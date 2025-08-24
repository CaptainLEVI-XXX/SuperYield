// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {UniversalLendingWrapper} from "../src/UniversalLendingWrapper.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {AddressInfo} from "./helper/Address.sol";
import {LibCall} from "@solady/utils/LibCall.sol";

contract UniversalLendingWrapperTest is Test, AddressInfo {
    using SafeTransferLib for address;
    using LibCall for address;

    UniversalLendingWrapper wrapper;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), MAINNET_FORK_BLOCK);

        wrapper = new UniversalLendingWrapper();

        // Setup test account
        vm.startPrank(user);
        vm.deal(user, 100 ether);
    }

    function testAaveV3Operations() public {
        console.log("Testing AAVE V3...");

        // Get some WETH
        (bool success,) = WETH.call{value: 10 ether}("");
        require(success, "WETH wrap failed");

        // Test supply
        bytes memory supplyData = wrapper.getCalldata(WETH, 1 ether, user, wrapper.SUPPLY(), wrapper.AAVE_V3());

        // Execute supply
        WETH.safeApprove(AAVE_V3_POOL, 1 ether);
        AAVE_V3_POOL.callContract(supplyData);
        console.log("Supply executed");

        // Test borrow
        bytes memory borrowData = wrapper.getCalldata(USDC, 100 * 1e6, user, wrapper.BORROW(), wrapper.AAVE_V3());

        assertEq(borrowData.length, 164, "Borrow calldata length incorrect");
        AAVE_V3_POOL.callContract(borrowData);
        console.log("Borrow executed");

        // Test repay
        USDC.safeApprove(AAVE_V3_POOL, 100 * 1e6);
        bytes memory repayData = wrapper.getCalldata(USDC, 100 * 1e6, user, wrapper.REPAY(), wrapper.AAVE_V3());

        AAVE_V3_POOL.callContract(repayData);
        console.log("Repay executed");

        // Test withdraw
        bytes memory withdrawData = wrapper.getCalldata(WETH, 0.5 ether, user, wrapper.WITHDRAW(), wrapper.AAVE_V3());

        AAVE_V3_POOL.callContract(withdrawData);
        console.log("Withdraw executed");
    }

    function testCompoundV3Operations() public {
        console.log("Testing Compound V3...");

        // Get some USDC from whale
        deal(USDC, user, 10000 * 1e6);

        // Test supply
        bytes memory supplyData = wrapper.getCalldata(USDC, 1000 * 1e6, user, wrapper.SUPPLY(), wrapper.COMPOUND_V3());

        USDC.safeApprove(COMPOUND_V3_USDC, 1000 * 1e6);
        COMPOUND_V3_USDC.callContract(supplyData);
        console.log(" Supply executed");

        // Test withdraw (borrow in V3 is same as withdraw)
        bytes memory withdrawData =
            wrapper.getCalldata(USDC, 500 * 1e6, user, wrapper.WITHDRAW(), wrapper.COMPOUND_V3());

        COMPOUND_V3_USDC.callContract(withdrawData);
        console.log("Withdraw executed");
    }
}
