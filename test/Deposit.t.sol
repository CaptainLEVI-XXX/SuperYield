// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {SuperVault} from "../src/SuperVault.sol";
import {BaseTest} from "./Base.t.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";

contract DepositTest is BaseTest {
    using SafeTransferLib for address;

    function testDepositShareValueIncrease() public {
        uint256 amount = 10e6;
        uint256 randomValue = 5e6;

        vm.prank(alice);
        superVault.deposit(amount, alice);

        assertEq(superVault.totalAssets(), amount);
        assertEq(superVault.balanceOf(alice), amount);

        vm.prank(bob);
        superVault.deposit(amount, bob);

        assertEq(superVault.totalAssets(), amount + amount);
        assertEq(superVault.balanceOf(bob), amount);

        deal(USDC, address(this), randomValue);
        USDC.safeTransfer(address(superVault), randomValue);

        assertEq(superVault.totalAssets(), amount + amount + randomValue);

        vm.prank(alice);
        uint256 shares = superVault.deposit(randomValue, alice);
        assertGt(randomValue, shares);
    }

    function testDepositGasInfo() public {
        uint256 amount = 10e6;
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        superVault.deposit(amount, alice);
        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);

        //180677 for deposit operation
    }

    function testDepositWithAssetWrapper() public {
        uint256 amount = 10e18;
        DexHelper.DexSwapCalldata memory data = _buildSwapParams(WETH, USDC, amount, address(assetWrapper));

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assetWrapper.deposit(data, alice, amount);
        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);
        // SuperYield - 351380
        // InstaDapp - 698,653

        console.log("Alice shares: ", superVault.balanceOf(alice));
    }

    function testDepositWithEthWrapper() public {
        uint256 amount = 10e18;
        DexHelper.DexSwapCalldata memory data = _buildSwapParams(WETH, USDC, amount, address(ethWrapper));

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ethWrapper.deposit{value: amount}(data, alice);
        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);
        // SuperYield - 352357
        // InstaDapp - 698,653

        console.log("Alice shares: ", superVault.balanceOf(alice));
    }

    function testWithdraw() public {
        uint256 amount = 10e6;

        vm.prank(alice);
        superVault.deposit(amount, alice);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        superVault.withdraw(amount / 2, alice, alice);
        uint256 gasAfter = gasleft();

        assertEq(superVault.totalAssets(), amount / 2);
        assertEq(superVault.balanceOf(alice), amount / 2);

        console.log("Gas used: ", gasBefore - gasAfter); //27545
    }

    function testWithdrawWithAssetWrapper() public {
        uint256 amount = 5000e6;

        vm.prank(alice);
        superVault.deposit(amount, alice);

        uint256 wethBalanceBefore = WETH.balanceOf(alice);

        DexHelper.DexSwapCalldata memory data = _buildSwapParams(USDC, WETH, amount, address(assetWrapper));

        vm.prank(alice);
        superVault.approve(address(assetWrapper), amount);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assetWrapper.withdraw(data, amount, alice);
        uint256 gasAfter = gasleft();

        //197214
        //Instadapp -442,419

        uint256 wethBalanceAfter = WETH.balanceOf(alice);

        assertGt(wethBalanceAfter, wethBalanceBefore);

        console.log("Alice WETH balance: ", wethBalanceAfter - wethBalanceBefore);

        console.log("Gas used: ", gasBefore - gasAfter); //27545
    }

    function testWithdrawWithEthWrapper() public {
        uint256 amount = 5000e6;

        vm.prank(alice);
        superVault.deposit(amount, alice);

        DexHelper.DexSwapCalldata memory data = _buildSwapParams(USDC, WETH, amount, address(ethWrapper));

        vm.prank(alice);
        superVault.approve(address(ethWrapper), amount);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ethWrapper.withdraw(data, amount, alice);
        uint256 gasAfter = gasleft();

        //197214
        //Instadapp -442,419

        assertGt(WETH.balanceOf(alice), 1e18);

        console.log("Alice shares: ", alice.balance);

        console.log("Gas used: ", gasBefore - gasAfter); //27545
    }
}
