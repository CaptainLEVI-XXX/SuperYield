// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./Base.t.sol";
import {console} from "forge-std/console.sol";

contract OracleTest is BaseTest {
    function testOracle() public view {
        uint256 wethUsd = oracleAggregator.getPrice(WETH, oracleAggregator.USD());
        uint256 usdcUsd = oracleAggregator.getPrice(USDC, oracleAggregator.USD());
        uint256 wethUsdc = oracleAggregator.getPrice(WETH, USDC);
        console.log("wethUsd", wethUsd);
        console.log("usdcUsd", usdcUsd);
        console.log("wethUsdc", wethUsdc);
    }
}
