// SPDX-License-Identifier: MIT

import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {Pausable} from "./abstract/Pausable.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {WadMath} from "./libraries/WadMath.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title SoftLiquidationManager - multi market pre-liquidation orchestrator
 * @notice  Startegy Manager is the only borrower that opens positions across multiple markets
 * This contract monitors LTV per marketId and executed pre-liwuidation to de-risk back to target LTV
 * marketId is a protocol-specific Identifier
 */
contract SoftLiquidationManager is UUPSUpgradeable, Admin2Step, Initializable, Pausable {
    using SafeTransferLib for address;
    using CustomRevert for bytes4;
    using Lock for *;
    using WadMath for uint256;

    struct MarketConfig {
        ILendingAdapter adapter; // adapter for this market
        bytes32 marketId; // protocol-specific id
        IPriceOracle preOracle; // oracle for pre-liq pricing (collateral→debt quote)
        uint256 preLltv; // WAD. start of soft band
        uint256 preLCF1; // WAD. close factor at preLltv
        uint256 preLCF2; // WAD. close factor at LLTV
        uint256 preLIF1; // WAD. incentive at preLltv (>= 1e18)
        uint256 preLIF2; // WAD. incentive at LLTV (<= 1 / LLTV)
        uint256 maxSlippageBPS; // 1e4 = 100%
        bool enabled; //
    }

    // if LTV is in [preLltv, lltv], push towards targetLtv(< preLtv)
    struct RiskTarget {
        uint256 targetLtv;
        uint256 maxRepayPct; // WAD. cap repay fraction of current debt per invocation
        uint256 cooldown; // seconds between soft-liqs per market
    }

    struct MarketMeta {
        uint48 lastAction;
        bool tracked;
    }

    struct LiquidationStorage {
        mapping(bytes32 => MarketConfig) marketConfigs;
        mapping(bytes32 => MarketMeta) marketMetas;
        mapping(bytes32 => RiskTarget) riskTargets;
    }

    /* ---------- Events ---------- */
    event MarketRegistered(bytes32 indexed marketId, address adapter);
    event MarketUpdated(bytes32 indexed marketId);
    event MarketTracked(bytes32 indexed marketId);
    event MarketUntracked(bytes32 indexed marketId);
    event SoftLiquidated(
        bytes32 indexed marketId,
        uint256 ltvBefore,
        uint256 ltvAfter,
        uint256 seizedAssets,
        uint256 repaidDebtAssets,
        uint256 repaidDebtShares
    );

    error SoftLiquidationManager__ZeroAddress();

    bytes32 public constant LIQUIDATION_STORAGE = keccak256("super.liquidation.storage");

    function liquidationStorage() internal pure returns (LiquidationStorage storage ls) {
        bytes32 position = LIQUIDATION_STORAGE;
        assembly {
            ls.slot := position
        }
    }

    address public borrower; // StrategyManager address

    function initialize(address owner, address borrower_) public initializer {
        _setAdmin(owner);
        borrower = borrower_;
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function registerMarkets(bytes32 marketId, MarketConfig calldata cfg, RiskTarget calldata rt) external onlyAdmin {
        if (address(cfg.adapter) == address(0)) SoftLiquidationManager__ZeroAddress.selector.revertWith();
        if (address(cfg.preOracle) == address(0)) SoftLiquidationManager__ZeroAddress.selector.revertWith();
        //sanity checks
        uint256 lltv_ = cfg.adapter.lltv(marketId);
        require(cfg.preLltv < lltv_, "preLltv>=LLTV");
        require(cfg.preLCF1 <= cfg.preLCF2, "LCF!mono");
        require(cfg.preLCF1 <= WadMath.WAD, "LCF1>1");
        require(cfg.preLIF1 >= WadMath.WAD, "LIF1<1");
        require(cfg.preLIF1 <= cfg.preLIF2, "LIF!mono");
        require(cfg.preLIF2 <= WadMath.WAD.wDiv(lltv_), "LIF2 too high");

        LiquidationStorage storage ls = liquidationStorage();
        ls.marketConfigs[marketId] = cfg;
        ls.riskTargets[marketId] = rt;
        emit MarketRegistered(marketId, address(cfg.adapter));
    }

    function setMarket(bytes32 marketId, MarketConfig calldata cfg) external onlyAdmin {
        LiquidationStorage storage ls = liquidationStorage();
        require(address(ls.marketConfigs[marketId].adapter) != address(0), "UNKNOWN_MARKET");
        ls.marketConfigs[marketId] = cfg;
        emit MarketUpdated(marketId);
    }

    function setRisk(bytes32 marketId, RiskTarget calldata rt) external onlyAdmin {
        LiquidationStorage storage ls = liquidationStorage();
        require(address(ls.marketConfigs[marketId].adapter) != address(0), "UNKNOWN_MARKET");
        ls.riskTargets[marketId] = rt;
        emit MarketUpdated(marketId);
    }

    function trackMarket(bytes32 marketId) external onlyAdmin {
        LiquidationStorage storage ls = liquidationStorage();
        ls.marketMetas[marketId].tracked = true;
        emit MarketTracked(marketId);
    }

    function untrackMarket(bytes32 marketId) external onlyAdmin {
        LiquidationStorage storage ls = liquidationStorage();
        ls.marketMetas[marketId].tracked = false;
        emit MarketUntracked(marketId);
    }

    /// Check a market for the fixed borrower and soft-liquidate if inside pre band. Returns whether action was taken.
    function checkAndSoftLiquidate(bytes32 marketId, bytes memory adapterData) external returns (bool acted) {
        LiquidationStorage storage ls = liquidationStorage();
        MarketConfig memory cfg = ls.marketConfigs[marketId];
        MarketMeta memory meta = ls.marketMetas[marketId];
        RiskTarget memory rt = ls.riskTargets[marketId];

        require(cfg.enabled, "DISABLED");
        require(meta.tracked, "NOT_TRACKED");

        cfg.adapter.accrue(marketId);

        // read position
        ILendingAdapter.PositionView memory p = cfg.adapter.getPosition(marketId, borrower);
        if (p.debt == 0 || p.collateral == 0) return false;

        uint256 ltv = _ltv(p, cfg.preOracle);
        uint256 lltv_ = cfg.adapter.lltv(marketId);

        if (ltv <= cfg.preLltv || ltv > lltv_) return false; // outside pre band

        // compute linear LIF/LIF
        (uint256 lif, uint256 lcf) =
            _lifLcf(ltv, cfg.preLltv, lltv_, cfg.preLIF1, cfg.preLIF2, cfg.preLCF1, cfg.preLCF2);

        // rate-limit via cooldown
        if (rt.cooldown > 0) require(block.timestamp >= uint256(meta.lastAction) + rt.cooldown, "COOLDOWN");

        // compute desired debt reduction to push LTV toward target
        uint256 targetLtv = (rt.targetLtv != 0 && rt.targetLtv < cfg.preLltv) ? rt.targetLtv : (cfg.preLltv + ltv) / 2;
        uint256 collateralQuoted = p.collateral.mulDivDown(cfg.preOracle.price(), 1e18);
        uint256 desiredDebt = targetLtv.wMul(collateralQuoted);
        uint256 deltaDebt = (p.debt > desiredDebt) ? (p.debt - desiredDebt) : 0;
        uint256 maxRepay = (rt.maxRepayPct != 0) ? (p.debt.wMul(rt.maxRepayPct)) : p.debt;

        // cap by LCF and maxRepayPct
        uint256 maxByLCF = lcf.wMul(p.debt);
        uint256 maxByPct = (rt.maxRepayPct == 0) ? type(uint256).max : rt.maxRepayPct.wMul(p.debt);
        uint256 repayAssets = _min(deltaDebt, _min(maxByLCF, maxByPct));
        if (repayAssets == 0) return false;

        // slippage/price sanity
        uint256 px = cfg.preOracle.price();
        require(px > 0, "BAD_PX");
        uint256 seizedAssets = repayAssets.wMul(lif).mulDivDown(1e18, px); // collateral units

        // Execute via adapter (seizedAssets path)
        (uint256 seizedOut, uint256 repaidAssetsOut, uint256 repaidSharesOut) =
            cfg.adapter.preLiquidate(marketId, borrower, seizedAssets, 0, adapterData);

        // Update meta & emit
        ls.marketMetas[marketId].lastAction = uint48(block.timestamp);
        uint256 ltvAfter = _ltv(cfg.adapter.getPosition(marketId, borrower), cfg.preOracle);
        emit SoftLiquidated(marketId, ltv, ltvAfter, seizedOut, repaidAssetsOut, repaidSharesOut);
        return true;
    }

    /// Batch variant for gas efficiency. Skips markets that don't qualify.
    function batchCheckAndSoftLiquidate(bytes32[] calldata marketIds, bytes[] calldata datas)
        external
        returns (uint256 actedCount)
    {
        require(marketIds.length == datas.length, "LEN");
        for (uint256 i; i < marketIds.length; ++i) {
            try this.checkAndSoftLiquidate(marketIds[i], datas[i]) returns (bool acted) {
                if (acted) actedCount++;
            } catch {}
        }
    }

    /* ---------- Views ---------- */
    function preview(bytes32 marketId) external view returns (uint256 ltv, uint256 lif, uint256 lcf) {
        LiquidationStorage storage ls = liquidationStorage();
        MarketConfig memory cfg = ls.marketConfigs[marketId];
        ILendingAdapter.PositionView memory p = cfg.adapter.getPosition(marketId, borrower);
        if (p.debt == 0 || p.collateral == 0) return (0, 0, 0);
        ltv = _ltv(p, cfg.preOracle);
        (lif, lcf) =
            _lifLcf(ltv, cfg.preLltv, cfg.adapter.lltv(marketId), cfg.preLIF1, cfg.preLIF2, cfg.preLCF1, cfg.preLCF2);
    }

    /* ---------- Internal math ---------- */
    function _lifLcf(uint256 ltv, uint256 preLltv, uint256 lltv, uint256 lif1, uint256 lif2, uint256 lcf1, uint256 lcf2)
        internal
        pure
        returns (uint256 lif, uint256 lcf)
    {
        uint256 quotient = (ltv - preLltv).wDiv(lltv - preLltv);
        lif = quotient.wMul(lif2 - lif1) + lif1;
        lcf = quotient.wMul(lcf2 - lcf1) + lcf1;
    }

    function _ltv(ILendingAdapter.PositionView memory p, IPriceOracle oracle) internal view returns (uint256) {
        uint256 px = oracle.price();
        require(px > 0, "BAD_PX");
        uint256 collateralQuoted = p.collateral.mulDivDown(px, 1e18);
        return p.debt.wDiv(collateralQuoted);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
