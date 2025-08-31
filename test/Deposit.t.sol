// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./Base.t.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";

contract DepositTest is BaseTest {
    using SafeTransferLib for address;

    function testDepositShareValueIncrease() public {
        // Alice deposits
        vm.prank(alice);
        superVault.deposit(SMALL_AMOUNT_USDC, alice);
        
        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC);
        assertEq(superVault.balanceOf(alice), SMALL_AMOUNT_USDC);

        // Bob deposits
        vm.prank(bob);
        superVault.deposit(SMALL_AMOUNT_USDC, bob);
        
        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC * 2);
        assertEq(superVault.balanceOf(bob), SMALL_AMOUNT_USDC);

        // Simulate yield by donating to vault
        uint256 randomValue = 5e6;
        deal(USDC, address(this), randomValue);
        USDC.safeTransfer(address(superVault), randomValue);
        
        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC * 2 + randomValue);

        // Alice deposits again - should get fewer shares
        vm.prank(alice);
        uint256 shares = superVault.deposit(randomValue, alice);
        assertGt(randomValue, shares);
    }

    function testDepositGasInfo() public {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        superVault.deposit(SMALL_AMOUNT_USDC, alice);
        uint256 gasAfter = gasleft();
        
        console.log("Gas used for deposit:", gasBefore - gasAfter);
    }

    function testDepositWithAssetWrapper() public {
        DexHelper.DexSwapCalldata memory data = buildSwapParams(
            WETH, 
            USDC, 
            SMALL_AMOUNT_WETH, 
            address(assetWrapper)
        );

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assetWrapper.deposit(data, alice, SMALL_AMOUNT_WETH);
        uint256 gasAfter = gasleft();
        
        console.log("Gas used for asset wrapper deposit:", gasBefore - gasAfter);
        console.log("Alice shares:", superVault.balanceOf(alice));
        
        assertGt(superVault.balanceOf(alice), 0);
    }

    function testDepositWithEthWrapper() public {
        DexHelper.DexSwapCalldata memory data = buildSwapParams(
            WETH, 
            USDC, 
            SMALL_AMOUNT_WETH, 
            address(ethWrapper)
        );

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ethWrapper.deposit{value: SMALL_AMOUNT_WETH}(data, alice);
        uint256 gasAfter = gasleft();
        
        console.log("Gas used for ETH wrapper deposit:", gasBefore - gasAfter);
        console.log("Alice shares:", superVault.balanceOf(alice));
        
        assertGt(superVault.balanceOf(alice), 0);
    }

    function testWithdraw() public {
        // Setup: Alice deposits
        vm.prank(alice);
        superVault.deposit(SMALL_AMOUNT_USDC, alice);

        // Withdraw half
        uint256 withdrawAmount = SMALL_AMOUNT_USDC / 2;
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        superVault.withdraw(withdrawAmount, alice, alice);
        uint256 gasAfter = gasleft();

        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC / 2);
        assertEq(superVault.balanceOf(alice), SMALL_AMOUNT_USDC / 2);
        
        console.log("Gas used for withdrawal:", gasBefore - gasAfter);
    }

    function testWithdrawWithAssetWrapper() public {
        // Setup: Alice deposits
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        uint256 wethBalanceBefore = WETH.balanceOf(alice);

        DexHelper.DexSwapCalldata memory data = buildSwapParams(
            USDC, 
            WETH, 
            LARGE_AMOUNT_USDC, 
            address(assetWrapper)
        );

        vm.prank(alice);
        superVault.approve(address(assetWrapper), LARGE_AMOUNT_USDC);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assetWrapper.withdraw(data, LARGE_AMOUNT_USDC, alice);
        uint256 gasAfter = gasleft();

        uint256 wethReceived = WETH.balanceOf(alice) - wethBalanceBefore;
        
        assertGt(wethReceived, 0);
        console.log("WETH received:", wethReceived);
        console.log("Gas used for asset wrapper withdrawal:", gasBefore - gasAfter);
    }

    function testWithdrawWithEthWrapper() public {
        // Setup: Alice deposits
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        DexHelper.DexSwapCalldata memory data = buildSwapParams(
            USDC, 
            WETH, 
            LARGE_AMOUNT_USDC, 
            address(ethWrapper)
        );

        vm.prank(alice);
        superVault.approve(address(ethWrapper), LARGE_AMOUNT_USDC);

        uint256 ethBefore = alice.balance;
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ethWrapper.withdraw(data, LARGE_AMOUNT_USDC, alice);
        uint256 gasAfter = gasleft();

        uint256 ethReceived = alice.balance - ethBefore;
        
        assertGt(ethReceived, 0);
        console.log("ETH received:", ethReceived);
        console.log("Gas used for ETH wrapper withdrawal:", gasBefore - gasAfter);
    }
}