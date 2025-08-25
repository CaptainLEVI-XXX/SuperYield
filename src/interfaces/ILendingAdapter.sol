// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface ILendingAdapter {
    struct PositionView {
        uint256 collateral;
        uint256 debt;
    } // raw token amounts

    function getPosition(bytes32 marketId, address borrower) external view returns (PositionView memory ps);
    function lltv(bytes32 marketId) external view returns (uint256);
    function accrue(bytes32 marketId) external view returns (uint256);
    function collateralAsset(bytes32 marketId) external view returns (address);
    function debtAsset(bytes32 marketId) external view returns (address);
    /**
     * Pre-liquidate a borrower on the underlying protocol.
     * If `seizedAssets > 0`, adapter computes debt shares via protocol math.
     */
    function preLiquidate(
        bytes32 marketId,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidDebtShares,
        bytes memory data
    ) external returns (uint256 seizedOut, uint256 repaidDebtAssets, uint256 repaidDebtSharesOut);
}
