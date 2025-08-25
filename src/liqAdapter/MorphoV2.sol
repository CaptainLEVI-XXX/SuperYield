//   SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {WadMath} from "../libraries/WadMath.sol";

interface IMorphoLike {
    struct Position {
        uint128 collateral;
        uint128 borrowShares;
    }

    struct Market {
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
    }

    function market(bytes32 id) external view returns (Market memory);
    function position(bytes32 id, address borrower) external view returns (Position memory);
    function idToMarketParams(bytes32 id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
}

interface IPreLiquidationLike {
    function preLiquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
        external
        returns (uint256 seizedOut, uint256 repaidAssets);
    function marketParams()
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
}

contract MorphoBluePreLiqAdapter is ILendingAdapter {
    using WadMath for uint256;

    IMorphoLike public immutable MORPHO;
    mapping(bytes32 id => IPreLiquidationLike) public preLiq;

    constructor(address morpho) {
        MORPHO = IMorphoLike(morpho);
    }

    function setPreLiquidation(bytes32 id, IPreLiquidationLike pre) external {
        preLiq[id] = pre;
    }

    function getPosition(bytes32 marketId,address borrower) external view returns (PositionView memory p) {
        IMorphoLike.Position memory pos = MORPHO.position(marketId, borrower);
        IMorphoLike.Market memory m = MORPHO.market(marketId);
        if (m.totalBorrowShares == 0) return PositionView({collateral: uint256(pos.collateral), debt: 0});
        // convert shares->assets (UP). Use protocol's exact math libs in production.
        uint256 debtAssets = (
            uint256(pos.borrowShares) * uint256(m.totalBorrowAssets) + uint256(m.totalBorrowShares) - 1
        ) / uint256(m.totalBorrowShares);
        p = PositionView({collateral: uint256(pos.collateral), debt: debtAssets});
    }

    function lltv(bytes32 marketId) external view returns (uint256) {
        (,,,, uint256 _lltv) = MORPHO.idToMarketParams(marketId);
        return _lltv;
    }

    function accrue(bytes32 marketId) external view returns (uint256){
         /* optional: call MORPHO.accrueInterest via proper interface */ 
         
    }
    
    function preLiquidate(
        bytes32 marketId,
        address borrower,
        uint256 seizedAssets,
        uint256, /*repaidDebtShares*/
        bytes calldata data
    ) external returns (uint256 seizedOut, uint256 repaidDebtAssets, uint256 repaidDebtSharesOut) {
        IPreLiquidationLike pre = preLiq[marketId];
        require(address(pre) != address(0), "NO_PRE");
        (seizedOut, repaidDebtAssets) = pre.preLiquidate(borrower, seizedAssets, 0, data);
        // shares not returned by the pre contract; set 0 or compute with protocol math if needed
        repaidDebtSharesOut = 0;
    }

    function debtAsset(bytes32 marketId) external view returns (address) {
        (address loan,,,,) = preLiq[marketId].marketParams();
        return loan;
    }

    function collateralAsset(bytes32 marketId) external view returns (address) {
        (, address col,,,) = preLiq[marketId].marketParams();
        return col;
    }
}


