// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {console} from "forge-std/console.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {PreLiquidationCore} from "../src/abstract/PreLiquidationCore.sol";
import {AaveV3Adapter} from "../src/adapter/AaveV3.sol";
import {WadMath} from "../src/libraries/WadMath.sol";

contract PreLiquidationTest is BaseTest {
    using SafeTransferLib for address;
    using WadMath for *;

    function testPreLiquidation() public {
        // Open position at LTV 74%
        uint256 positionId = _openPosition();
        console.log("Opened position ID:", positionId);

        // Configure pre-liquidation parameters
        PreLiquidationCore.PreLiquidationParams memory params = PreLiquidationCore.PreLiquidationParams({
            preLltv: 0.7e18, // 70% - start of pre-liquidation band
            preLCF1: 0.1e18, // 10% - close factor at preLltv
            preLCF2: 0.5e18, // 50% - close factor at protocol LLTV
            preLIF1: 1.02e18, // 102% - liquidation incentive at preLltv (2% bonus)
            preLIF2: 1.05e18, // 105% - liquidation incentive at protocol LLTV (5% bonus)
            dustThreshold: 50e18 // $50 minimum position size
        });

        // Configure market in PreLiquidationManager
        vm.prank(admin);
        preLiquidationManager.configureMarket(
            marketId,
            positionId,
            address(aaveAdapter),
            params,
            0.65e18, // targetLtv - 65% (target after pre-liquidation)
            1e18, // maxRepayPct - 100% max debt repayment
            0, // cooldown - no cooldown for test
            false // flashLoanEnabled - disable for this test
        );
        console.log("Market configured");

        // Check initial position state
        (uint256 initialCollateralUsd, uint256 initialDebtUsd) =
            aaveAdapter.getPositionUsd(marketId, address(strategyManager));

        console.log("Initial collateral USD:", initialCollateralUsd);
        console.log("Initial debt USD:", initialDebtUsd);

        uint256 initialLtv = initialDebtUsd.wDiv(initialCollateralUsd);
        console.log("Initial LTV:", initialLtv / 1e16, "%");

        // Verify position is now eligible for pre-liquidation
        (
            bool eligible,
            uint256 currentLtv,
            uint256 lif,
            uint256 lcf,
            uint256 optimalRepayUsd,
            uint256 expectedSeizeUsd,
            uint256 expectedProfit
        ) = preLiquidationManager.checkPosition(marketId);

        assertTrue(eligible, "Position should be eligible for pre-liquidation after price drop");
        console.log("Current LTV after price change:", currentLtv);
        console.log("LIF (Liquidation Incentive Factor):", lif);
        console.log("LCF (Liquidation Close Factor):", lcf);
        console.log("Optimal repay USD:", optimalRepayUsd);
        console.log("Expected seize USD:", expectedSeizeUsd);
        console.log("Expected profit:", expectedProfit);
        console.log("============================");
        console.log(
            "Expected LTV ",
            (initialDebtUsd - optimalRepayUsd).wDiv(initialCollateralUsd - expectedSeizeUsd) / 1e16,
            "%"
        );

        // Verify LTV is in pre-liquidation range
        assertGt(currentLtv, params.preLltv, "LTV should be above pre-liquidation threshold");
        assertGt(optimalRepayUsd, 0, "Should have positive repay amount");
        assertGt(expectedSeizeUsd, 0, "Should have positive seize amount");

        // Prepare keeper with USDC for pre-liquidation
        uint256 repayAmountUsd = optimalRepayUsd;
        uint256 repayAmountTokens = aaveAdapter.usdToTokenUnits(address(WETH), repayAmountUsd);

        // Give keeper enough USDC (double the needed amount for safety)
        deal(address(WETH), address(this), repayAmountTokens * 2);

        // Approve PreLiquidationManager to spend USDC
        WETH.safeApprove(address(preLiquidationManager), repayAmountTokens * 2);

        console.log("Keeper prepared with WETH tokens:", repayAmountTokens);

        // Execute pre-liquidation
        uint256 balanceBefore = USDC.balanceOf(address(this));
        uint256 gasBefore = gasleft();

        (uint256 actualRepaidUsd, uint256 actualSeizedUsd) = preLiquidationManager.preLiquidate(
            marketId,
            repayAmountUsd, // maxRepayUsd
            0 // minSeizeUsd (no slippage protection for test)
        ); //411690

        uint256 gasLeft = gasleft();
        console.log("Gas used:", gasBefore - gasLeft);

        uint256 balanceAfter = USDC.balanceOf(address(this));
        uint256 wethReceived = balanceAfter - balanceBefore;

        console.log("Pre-liquidation executed successfully");
        console.log("Actual repaid USD:", actualRepaidUsd);
        console.log("Actual seized USD:", actualSeizedUsd);
        console.log("WETH tokens received:", wethReceived);

        // Verify Keeper profit calculation
        uint256 actualProfit = actualSeizedUsd - actualRepaidUsd;
        console.log("Actual profit USD:", actualProfit);

        // Check position state after pre-liquidation
        (uint256 finalCollateralUsd, uint256 finalDebtUsd) =
            aaveAdapter.getPositionUsd(marketId, address(strategyManager));

        console.log("Final collateral USD:", finalCollateralUsd);
        console.log("Final debt USD:", finalDebtUsd);

        if (finalDebtUsd > 0) {
            uint256 finalLtv = finalDebtUsd.wDiv(finalCollateralUsd);
            console.log("Final LTV:", finalLtv);

            // Verify LTV improved
            assertLt(finalLtv, currentLtv, "LTV should improve after pre-liquidation");
        }

        // Verify collateral and debt decreased
        assertLt(finalCollateralUsd, initialCollateralUsd, "Collateral should decrease");
        assertLt(finalDebtUsd, initialDebtUsd, "Debt should decrease");
    }

    function testPreLiquidateWithFlashLoan() public {
        // Open position at LTV 74%
        uint256 positionId = _openPosition();
        console.log("Opened position ID:", positionId);

        // Configure pre-liquidation parameters
        PreLiquidationCore.PreLiquidationParams memory params = PreLiquidationCore.PreLiquidationParams({
            preLltv: 0.7e18, // 70% - start of pre-liquidation band
            preLCF1: 0.1e18, // 10% - close factor at preLltv
            preLCF2: 0.5e18, // 50% - close factor at protocol LLTV
            preLIF1: 1.02e18, // 102% - liquidation incentive at preLltv (2% bonus)
            preLIF2: 1.05e18, // 105% - liquidation incentive at protocol LLTV (5% bonus)
            dustThreshold: 50e18 // $50 minimum position size
        });

        // Configure market in PreLiquidationManager
        vm.prank(admin);
        preLiquidationManager.configureMarket(
            marketId,
            positionId,
            address(aaveAdapter),
            params,
            0.65e18, // targetLtv - 65% (target after pre-liquidation)
            1e18, // maxRepayPct - 100% max debt repayment
            0, // cooldown - no cooldown for test
            true // flashLoanEnabled - disable for this test
        );
        console.log("Market configured");

        // Check initial position state
        (uint256 initialCollateralUsd, uint256 initialDebtUsd) =
            aaveAdapter.getPositionUsd(marketId, address(strategyManager));

        console.log("Initial collateral USD:", initialCollateralUsd);
        console.log("Initial debt USD:", initialDebtUsd);

        uint256 initialLtv = initialDebtUsd.wDiv(initialCollateralUsd);
        console.log("Initial LTV:", initialLtv / 1e16, "%");

        // Verify position is now eligible for pre-liquidation
        (
            bool eligible,
            uint256 currentLtv,
            uint256 lif,
            uint256 lcf,
            uint256 optimalRepayUsd,
            uint256 expectedSeizeUsd,
            uint256 expectedProfit
        ) = preLiquidationManager.checkPosition(marketId);

        assertTrue(eligible, "Position should be eligible for pre-liquidation after price drop");
        console.log("Current LTV after price change:", currentLtv);
        console.log("LIF (Liquidation Incentive Factor):", lif);
        console.log("LCF (Liquidation Close Factor):", lcf);
        console.log("Optimal repay USD:", optimalRepayUsd);
        console.log("Expected seize USD:", expectedSeizeUsd);
        console.log("Expected profit:", expectedProfit);
        console.log("============================");
        console.log(
            "Expected LTV ",
            (initialDebtUsd - optimalRepayUsd).wDiv(initialCollateralUsd - expectedSeizeUsd) / 1e16,
            "%"
        );

        // Verify LTV is in pre-liquidation range
        assertGt(currentLtv, params.preLltv, "LTV should be above pre-liquidation threshold");
        assertGt(optimalRepayUsd, 0, "Should have positive repay amount");
        assertGt(expectedSeizeUsd, 0, "Should have positive seize amount");

        // Prepare keeper with USDC for pre-liquidation
        uint256 repayAmountUsd = optimalRepayUsd;
        uint256 repayAmountTokens = aaveAdapter.usdToTokenUnits(address(WETH), repayAmountUsd);

        // Give keeper enough USDC (double the needed amount for safety)
        // deal(address(WETH), address(this), repayAmountTokens * 2);

        // // Approve PreLiquidationManager to spend USDC
        // WETH.safeApprove(address(preLiquidationManager), repayAmountTokens * 2);

        // console.log("Keeper prepared with WETH tokens:", repayAmountTokens);

        // Execute pre-liquidation
        uint256 balanceBefore = USDC.balanceOf(address(this));

        uint256 seizeAmount = 2290167005;

        console.log("--++++++++++++----seizeAmount-++++++++++++++--", seizeAmount);

        DexHelper.DexSwapCalldata memory swapData =
            _buildSwapParams(USDC, WETH, seizeAmount, address(preLiquidationManager));

        uint256 gasBefore = gasleft();

        preLiquidationManager.preLiquidateWithFlashLoan(
            marketId,
            repayAmountUsd, // maxRepayUsd// minSeizeUsd (no slippage protection for test),
            5,
            swapData
        ); //587987
        uint256 gasLeft = gasleft();
        console.log("Gas used:", gasBefore - gasLeft);

        uint256 balanceAfter = WETH.balanceOf(address(this));
        uint256 wethReceived = balanceAfter - balanceBefore;

        console.log("Pre-liquidation executed successfully");
        // console.log("Actual repaid USD:", actualRepaidUsd);
        // console.log("Actual seized USD:", actualSeizedUsd);
        console.log("WETH tokens received:", wethReceived);

        // Verify Keeper profit calculation
        // uint256 actualProfit = actualSeizedUsd - actualRepaidUsd;
        // console.log("Actual profit USD:", actualProfit);

        // Check position state after pre-liquidation
        (uint256 finalCollateralUsd, uint256 finalDebtUsd) =
            aaveAdapter.getPositionUsd(marketId, address(strategyManager));

        console.log("Final collateral USD:", finalCollateralUsd);
        console.log("Final debt USD:", finalDebtUsd);

        if (finalDebtUsd > 0) {
            uint256 finalLtv = finalDebtUsd.wDiv(finalCollateralUsd);
            console.log("Final LTV:", finalLtv);

            // Verify LTV improved
            assertLt(finalLtv, currentLtv, "LTV should improve after pre-liquidation");
        }

        // Verify collateral and debt decreased
        assertLt(finalCollateralUsd, initialCollateralUsd, "Collateral should decrease");
        assertLt(finalDebtUsd, initialDebtUsd, "Debt should decrease");
    }

    function _openPosition() internal returns (uint256 positionId) {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6;
        DexHelper.DexSwapCalldata memory swapData = _buildSwapParams(WETH, USDC, 1e18, address(strategyManager));
        vm.prank(admin);
        positionId = strategyManager.openPosition(
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
        // created a position at 74%LTV
        //1,012,791 ---- gas  used our executeOperation is 544,307--gas used by FlashLoan = 468,484
        //1,010.336
        //1020727
    }
}
