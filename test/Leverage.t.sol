// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./Base.t.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {WadMath} from "../src/libraries/WadMath.sol";

contract LeverageTest is BaseTest {
    using SafeTransferLib for address;
    using WadMath for *;

    function testOpenPosition() public {
        // Setup: Alice deposits to vault
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6; // $4000 USDC
        DexHelper.DexSwapCalldata memory swapData = buildSwapParams(
            WETH, 
            USDC, 
            1e18, 
            address(strategyManager)
        );
        
        uint256 gasBefore = gasleft();
        vm.prank(admin);
        uint256 positionId = strategyManager.openPosition(
            address(superVault),
            address(USDC),
            address(WETH),
            FIVE_THOUSAND_DOLLAR,
            1e18,
            flashLoanAmount,
            venue,
            5,
            swapData
        );
        uint256 gasAfter = gasleft();
        
        console.log("Gas used for opening position:", gasBefore - gasAfter);
        console.log("Position ID created:", positionId);
        
        assertGt(positionId, 0);
    }

    function testClosePosition() public {
        // Setup: Open a position first
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6;
        DexHelper.DexSwapCalldata memory swapData = buildSwapParams(
            WETH, 
            USDC, 
            1e18, 
            address(strategyManager)
        );

        vm.prank(admin);
        uint256 positionId = strategyManager.openPosition(
            address(superVault),
            address(USDC),
            address(WETH),
            FIVE_THOUSAND_DOLLAR,
            1e18,
            flashLoanAmount,
            venue,
            5,
            swapData
        );

        // Close the position
        DexHelper.DexSwapCalldata memory closeSwapData = buildSwapParams(
            USDC, 
            WETH, 
            FIVE_THOUSAND_DOLLAR, 
            address(strategyManager)
        );

        uint256 gasBefore = gasleft();
        vm.prank(admin);
        strategyManager.closePosition(positionId, 1e18, FIVE_THOUSAND_DOLLAR, closeSwapData, 5);
        uint256 gasAfter = gasleft();
        
        console.log("Gas used for closing position:", gasBefore - gasAfter);
    }

    function testMigratePosition() public {
        // Setup: Open a position
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6;
        DexHelper.DexSwapCalldata memory swapData = buildSwapParams(
            WETH, 
            USDC, 
            1e18, 
            address(strategyManager)
        );
        
        vm.prank(admin);
        uint256 positionId = strategyManager.openPosition(
            address(superVault),
            address(USDC),
            address(WETH),
            FIVE_THOUSAND_DOLLAR,
            1e18,
            flashLoanAmount,
            venue,
            5,
            swapData
        );

        // Migrate the position
        uint256 gasBefore = gasleft();
        vm.prank(admin);
        strategyManager.migratePosition(positionId, venue, 5);
        uint256 gasAfter = gasleft();
        
        console.log("Gas used for migrating position:", gasBefore - gasAfter);
    }

//     function testRebalanceToTargetLTV() public {
//         // Setup: Open a position
//         vm.prank(alice);
//         superVault.deposit(LARGE_AMOUNT_USDC, alice);

//         bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
//         uint256 flashLoanAmount = 4000e6;
//         DexHelper.DexSwapCalldata memory swapData = buildSwapParams(
//             WETH, 
//             USDC, 
//             1e18, 
//             address(strategyManager)
//         );

//         vm.prank(admin);
//         uint256 positionId = strategyManager.openPosition(
//             address(superVault),
//             address(USDC),
//             address(WETH),
//             5000e6,
//             1e18,
//             flashLoanAmount,
//             venue,
//             5,
//             swapData
//         );

//         // Get current LTV
//         (uint256 collateralUsd, uint256 debtUsd) = aaveAdapter.getPositionUsd(
//             marketId, 
//             address(strategyManager)
//         );

//         console.log("Initial collateral USD:", collateralUsd);
//         console.log("Initial debt USD:", debtUsd);

//         uint256 currentLtv = debtUsd.wDiv(collateralUsd);
//         console.log("Current LTV:", currentLtv / 1e16, "%");

//         // Set target LTV 5% higher
//         uint256 targetLtv = currentLtv + 5e16;
//         console.log("Target LTV:", targetLtv / 1e16, "%");

//         // Calculate rebalance parameters
//         uint256 targetDebtUsd = collateralUsd.wMul(targetLtv);
//         uint256 deltaDebtUsd = targetDebtUsd - debtUsd;
//         uint256 deltaBorrowWeth = aaveAdapter.usdToTokenUnits(address(WETH), deltaDebtUsd);

//         DexHelper.DexSwapCalldata memory rebalanceSwap = buildSwapParams(
//             WETH, 
//             USDC, 
//             deltaBorrowWeth, 
//             address(strategyManager)
//         );

//         // Execute rebalance
//         vm.prank(admin);
//         strategyManager.rebalanceToTargetLTV(
//             positionId,
//             targetLtv,
//             deltaBorrowWeth,
//             deltaDebtUsd,
//             rebalanceSwap,
//             5
//         );

//         // Verify new LTV
//         (uint256 newCollateralUsd, uint256 newDebtUsd) = aaveAdapter.getPositionUsd(
//             marketId, 
//             address(strategyManager)
//         );
        
//         uint256 newLtv = newDebtUsd.wDiv(newCollateralUsd);
//         console.log("New LTV:", newLtv / 1e16, "%");
        
//         assertApproxEqAbs(newLtv, targetLtv, 0.01e18); // Within 1%
//     }
}