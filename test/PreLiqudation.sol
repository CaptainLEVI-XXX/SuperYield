// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {console} from "forge-std/console.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {PreLiquidationCore} from "../src/abstract/PreLiquidationCore.sol";
import {WadMath} from "../src/libraries/WadMath.sol";

contract PreLiquidationTest is BaseTest {
    using SafeTransferLib for address;
    using WadMath for *;

    function testPreLiquidation() public {
        // Open position at high LTV
        uint256 positionId = _openHighLtvPosition();
        console.log("Opened position ID:", positionId);

        // Configure pre-liquidation parameters
        PreLiquidationCore.PreLiquidationParams memory params = PreLiquidationCore.PreLiquidationParams({
            preLltv: 0.7e18,    // 70% - start of pre-liquidation band
            preLCF1: 0.1e18,    // 10% - close factor at preLltv
            preLCF2: 0.5e18,    // 50% - close factor at protocol LLTV
            preLIF1: 1.02e18,   // 102% - liquidation incentive at preLltv (2% bonus)
            preLIF2: 1.05e18,   // 105% - liquidation incentive at protocol LLTV (5% bonus)
            dustThreshold: 50e18 // $50 minimum position size
        });

        // Configure market
        vm.prank(admin);
        preLiquidationManager.configureMarket(
            marketId,
            positionId,
            address(aaveAdapter),
            params,
            0.65e18,  // targetLtv - 65%
            1e18,     // maxRepayPct - 100%
            0,        // cooldown - no cooldown
            false     // flashLoanEnabled
        );

        // Check initial position state
        (uint256 initialCollateralUsd, uint256 initialDebtUsd) = aaveAdapter.getPositionUsd(
            marketId, 
            address(strategyManager)
        );

        console.log("Initial collateral USD:", initialCollateralUsd);
        console.log("Initial debt USD:", initialDebtUsd);

        uint256 initialLtv = initialDebtUsd.wDiv(initialCollateralUsd);
        console.log("Initial LTV:", initialLtv / 1e16, "%");

        // Check if eligible for pre-liquidation
        (
            bool eligible,
            uint256 currentLtv,
            uint256 lif,
            uint256 lcf,
            uint256 optimalRepayUsd,
            uint256 expectedSeizeUsd,
            uint256 expectedProfit
        ) = preLiquidationManager.checkPosition(marketId);

        assertTrue(eligible, "Position should be eligible for pre-liquidation");
        console.log("Current LTV:", currentLtv / 1e16, "%");
        console.log("Optimal repay USD:", optimalRepayUsd);
        console.log("Expected seize USD:", expectedSeizeUsd);
        console.log("Expected profit:", expectedProfit);

        // Prepare keeper with WETH for pre-liquidation
        uint256 repayAmountTokens = aaveAdapter.usdToTokenUnits(address(WETH), optimalRepayUsd);
        deal(address(WETH), address(this), repayAmountTokens * 2);
        WETH.safeApprove(address(preLiquidationManager), repayAmountTokens * 2);

        // Execute pre-liquidation
        uint256 gasBefore = gasleft();
        (uint256 actualRepaidUsd, uint256 actualSeizedUsd) = preLiquidationManager.preLiquidate(
            marketId,
            optimalRepayUsd,
            0 // minSeizeUsd
        );
        uint256 gasAfter = gasleft();

        console.log("Gas used for pre-liquidation:", gasBefore - gasAfter);
        console.log("Actual repaid USD:", actualRepaidUsd);
        console.log("Actual seized USD:", actualSeizedUsd);
        console.log("Keeper profit USD:", actualSeizedUsd - actualRepaidUsd);

        // Check position after pre-liquidation
        (uint256 finalCollateralUsd, uint256 finalDebtUsd) = aaveAdapter.getPositionUsd(
            marketId, 
            address(strategyManager)
        );

        console.log("Final collateral USD:", finalCollateralUsd);
        console.log("Final debt USD:", finalDebtUsd);

        if (finalDebtUsd > 0) {
            uint256 finalLtv = finalDebtUsd.wDiv(finalCollateralUsd);
            console.log("Final LTV:", finalLtv / 1e16, "%");
            assertLt(finalLtv, currentLtv, "LTV should improve after pre-liquidation");
        }

        // Verify improvements
        assertLt(finalCollateralUsd, initialCollateralUsd, "Collateral should decrease");
        assertLt(finalDebtUsd, initialDebtUsd, "Debt should decrease");
    }

    function testPreLiquidateWithFlashLoan() public {
        // Open position at high LTV
        uint256 positionId = _openHighLtvPosition();
        console.log("Opened position ID:", positionId);

        // Configure with flash loan enabled
        PreLiquidationCore.PreLiquidationParams memory params = PreLiquidationCore.PreLiquidationParams({
            preLltv: 0.7e18,
            preLCF1: 0.1e18,
            preLCF2: 0.5e18,
            preLIF1: 1.02e18,
            preLIF2: 1.05e18,
            dustThreshold: 50e18
        });

        vm.prank(admin);
        preLiquidationManager.configureMarket(
            marketId,
            positionId,
            address(aaveAdapter),
            params,
            0.65e18,
            1e18,
            0,
            true // Enable flash loan
        );

        // Get position metrics
        (uint256 initialCollateralUsd, uint256 initialDebtUsd) = aaveAdapter.getPositionUsd(
            marketId, 
            address(strategyManager)
        );

        uint256 initialLtv = initialDebtUsd.wDiv(initialCollateralUsd);
        console.log("Initial LTV:", initialLtv / 1e16, "%");

        // Check eligibility
        (
            bool eligible,
            ,
            ,
            ,
            uint256 optimalRepayUsd,
            uint256 expectedSeizeUsd,
            
        ) = preLiquidationManager.checkPosition(marketId);

        assertTrue(eligible, "Position should be eligible");

        // Calculate seized amount for swap
        uint256 seizeAmountTokens = aaveAdapter.usdToTokenUnits(address(USDC), expectedSeizeUsd);
        
        DexHelper.DexSwapCalldata memory swapData = buildSwapParams(
            USDC,
            WETH,
            seizeAmountTokens,
            address(preLiquidationManager)
        );

        // Execute flash loan pre-liquidation
        uint256 gasBefore = gasleft();
        preLiquidationManager.preLiquidateWithFlashLoan(
            marketId,
            optimalRepayUsd,
            5,
            swapData
        );
        uint256 gasAfter = gasleft();

        console.log("Gas used for flash loan pre-liquidation:", gasBefore - gasAfter);

        // Check final state
        (uint256 finalCollateralUsd, uint256 finalDebtUsd) = aaveAdapter.getPositionUsd(
            marketId, 
            address(strategyManager)
        );

        console.log("Final collateral USD:", finalCollateralUsd);
        console.log("Final debt USD:", finalDebtUsd);

        if (finalDebtUsd > 0) {
            uint256 finalLtv = finalDebtUsd.wDiv(finalCollateralUsd);
            console.log("Final LTV:", finalLtv / 1e16, "%");
            assertLt(finalLtv, initialLtv, "LTV should improve");
        }

        assertLt(finalCollateralUsd, initialCollateralUsd, "Collateral should decrease");
        assertLt(finalDebtUsd, initialDebtUsd, "Debt should decrease");
    }

    function _openHighLtvPosition() internal returns (uint256) {
        // Alice deposits to vault
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6;
        DexHelper.DexSwapCalldata memory swapData = buildSwapParams(
            WETH, 
            USDC, 
            1.4e18, // Higher borrow for 74% LTV
            address(strategyManager)
        );
        
        vm.prank(admin);
        return strategyManager.openPosition(
            address(superVault),
            address(USDC),
            address(WETH),
            FIVE_THOUSAND_DOLLAR,
            1.4e18,
            flashLoanAmount,
            venue,
            5,
            swapData
        );
    }
}