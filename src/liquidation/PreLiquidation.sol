// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {WadMath} from "../libraries/WadMath.sol";
import {Lock} from "../libraries/Lock.sol";
import {Admin2Step} from "../abstract/Admin2Step.sol";
import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IStrategyManager} from "../interfaces/IExecutionEngine.sol";
import {IInstaFlashAggregatorInterface, IInstaFlashReceiverInterface} from "../interfaces/IInstaDappFlashLoan.sol";
import {PreLiquidationCore} from "../abstract/PreLiquidationCore.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {console} from "forge-std/console.sol";
import {DexHelper} from "../abstract/DexHelper.sol";
import {PreLiquidationStorage} from "./Storage.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";

contract PreLiquidationManager is
    Admin2Step,
    PreLiquidationStorage,
    PreLiquidationCore,
    Initializable,
    UUPSUpgradeable,
    IInstaFlashReceiverInterface,
    DexHelper
{
    using SafeTransferLib for address;
    using WadMath for uint256;
    using CustomRevert for bytes4;

    function initialize(address _strategyManager, address _flashLoanProvider, address owner) public initializer {
        PreLiqState storage preliq = _preliqStorage();
        preliq.strategyManager = IStrategyManager(_strategyManager);
        preliq.flashAggregator = IInstaFlashAggregatorInterface(_flashLoanProvider);
        _setAdmin(owner);
    }

    /// @notice Configures pre-liquidation parameters for a specific market
    /// @dev Only callable by admin. Validates all parameters before setting configuration
    /// @param marketId Unique identifier for the market
    /// @param positionId Position identifier
    /// @param adapter Address of the protocol adapter contract
    /// @param params Pre-liquidation parameters including LTV thresholds
    /// @param targetLtv Target LTV ratio to achieve after pre-liquidation
    /// @param maxRepayPct Maximum percentage of debt that can be repaid (in WAD format)
    /// @param cooldown Cooldown period between pre-liquidation actions (in seconds)
    /// @param enableFlashLoan Whether to enable flash loan pre-liquidations for this market
    function configureMarket(
        bytes32 marketId,
        uint256 positionId,
        address adapter,
        PreLiquidationParams calldata params,
        uint256 targetLtv,
        uint256 maxRepayPct,
        uint256 cooldown,
        bool enableFlashLoan
    ) external onlyAdmin {
        uint256 protocolLltv = IProtocolAdapter(adapter).lltv(marketId);

        // Validate using core function
        validateParams(params, protocolLltv);

        if (targetLtv >= params.preLltv) TargetLtvTooHigh.selector.revertWith();
        if (maxRepayPct > WadMath.WAD) MaxRepayPctTooHigh.selector.revertWith();

        _marketStorage().markets[marketId] = MarketConfig({
            positionId: positionId,
            adapter: IProtocolAdapter(adapter),
            params: params,
            targetLtv: targetLtv,
            maxRepayPct: maxRepayPct,
            cooldown: cooldown,
            lastAction: 0,
            enabled: true,
            flashLoanEnabled: enableFlashLoan
        });

        emit MarketConfigured(marketId, positionId, enableFlashLoan);
    }

    function setMarketEnabled(bytes32 marketId, bool enabled) external onlyAdmin {
        _marketStorage().markets[marketId].enabled = enabled;
    }

    function preLiquidate(bytes32 marketId, uint256 maxRepayUsd, uint256 minSeizeUsd)
        external
        returns (uint256 actualRepaidUsd, uint256 actualSeizedUsd)
    {
        MarketConfig storage config = _marketStorage().markets[marketId];

        _validateMarket(config);

        // Get position and calculate amounts
        (LiquidationAmounts memory amounts, uint256 currentLtv,,) = _preparePreLiquidation(marketId);

        // Apply keeper limits
        if (maxRepayUsd > 0 && amounts.repayAmount > maxRepayUsd) {
            amounts.repayAmount = maxRepayUsd;
            amounts.seizeAmount = amounts.repayAmount.wMul(amounts.lif);
        }

        if (minSeizeUsd > 0 && amounts.seizeAmount < minSeizeUsd) AmountTooSmall.selector.revertWith();

        // Execute liquidation
        (actualRepaidUsd, actualSeizedUsd) = _executeLiquidation(
            marketId,
            config,
            amounts,
            msg.sender,
            false // not a flash loan
        );

        // Update state and emit
        _finalizeLiquidation(marketId, config, currentLtv, actualRepaidUsd, actualSeizedUsd, msg.sender);
    }

    function preLiquidateWithFlashLoan(
        bytes32 marketId,
        uint256 maxRepayUsd,
        uint16 routeForFlashLoan,
        DexSwapCalldata memory swapData
    ) external {
        MarketConfig storage config = _marketStorage().markets[marketId];
        _validateMarket(config);

        if (!config.flashLoanEnabled) FlashLoanFailed.selector.revertWith();

        // Get position and calculate amounts
        (LiquidationAmounts memory amounts,,,) = _preparePreLiquidation(marketId);

        if (maxRepayUsd > 0 && amounts.repayAmount > maxRepayUsd) {
            amounts.repayAmount = maxRepayUsd;
            amounts.seizeAmount = amounts.repayAmount.wMul(amounts.lif);
        }

        // Get tokens
        (address collateralToken, address debtToken) = config.adapter.getTokens(marketId);

        // Convert to token units for flash loan
        uint256 repayUnits = config.adapter.usdToTokenUnits(debtToken, amounts.repayAmount);

        // Prepare flash loan data
        FlashLoanData memory flashData = FlashLoanData({
            marketId: marketId,
            keeper: msg.sender,
            seizeAmount: amounts.seizeAmount,
            repayAmount: repayUnits,
            collateralToken: collateralToken,
            debtToken: debtToken,
            swapData: swapData
        });

        // Execute flash loan
        _preliqStorage().flashAggregator.flashLoan(
            toArray(debtToken), toArray(repayUnits), routeForFlashLoan, abi.encode(flashData), ""
        );

        emit FlashLiquidation(
            marketId, msg.sender, repayUnits, calculateKeeperProfit(amounts.seizeAmount, amounts.repayAmount)
        );
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        address flashAggregator = address(_preliqStorage().flashAggregator);
        if (msg.sender != flashAggregator) InvalidFlashLoanCallback.selector.revertWith();
        if (initiator != address(this)) InvalidFlashLoanCallback.selector.revertWith();

        FlashLoanData memory flashData = abi.decode(params, (FlashLoanData));

        MarketConfig storage config = _marketStorage().markets[flashData.marketId];

        // Calculate amounts in USD
        uint256 repayUsd = config.adapter.tokenUnitsToUsd(flashData.debtToken, amounts[0]);

        LiquidationAmounts memory liquidationAmounts = LiquidationAmounts({
            repayAmount: repayUsd,
            seizeAmount: flashData.seizeAmount,
            lif: 0, // Already calculated
            lcf: 0 // Already calculated
        });
        // Execute the actual liquidation
        (, uint256 actualSeizedUsd) = _executeLiquidation(
            flashData.marketId,
            config,
            liquidationAmounts,
            flashData.keeper,
            true // is flash loan
        );

        // Convert seized collateral to debt token to repay flash loan
        uint256 seizedUnits = config.adapter.usdToTokenUnits(flashData.collateralToken, actualSeizedUsd);

        flashData.collateralToken.safeApprove(getDexRouter(flashData.swapData.identifier), seizedUnits);
        performSwap(flashData.swapData);

        //  flash loan repayment
        uint256 totalRepay = amounts[0] + premiums[0];
        flashData.debtToken.safeTransfer(address(flashAggregator), totalRepay);

        // Send profit to keeper
        flashData.debtToken.safeTransfer(flashData.keeper, flashData.debtToken.balanceOf(address(this)));

        return true;
    }

    function checkPosition(bytes32 marketKey)
        external
        view
        returns (
            bool preLiquidatable,
            uint256 currentLtv,
            uint256 lif,
            uint256 lcf,
            uint256 optimalRepayUsd,
            uint256 expectedSeizeUsd,
            uint256 expectedProfit
        )
    {
        MarketConfig memory config = _marketStorage().markets[marketKey];
        if (!config.enabled) return (false, 0, 0, 0, 0, 0, 0);

        try this.getPositionData(marketKey) returns (uint256 collateralUsd, uint256 debtUsd, uint256 protocolLltv) {
            if (collateralUsd == 0 || debtUsd == 0) return (false, 0, 0, 0, 0, 0, 0);

            currentLtv = debtUsd.wDiv(collateralUsd);

            if (isPreLiquidatable(currentLtv, config.params.preLltv, protocolLltv)) {
                preLiquidatable = true;

                LiquidationAmounts memory amounts = calculateLiquidationAmounts(
                    collateralUsd,
                    debtUsd,
                    currentLtv,
                    config.targetLtv,
                    protocolLltv,
                    config.maxRepayPct,
                    config.params
                );

                lif = amounts.lif;
                lcf = amounts.lcf;
                optimalRepayUsd = amounts.repayAmount;
                expectedSeizeUsd = amounts.seizeAmount;
                expectedProfit = calculateKeeperProfit(expectedSeizeUsd, optimalRepayUsd);
            }
        } catch {}
    }

    function getPositionData(bytes32 marketId)
        external
        view
        returns (uint256 collateralUsd, uint256 debtUsd, uint256 protocolLltv)
    {
        MarketConfig memory config = _marketStorage().markets[marketId];
        (collateralUsd, debtUsd) = config.adapter.getPositionUsd(marketId, address(_preliqStorage().strategyManager));
        protocolLltv = config.adapter.lltv(marketId);
    }

    function _preparePreLiquidation(bytes32 marketId)
        internal
        view
        returns (LiquidationAmounts memory amounts, uint256 currentLtv, uint256 collateralUsd, uint256 debtUsd)
    {
        MarketConfig memory config = _marketStorage().markets[marketId];

        // Get current position
        (collateralUsd, debtUsd) = config.adapter.getPositionUsd(marketId, address(_preliqStorage().strategyManager));

        if (collateralUsd == 0 || debtUsd == 0) AmountTooSmall.selector.revertWith();

        // Calculate LTV
        currentLtv = debtUsd.wDiv(collateralUsd);
        uint256 protocolLltv = config.adapter.lltv(marketId);

        // Check if in pre-liquidation zone
        if (!isPreLiquidatable(currentLtv, config.params.preLltv, protocolLltv)) {
            NotInPreLiquidationZone.selector.revertWith();
        }

        // Calculate optimal amounts using core function
        amounts = calculateLiquidationAmounts(
            collateralUsd, debtUsd, currentLtv, config.targetLtv, protocolLltv, config.maxRepayPct, config.params
        );
    }

    function _executeLiquidation(
        bytes32 marketId,
        MarketConfig memory config,
        LiquidationAmounts memory amounts,
        address keeper,
        bool isFlashLoan
    ) internal returns (uint256 actualRepaidUsd, uint256 actualSeizedUsd) {
        PreLiqState storage preliqStorage = _preliqStorage();
        // Get tokens
        (address collateralToken, address debtToken) = config.adapter.getTokens(marketId);

        // Convert to token units
        uint256 repayUnits = config.adapter.usdToTokenUnits(debtToken, amounts.repayAmount);
        uint256 seizeUnits = config.adapter.usdToTokenUnits(collateralToken, amounts.seizeAmount);

        if (!isFlashLoan) {
            // Transfer debt tokens from keeper
            debtToken.safeTransferFrom(keeper, address(this), repayUnits);
        }

        // Approve strategy manager
        debtToken.safeApprove(address(preliqStorage.strategyManager), repayUnits);

        // Execute through strategy manager
        (uint256 actualRepaid, uint256 actualSeized) = preliqStorage.strategyManager.executePreLiquidation(
            config.positionId, repayUnits, seizeUnits, isFlashLoan ? address(this) : keeper
        );

        // Convert back to USD
        actualRepaidUsd = config.adapter.tokenUnitsToUsd(debtToken, actualRepaid);
        actualSeizedUsd = config.adapter.tokenUnitsToUsd(collateralToken, actualSeized);
    }

    function _validateMarket(MarketConfig memory config) internal view {
        if (!config.enabled) MarketNotEnabled.selector.revertWith();
        if (block.timestamp < config.lastAction + config.cooldown) CooldownActive.selector.revertWith();
    }

    function _finalizeLiquidation(
        bytes32 marketId,
        MarketConfig storage config,
        uint256 ltvBefore,
        uint256 actualRepaidUsd,
        uint256 actualSeizedUsd,
        address keeper
    ) internal {
        config.lastAction = uint48(block.timestamp);

        // Calculate new LTV
        (uint256 newCollateralUsd, uint256 newDebtUsd) =
            config.adapter.getPositionUsd(marketId, address(_preliqStorage().strategyManager));
        uint256 ltvAfter = newDebtUsd > 0 ? newDebtUsd.wDiv(newCollateralUsd) : 0;

        // Calculate and track profit
        uint256 profit = calculateKeeperProfit(actualSeizedUsd, actualRepaidUsd);

        emit PreLiquidation(marketId, keeper, ltvBefore, ltvAfter, actualRepaidUsd, actualSeizedUsd, profit);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function toArray(address item) internal pure returns (address[] memory) {
        address[] memory array = new address[](1);
        array[0] = item;
        return array;
    }

    function toArray(uint256 item) internal pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = item;
        return array;
    }

    function whitelistRoute(string memory name, address _router) public virtual override onlyAdmin returns (bytes32) {
        return super.whitelistRoute(name, _router);
    }

    function updateRouteStatus(bytes32[] calldata identifier, bool[] calldata status)
        public
        virtual
        override
        onlyAdmin
        returns (bool)
    {
        return super.updateRouteStatus(identifier, status);
    }
}
