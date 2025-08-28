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
        uint256 randomValue = 5e6;

        vm.prank(alice);
        superVault.deposit(SMALL_AMOUNT_USDC, alice);

        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC);
        assertEq(superVault.balanceOf(alice), SMALL_AMOUNT_USDC);

        vm.prank(bob);
        superVault.deposit(SMALL_AMOUNT_USDC, bob);

        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC + SMALL_AMOUNT_USDC);
        assertEq(superVault.balanceOf(bob), SMALL_AMOUNT_USDC);

        deal(USDC, address(this), randomValue);
        USDC.safeTransfer(address(superVault), randomValue);

        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC + SMALL_AMOUNT_USDC + randomValue);

        vm.prank(alice);
        uint256 shares = superVault.deposit(randomValue, alice);
        assertGt(randomValue, shares);
    }

    function testDepositGasInfo() public {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        superVault.deposit(SMALL_AMOUNT_USDC, alice);
        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);

        //180677 for deposit operation
    }

    function testDepositWithAssetWrapper() public {
        DexHelper.DexSwapCalldata memory data = _buildSwapParams(WETH, USDC, SMALL_AMOUNT_WETH, address(assetWrapper));

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assetWrapper.deposit(data, alice, SMALL_AMOUNT_WETH);
        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);
        // SuperYield - 351380
        // InstaDapp - 698,653

        console.log("Alice shares: ", superVault.balanceOf(alice));
    }

    function testDepositWithEthWrapper() public {
        DexHelper.DexSwapCalldata memory data = _buildSwapParams(WETH, USDC, SMALL_AMOUNT_WETH, address(ethWrapper));

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ethWrapper.deposit{value: SMALL_AMOUNT_WETH}(data, alice);
        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);
        // SuperYield - 352357
        // InstaDapp - 698,653

        console.log("Alice shares: ", superVault.balanceOf(alice));
    }

    function testWithdraw() public {
        vm.prank(alice);
        superVault.deposit(SMALL_AMOUNT_USDC, alice);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        superVault.withdraw(SMALL_AMOUNT_USDC / 2, alice, alice);
        uint256 gasAfter = gasleft();

        assertEq(superVault.totalAssets(), SMALL_AMOUNT_USDC / 2);
        assertEq(superVault.balanceOf(alice), SMALL_AMOUNT_USDC / 2);

        console.log("Gas used: ", gasBefore - gasAfter); //27545
    }

    function testWithdrawWithAssetWrapper() public {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        uint256 wethBalanceBefore = WETH.balanceOf(alice);

        DexHelper.DexSwapCalldata memory data = _buildSwapParams(USDC, WETH, LARGE_AMOUNT_USDC, address(assetWrapper));

        vm.prank(alice);
        superVault.approve(address(assetWrapper), LARGE_AMOUNT_USDC);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assetWrapper.withdraw(data, LARGE_AMOUNT_USDC, alice);
        uint256 gasAfter = gasleft();

        //197214
        //Instadapp -442,419

        uint256 wethBalanceAfter = WETH.balanceOf(alice);

        assertGt(wethBalanceAfter, wethBalanceBefore);

        console.log("Alice WETH balance: ", wethBalanceAfter - wethBalanceBefore);

        console.log("Gas used: ", gasBefore - gasAfter); //27545
    }

    function testWithdrawWithEthWrapper() public {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        DexHelper.DexSwapCalldata memory data = _buildSwapParams(USDC, WETH, LARGE_AMOUNT_USDC, address(ethWrapper));

        vm.prank(alice);
        superVault.approve(address(ethWrapper), LARGE_AMOUNT_USDC);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ethWrapper.withdraw(data, LARGE_AMOUNT_USDC, alice);
        uint256 gasAfter = gasleft();

        //197214
        //Instadapp -442,419

        assertGt(WETH.balanceOf(alice), 1e18);

        console.log("Alice shares: ", alice.balance);

        console.log("Gas used: ", gasBefore - gasAfter); //27545
    }
}
