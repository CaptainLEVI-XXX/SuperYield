// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WadMath} from "../libraries/WadMath.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";

abstract contract PreLiquidationCore {
    using WadMath for uint256;
    using CustomRevert for bytes4;

    struct PreLiquidationParams {
        uint256 preLltv; // WAD - Start of pre-liquidation band
        uint256 preLCF1; // WAD - Close factor at preLltv
        uint256 preLCF2; // WAD - Close factor at LLTV
        uint256 preLIF1; // WAD - Incentive at preLltv (>= 1e18)
        uint256 preLIF2; // WAD - Incentive at LLTV
        uint256 dustThreshold; // Minimum position size in USD to pre-liquidate
    }

    struct LiquidationAmounts {
        uint256 repayAmount;
        uint256 seizeAmount;
        uint256 lif;
        uint256 lcf;
    }

    // Errors
    error InvalidLTV();
    error InvalidParameters();

    /**
     * @notice Calculate LIF and LCF based on current LTV
     * @dev Linear interpolation between preLltv and LLTV
     */
    function calculateLifLcf(
        uint256 currentLtv,
        uint256 preLltv,
        uint256 protocolLltv,
        PreLiquidationParams memory params
    ) public pure returns (uint256 lif, uint256 lcf) {
        // Ensure we're in valid range
        if (currentLtv <= preLltv || currentLtv > protocolLltv) {
            revert InvalidLTV();
        }

        // Linear interpolation quotient: 0 at preLltv, 1 at protocolLltv
        uint256 quotient = (currentLtv - preLltv).wDiv(protocolLltv - preLltv);

        // LIF increases linearly from preLIF1 to preLIF2
        lif = params.preLIF1 + quotient.wMul(params.preLIF2 - params.preLIF1);

        // LCF increases linearly from preLCF1 to preLCF2
        lcf = params.preLCF1 + quotient.wMul(params.preLCF2 - params.preLCF1);
    }

    /**
     * @notice Validate pre-liquidation parameters
     * @dev Ensures parameters maintain position health
     */
    function validateParams(PreLiquidationParams memory params, uint256 protocolLltv) public pure {
        require(params.preLltv < protocolLltv, "preLltv >= LLTV");
        require(params.preLCF1 <= params.preLCF2, "LCF not monotonic");
        require(params.preLCF1 <= WadMath.WAD, "LCF1 > 100%");
        require(params.preLIF1 >= WadMath.WAD, "LIF1 < 100%");
        require(params.preLIF1 <= params.preLIF2, "LIF not monotonic");
        require(params.preLIF2 <= WadMath.WAD.wDiv(protocolLltv), "LIF2 too high");
    }

    function calculateRepayAmount(
        uint256 collateralUsd,
        uint256 debtUsd,
        uint256 targetLtv,
        uint256 lcf,
        uint256 maxRepayPct,
        uint256 dustThreshold
    ) internal pure returns (uint256 repayAmount) {
        // Calculate amount needed to reach target LTV
        uint256 targetDebtUsd = targetLtv.wMul(collateralUsd);
        uint256 desiredRepay = debtUsd > targetDebtUsd ? debtUsd - targetDebtUsd : 0;

        // Apply LCF constraint
        uint256 maxByLcf = lcf.wMul(debtUsd);

        // Apply max repay percentage constraint
        uint256 maxByPct = maxRepayPct.wMul(debtUsd);

        // Take minimum of all constraints
        repayAmount = desiredRepay;
        if (repayAmount > maxByLcf) repayAmount = maxByLcf;
        if (repayAmount > maxByPct) repayAmount = maxByPct;

        // Check dust threshold
        if (repayAmount < dustThreshold) {
            repayAmount = 0;
        }
    }

    /**
     * @notice Calculate optimal liquidation amounts
     */
    function calculateLiquidationAmounts(
        uint256 collateralUsd,
        uint256 debtUsd,
        uint256 currentLtv,
        uint256 targetLtv,
        uint256 protocolLltv,
        uint256 maxRepayPct,
        PreLiquidationParams memory params
    ) public pure returns (LiquidationAmounts memory amounts) {
        // Get LIF and LCF for current position
        (amounts.lif, amounts.lcf) = calculateLifLcf(currentLtv, params.preLltv, protocolLltv, params);

        // Calculate desired repay to reach target LTV
        uint256 targetDebtUsd = targetLtv.wMul(collateralUsd);
        uint256 desiredRepay = debtUsd > targetDebtUsd ? debtUsd - targetDebtUsd : 0;

        // Apply constraints
        uint256 maxByLcf = amounts.lcf.wMul(debtUsd);
        uint256 maxByPct = maxRepayPct.wMul(debtUsd);

        // Take minimum of all constraints
        amounts.repayAmount = _min(desiredRepay, _min(maxByLcf, maxByPct));

        // Check dust threshold
        if (amounts.repayAmount < params.dustThreshold) {
            amounts.repayAmount = 0;
            amounts.seizeAmount = 0;
            return amounts;
        }

        // Calculate collateral to seize
        amounts.seizeAmount = amounts.repayAmount.wMul(amounts.lif);

        // Ensure we don't seize more than available
        if (amounts.seizeAmount > collateralUsd) {
            amounts.seizeAmount = collateralUsd;
            amounts.repayAmount = amounts.seizeAmount.wDiv(amounts.lif);
        }
    }

    /**
     * @notice Check if position is in pre-liquidation zone
     */
    function isPreLiquidatable(uint256 currentLtv, uint256 preLltv, uint256 protocolLltv) public pure returns (bool) {
        return currentLtv > preLltv && currentLtv <= protocolLltv;
    }

    /**
     * @notice Calculate profit for keeper
     */
    function calculateKeeperProfit(uint256 seizeAmount, uint256 repayAmount) public pure returns (uint256) {
        return seizeAmount > repayAmount ? seizeAmount - repayAmount : 0;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
