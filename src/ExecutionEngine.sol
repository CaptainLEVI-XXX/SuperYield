// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {DexHelper} from "./abstract/DexHelper.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {LibCall} from "@solady/utils/LibCall.sol";
import {Lock} from "./libraries/Lock.sol";
import {IUniversalLendingWrapper} from "./interfaces/IUniversalLendingWrapper.sol";
import {Rebalancer} from "./abstract/Rebalancer.sol";
import {Venue} from "./abstract/Venue.sol";
import {Lock} from "./libraries/Lock.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";

contract StrategyManager is DexHelper, Venue, Admin2Step, Rebalancer, Initializable, UUPSUpgradeable {
    using SafeTransferLib for address;
    using LibCall for address;
    using CustomRevert for bytes4;

    enum PositionStatus {
        Inactive,
        Active,
        Migrated
    }

    struct Position {
        address vault;
        address supplyAsset;
        address borrowAsset;
        bytes32 currentVenue;
        uint256 totalSupplied;
        uint256 totalBorrowed;
        PositionStatus status;
    }

    uint256 public nextPositionId;

    mapping(uint256 => Position) public positions;
    //vault positions
    mapping(address => uint256[]) public vaultPositions;

    address public preLiquidationManager;

    mapping(address => uint256) public reserves; // asset => amount

    mapping(address => bool) public vaults;
    mapping(address => mapping(address => uint256)) public vaultReserves; // vault => asset => amount

    error OperationLocked();

    event PositionOpened(uint256 indexed positionId, address vault, bytes32 venue);
    event PositionClosed(uint256 indexed positionId, uint256 finalAmount);
    event PositionRebalanced(uint256 indexed positionId, bytes32 from, bytes32 to);
    event ReservesUpdated(address asset, uint256 amount);

    modifier onlyVault() {
        require(vaults[msg.sender], "Not vault");
        _;
    }

    modifier onlyPreLiquidator() {
        require(msg.sender == preLiquidationManager, "Not pre-liquidator");
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
        require(venues[venue].active, "Venue not active");
        require(vaults[vault], "Vault not registered");

        positionId = ++nextPositionId;

        vaultPositions[vault].push(positionId);

        LeverageData memory leverageData = LeverageData({
            supplyAsset: supplyAsset,
            borrowAsset: borrowAsset,
            initialSupply: supplyAmount,
            borrowAmount: borrowAmount,
            flashLoanAmount: flashLoanAmount,
            venue: venue,
            swapCalldata: swapData
        });

        supplyAsset.safeTransferFrom(vault, address(this), supplyAmount);

        leverage(leverageData, routeForFlashLoan);

        positions[positionId] = Position({
            vault: vault,
            supplyAsset: supplyAsset,
            borrowAsset: borrowAsset,
            currentVenue: venue,
            totalSupplied: supplyAmount,
            totalBorrowed: borrowAmount,
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
        Position storage position = positions[positionId];
        require(position.status == PositionStatus.Active, "Position not active");

        DeleverageData memory deleverageData = DeleverageData({
            supplyAsset: position.supplyAsset,
            borrowAsset: position.borrowAsset,
            venue: position.currentVenue,
            repayAmount: repayAmount,
            withdrawAmount: withdrawAmount,
            swapCalldata: swapData
        });

        deleverage(deleverageData, routeForFlashLoan);

        position.status = PositionStatus.Inactive;
        emit PositionClosed(positionId, position.totalSupplied);
    }

    /// @notice Move a position to a target LTV in a single flash-backed operation.
    /// @dev Caller must provide flashLoanAmount denominated in supplyAsset (since leverage() flashloans supplyAsset),
    ///      and borrowAmount denominated in borrowAsset (the amount to borrow from the venue after supplying).
    ///      swapData for leverage MUST be borrowAsset -> supplyAsset (amountIn == borrowAmount).
    function rebalanceToTargetLTV(
        uint256 positionId,
        uint256 targetLTV, // 1e18 precision
        uint256 borrowAmount, // borrowAsset units needed to reach target (computed off-chain)
        uint256 flashLoanAmount, // supplyAsset units to flashLoan (computed off-chain)
        DexSwapCalldata calldata swapData, // should be borrowAsset -> supplyAsset when leveraging; opposite for deleveraging
        uint16 routeForFlashLoan
    ) external onlyAdmin {
        Position storage pos = positions[positionId];
        require(pos.status == PositionStatus.Active, "inactive");
        require(targetLTV > 0 && targetLTV < 1e18, "bad target");

        // compute current LTV (naive using stored accounting)
        uint256 currentLTV = (pos.totalBorrowed * 1e18) / pos.totalSupplied;
        if (currentLTV == targetLTV) return;

        if (targetLTV > currentLTV) {
            // Build LeverageData compatible with your Rebalancer
            LeverageData memory data = LeverageData({
                supplyAsset: pos.supplyAsset,
                borrowAsset: pos.borrowAsset,
                initialSupply: pos.totalSupplied,
                borrowAmount: borrowAmount,
                flashLoanAmount: flashLoanAmount,
                venue: pos.currentVenue,
                swapCalldata: swapData
            });

            // Make the flash-backed leverage call
            leverage(data, routeForFlashLoan);

            // NOTE: update accounting conservatively: we cannot know exact swapped amount on-chain here.
            pos.totalBorrowed += borrowAmount;
            pos.totalSupplied += flashLoanAmount; // approximate - replace with adapter read if available
        } else {
            // Delever: need to repay 'repayAmount' of borrowAsset; flashLoan must be in borrowAsset
            uint256 repayAmount = pos.totalBorrowed - (pos.totalSupplied * targetLTV) / 1e18;

            // swapData must be supplyAsset -> borrowAsset; amountIn should be withdrawAmount (collateral units)
            // require(swapData.tokenIn == pos.supplyAsset, "swapData.tokenIn must be supplyAsset for delever");
            // require(swapData.tokenOut == pos.borrowAsset, "swapData.tokenOut must be borrowAsset for delever");
            // // caller should set swapData.amountIn to expected withdrawAmount (off-chain computed)
            // // We'll accept it as-is and rely on adapter/exec to revert if insufficient
            DeleverageData memory d = DeleverageData({
                supplyAsset: pos.supplyAsset,
                borrowAsset: pos.borrowAsset,
                repayAmount: repayAmount,
                withdrawAmount: borrowAmount,
                venue: pos.currentVenue,
                swapCalldata: swapData
            });

            deleverage(d, routeForFlashLoan);

            pos.totalBorrowed -= repayAmount;
            pos.totalSupplied -= borrowAmount; // approximate
        }
    }

    /**
     * @notice Rebalance position to different venue
     */
    function rebalancePosition(
        uint256 positionId,
        bytes32 toVenue,
        DexSwapCalldata calldata swapData,
        uint16 routeForFlashLoan
    ) external onlyAdmin {
        Position storage position = positions[positionId];
        require(position.status == PositionStatus.Active, "Not active");
        require(venues[toVenue].active, "Venue not active");

        RebalanceData memory rebalanceData = RebalanceData({
            fromVenue: position.currentVenue,
            toVenue: toVenue,
            moveSupplyAmount: position.totalSupplied,
            moveBorrowAmount: position.totalBorrowed,
            swapCalldata: swapData,
            supplyAsset: position.supplyAsset,
            borrowAsset: position.borrowAsset
        });

        rebalance(rebalanceData, routeForFlashLoan);

        position.currentVenue = toVenue;
        position.status = PositionStatus.Migrated;

        emit PositionRebalanced(positionId, position.currentVenue, toVenue);
    }

    function executePreLiquidation(
        bytes32 protocolId,
        bytes32 marketId,
        address debtToken,
        address collateralToken,
        uint256 repayAmount,
        uint256 seizeAmount,
        address keeper
    ) external onlyPreLiquidator returns (uint256, uint256) {
        // Find position by market
        uint256 positionId = findPositionByMarket(protocolId, marketId);
        Position storage position = positions[positionId];

        require(position.borrowAsset == debtToken, "Wrong debt token");
        require(position.supplyAsset == collateralToken, "Wrong collateral");

        VenueInfo memory venue = venues[position.currentVenue];

        // Take repay amount from Liquidator
        debtToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        // Repay debt
        debtToken.safeApprove(venue.router, repayAmount);
        bytes memory repayCalldata = calldataGenerator.getCalldata(
            debtToken,
            repayAmount,
            address(this),
            3, // REPAY
            venue.id
        );
        venue.router.callContract(repayCalldata);

        // Withdraw collateral for keeper
        bytes memory withdrawCalldata = calldataGenerator.getCalldata(
            collateralToken,
            seizeAmount,
            address(this),
            1, // WITHDRAW
            venue.id
        );
        venue.router.callContract(withdrawCalldata);

        // Send collateral to keeper
        collateralToken.safeTransfer(keeper, seizeAmount);

        // Update position state
        position.totalBorrowed -= repayAmount;
        position.totalSupplied -= seizeAmount;

        return (repayAmount, seizeAmount);
    }

    function registerVenue(address router, uint8 identifier) public virtual override onlyAdmin {
        super.registerVenue(router, identifier);
    }

    function registerVault(address vault) external onlyAdmin {
        vaults[vault] = true;
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

    function findPositionByMarket(bytes32 protocolId, bytes32 marketId) internal view returns (uint256) {
        // Find position matching protocol and market
        // Implementation needed
        return 0;
    }

    function deleverageForWithdrawal(address vault, uint256 amount) internal returns (uint256) {
        // Partially deleverage positions to free up funds
        // Implementation needed
        return 0;
    }

    function getVaultSupplyAsset(address vault) internal view returns (address) {
        // Get supply asset for vault
        // Could call vault.asset0() or similar
        return address(0); // Placeholder
    }

    // function initialize(address owner) public initializer {
    //     _setAdmin(owner);
    // }

    function getDeployedValue(address vault) external view returns (uint256) {
        return vaultReserves[vault][getVaultSupplyAsset(vault)];
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
