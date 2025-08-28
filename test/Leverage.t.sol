// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./Base.t.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {Venue} from "../src/abstract/Venue.sol";

contract LeverageTest is BaseTest {
    function testOpenPosition() public {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 2e18; //$ 9037.96 dollar worth of WETH
        DexHelper.DexSwapCalldata memory swapData =
            _buildSwapParams(WETH, USDC, flashLoanAmount, address(strategyManager));
        uint256 gasBefore = gasleft();

        vm.prank(admin);
        strategyManager.openPosition(
            address(superVault),
            address(USDC),
            address(WETH),
            FOUR_THOUSAND_DOLLAR,
            flashLoanAmount,
            venue,
            50e16,
            5,
            swapData
        );

        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);
        //1,012,791
        //1,010.336
    }
}
