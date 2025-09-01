// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInstaFlashAggregatorInterface} from "../interfaces/IInstaDappFlashLoan.sol";
import {IStrategyManager} from "../interfaces/IExecutionEngine.sol";
import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {PreLiquidationCore} from "../abstract/PreLiquidationCore.sol";
import {DexHelper} from "../abstract/DexHelper.sol";

abstract contract PreLiquidationStorage {
    struct PreLiqState {
        /// @notice InstaDapp flash loan aggregator interface
        IInstaFlashAggregatorInterface flashAggregator;
        /// @notice Strategy manager contract that handles position management
        IStrategyManager strategyManager;
    }

    /// @notice Configuration parameters for a specific market
    /// @dev Contains all necessary parameters to manage pre-liquidations for a market
    /// @param protocolId Unique identifier for the lending protocol
    /// @param marketId Unique identifier for the specific market within the protocol
    /// @param adapter Protocol adapter contract for interacting with the lending protocol
    /// @param params Pre-liquidation parameters including thresholds and incentives
    /// @param targetLtv Target loan-to-value ratio after pre-liquidation
    /// @param maxRepayPct Maximum percentage of debt that can be repaid in one transaction
    /// @param cooldown Minimum time between pre-liquidation actions for this market
    /// @param lastAction Timestamp of the last pre-liquidation action
    /// @param enabled Whether pre-liquidations are enabled for this market
    /// @param flashLoanEnabled Whether flash loan pre-liquidations are allowed
    struct MarketConfig {
        uint256 positionId;
        IProtocolAdapter adapter;
        PreLiquidationCore.PreLiquidationParams params;
        uint256 targetLtv;
        uint256 maxRepayPct;
        uint256 cooldown;
        uint48 lastAction;
        bool enabled;
        bool flashLoanEnabled;
    }

    /// @notice Data structure for flash loan execution
    /// @dev Contains all necessary information for executing a flash loan pre-liquidation
    /// @param marketKey Unique key identifying the market configuration
    /// @param keeper Address of the keeper executing the pre-liquidation
    /// @param seizeAmount Amount of collateral to seize (in USD)
    /// @param collateralToken Address of the collateral token
    /// @param debtToken Address of the debt token to repay
    struct FlashLoanData {
        bytes32 marketId;
        address keeper;
        uint256 seizeAmount;
        uint256 repayAmount;
        address collateralToken;
        address debtToken;
        DexHelper.DexSwapCalldata swapData;
    }

    struct MarketStorage {
        mapping(bytes32 => MarketConfig) markets;
    }

    event PreLiquidation(
        bytes32 indexed marketKey,
        address indexed keeper,
        uint256 ltvBefore,
        uint256 ltvAfter,
        uint256 repaidUsd,
        uint256 seizedUsd,
        uint256 profit
    );
    event FlashLiquidation(bytes32 indexed marketKey, address indexed keeper, uint256 flashLoanAmount, uint256 profit);
    event MarketConfigured(bytes32 indexed marketKey, uint256 positionId, bool flashLoanEnabled);

    error NotAuthorized();
    error MarketNotEnabled();
    error NotInPreLiquidationZone();
    error CooldownActive();
    error TargetLtvTooHigh();
    error MaxRepayPctTooHigh();
    error AmountTooSmall();
    error FlashLoanFailed();
    error InvalidFlashLoanCallback();

    // keccak256("preliquidation.storage.position")
    bytes32 public constant PRELIQ_STORAGE_POSITION = 0xe3b54e7a634b8dd47e6ef3d72f4dc0d6f033e4f18def382c5701f0bc4e3b5ed4;

    // keccak256("market.storage.position")
    bytes32 public constant MARKET_STORAGE_POSITION = 0x865d3b2112b161636a1ab96b7ef1ed64d061a820146568f72a1015590043c738;

    /// @dev This way we can define Storage at random slots in EVM which will help in avoiding storage collisions in the case of upgrades.
    function _preliqStorage() internal pure returns (PreLiqState storage preliqStorage) {
        bytes32 position = PRELIQ_STORAGE_POSITION;
        assembly {
            preliqStorage.slot := position
        }
    }
    /// @dev This way we can define Storage at random slots in EVM which will help in avoiding storage collisions in the case of upgrades.

    function _marketStorage() internal pure returns (MarketStorage storage marketStorage) {
        bytes32 position = MARKET_STORAGE_POSITION;
        assembly {
            marketStorage.slot := position
        }
    }
}
