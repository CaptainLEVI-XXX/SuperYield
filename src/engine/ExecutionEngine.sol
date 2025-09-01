// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {DexHelper} from "../abstract/DexHelper.sol";
import {Admin2Step} from "../abstract/Admin2Step.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {LibCall} from "@solady/utils/LibCall.sol";
import {Lock} from "../libraries/Lock.sol";
import {IUniversalLendingWrapper} from "../interfaces/IUniversalLendingWrapper.sol";
import {Rebalancer} from "../abstract/Rebalancer.sol";
import {Venue} from "../abstract/Venue.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {console} from "forge-std/console.sol";
import {ExecutionStorage} from "./Storage.sol";
import {ISuperVault} from "../interfaces/ISuperVault.sol";

contract StrategyManager is
    ExecutionStorage,
    DexHelper,
    Venue,
    Admin2Step,
    Rebalancer,
    Initializable,
    UUPSUpgradeable
{
    using SafeTransferLib for address;
    using LibCall for address;
    using CustomRevert for bytes4;
    using WadMath for uint256;

    modifier onlyVault() {
        if (!_vaultStorage().vaults[msg.sender]) InvalidCaller.selector.revertWith();
        _;
    }

    modifier onlyPreLiquidator() {
        if (msg.sender != preLiquidationManager) InvalidCaller.selector.revertWith();
        _;
    }

    modifier lockUnlock() {
        if (Lock.isUnlocked()) OperationLocked.selector.revertWith();
        Lock.lock();
        _;
        Lock.unlock();
    }

    function initialize(
        address _flashAggregator,
        address _calldataGenerator,
        address _preLiquidationManager,
        address _owner
    ) external initializer {
        _initializeRebalancer(_flashAggregator, _calldataGenerator);
        preLiquidationManager = _preLiquidationManager;
        _setAdmin(_owner);
    }

    // Open a Position
    function openPosition(
        address vault,
        address supplyAsset,
        address borrowAsset,
        uint256 supplyAmount,
        uint256 borrowAmount,
        uint256 flashLoanAmount,
        bytes32 venue,
        uint16 routeForFlashLoan,
        DexSwapCalldata calldata swapData
    ) external onlyAdmin returns (uint256 positionId) {
        PositionStorage storage pos = _positionStorage();
        VenueStorage storage venueInfo = _venueStorage();
        VaultInfo storage vaultInfo = _vaultStorage();

        if (!venueInfo.venues[venue].active) InvalidCaller.selector.revertWith();
        if (!vaultInfo.vaults[vault]) InvalidCaller.selector.revertWith();

        positionId = ++pos.nextPositionId;

        vaultInfo.vaultPositions[vault].push(positionId);

        LeverageData memory leverageData = LeverageData({
            supplyAsset: supplyAsset,
            borrowAsset: borrowAsset,
            initialSupply: supplyAmount,
            borrowAmount: borrowAmount,
            flashLoanAmount: flashLoanAmount,
            venue: venue,
            swapCalldata: swapData
        });

        ISuperVault(vault).provideFundsToEngine(supplyAmount);

        leverage(leverageData, routeForFlashLoan);

        IProtocolAdapter adapter = venueInfo.venues[venue].adapter;

        (uint256 collateralUsd, uint256 debtUsd) = adapter.getPositionUsd(supplyAsset, borrowAsset, address(this));

        uint256 totalSupplied_ = adapter.usdToTokenUnits(supplyAsset, collateralUsd - WadMath.WAD); //collateralUsd-1e18 is for difference in price since we are using our own oracle
        uint256 totalBorrowed_ = adapter.usdToTokenUnits(borrowAsset, debtUsd);

        pos.positions[positionId] = Position({
            vault: vault,
            supplyAsset: supplyAsset,
            borrowAsset: borrowAsset,
            currentVenue: venue,
            totalSupplied: totalSupplied_,
            totalBorrowed: totalBorrowed_,
            status: PositionStatus.Active
        });

        emit PositionOpened(positionId, vault, venue);
    }

    function closePosition(
        uint256 positionId,
        uint256 repayAmount,
        uint256 withdrawAmount,
        DexSwapCalldata calldata swapData,
        uint16 routeForFlashLoan
    ) external onlyAdmin {
        Position storage position = _positionStorage().positions[positionId];
        require(position.status == PositionStatus.Active, "Position not active");

        DeleverageData memory deleverageData = DeleverageData({
            supplyAsset: position.supplyAsset,
            borrowAsset: position.borrowAsset,
            vault: position.vault,
            venue: position.currentVenue,
            repayAmount: repayAmount,
            withdrawAmount: withdrawAmount,
            swapCalldata: swapData
        });

        deleverage(deleverageData, routeForFlashLoan);

        position.status = PositionStatus.Inactive;
        emit PositionClosed(positionId, position.totalSupplied);
    }

    function migratePosition(uint256 positionId, bytes32 toVenue, uint16 routeForFlashLoan) external onlyAdmin {
        Position storage position = _positionStorage().positions[positionId];
        require(position.status == PositionStatus.Active, "Not active");
        require(_venueStorage().venues[toVenue].active, "Venue not active");

        RebalanceData memory rebalanceData = RebalanceData({
            fromVenue: position.currentVenue,
            toVenue: toVenue,
            moveSupplyAmount: position.totalSupplied,
            moveBorrowAmount: position.totalBorrowed,
            supplyAsset: position.supplyAsset,
            borrowAsset: position.borrowAsset
        });

        rebalance(rebalanceData, routeForFlashLoan);

        position.currentVenue = toVenue;
        position.status = PositionStatus.Migrated;

        emit PositionRebalanced(positionId, position.currentVenue, toVenue);
    }

    function executePreLiquidation(uint256 positionId, uint256 repayAmount, uint256 seizeAmount, address keeper)
        external
        onlyPreLiquidator
        returns (uint256, uint256)
    {
        Position storage position = _positionStorage().positions[positionId];
        if (position.status != PositionStatus.Active) InvalidCaller.selector.revertWith();
        VenueInfo memory venue = _venueStorage().venues[position.currentVenue];

        // Take repay amount from Liquidator
        position.borrowAsset.safeTransferFrom(msg.sender, address(this), repayAmount);

        // Approve venue Router for debt
        position.borrowAsset.safeApprove(venue.router, repayAmount);

        (bytes memory repayCalldata, bytes memory withdrawCalldata) = calldataGenerator.getBatchRepayWithdraw(
            position.borrowAsset, repayAmount, position.supplyAsset, seizeAmount, address(this), venue.id
        );

        venue.router.callContract(repayCalldata);
        venue.router.callContract(withdrawCalldata);

        // Send collateral to keeper
        position.supplyAsset.safeTransfer(keeper, seizeAmount);

        // Update position state
        position.totalBorrowed -= repayAmount;
        position.totalSupplied -= seizeAmount;

        return (repayAmount, seizeAmount);
    }

    function registerVenue(address router, uint8 identifier, address adapter) public virtual override onlyAdmin {
        super.registerVenue(router, identifier, adapter);
    }

    function registerVault(address vault) external onlyAdmin {
        _vaultStorage().vaults[vault] = true;
    }

    function whitelistRoute(string memory name, address _router) public virtual override returns (bytes32) {
        return super.whitelistRoute(name, _router);
    }

    function updateRouteStatus(bytes32[] calldata identifier, bool[] calldata status)
        public
        virtual
        override
        returns (bool)
    {
        return super.updateRouteStatus(identifier, status);
    }

    function setPreLiquidationManager(address _manager) external onlyAdmin {
        preLiquidationManager = _manager;
    }

    function getPosition(uint256 positionId) external view returns (uint256 collateral, uint256 debt) {
        Position storage position = _positionStorage().positions[positionId];
        return (position.totalSupplied, position.totalBorrowed);
    }

    function setUniversalLendingWrapper(address _wrapper) external onlyAdmin {
        calldataGenerator = IUniversalLendingWrapper(_wrapper);
    }

    function getDeployedValue(address vault) external view returns (uint256 totalValue) {
        uint256[] memory positions = _vaultStorage().vaultPositions[vault];
        VenueStorage storage venueStorage = _venueStorage();

        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = _positionStorage().positions[positions[i]];
            if (position.status == PositionStatus.Active) {
                IProtocolAdapter adapter = venueStorage.venues[position.currentVenue].adapter;
                try adapter.getPositionUsd(position.supplyAsset, position.borrowAsset, address(this)) returns (
                    uint256 collateralUsd, uint256 debtUsd
                ) {
                    // Net position value = collateral - debt
                    if (collateralUsd > debtUsd) {
                        uint256 netUsd = collateralUsd - debtUsd;
                        // Convert to vault's underlying asset
                        totalValue += adapter.usdToTokenUnits(position.supplyAsset, netUsd);
                    }
                } catch {
                    // Fallback to recorded amounts if adapter fails
                    totalValue += position.totalSupplied > position.totalBorrowed
                        ? position.totalSupplied - position.totalBorrowed
                        : 0;
                }
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
