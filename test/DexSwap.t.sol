// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {AddressInfo} from "./helper/Address.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {IUniswapV3Router} from "../src/interfaces/IUniswapV3Router.sol";
import {MockDexHelper} from "./helper/MockDexHelper.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";


contract DexHelperTest is Test, AddressInfo {
    using SafeTransferLib for address;

    MockDexHelper dex;
    bytes32 id;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), MAINNET_FORK_BLOCK);
        dex = new MockDexHelper();
        vm.startPrank(address(dex));
        vm.deal(address(dex), 100 ether);
        WETH.safeApprove(UniswapV3, type(uint256).max);
        // Whitelist Uniswap V3
        id = dex.whitelistRoute("UniswapV3", UniswapV3);
    }

    function testUniswapV3Swap() public {
        // Deposit ETH → WETH
        (bool s,) = WETH.call{value: 1 ether}("");
        require(s, "wrap fail");

        uint256 wethBalBefore = WETH.balanceOf(address(dex));
        uint256 daiBalBefore = DAI.balanceOf(address(dex));

        // Build calldata for UniswapV3 exactInputSingle
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: DAI,
            fee: 3000,
            recipient: address(dex),
            deadline: block.timestamp + 1,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory swapData = abi.encodeWithSelector(IUniswapV3Router.exactInputSingle.selector, params);

        DexHelper.DexSwapCalldata memory data = DexHelper.DexSwapCalldata({swapCalldata: swapData, identifier: id});

        dex.exposedPerformSwap(data);

        uint256 wethBalAfter = WETH.balanceOf(address(dex));
        uint256 daiBalAfter = DAI.balanceOf(address(dex));

        console.log("WETH before:", wethBalBefore, "after:", wethBalAfter);
        console.log("DAI before:", daiBalBefore, "after:", daiBalAfter);

        assertGt(daiBalAfter, daiBalBefore, "DAI should increase");
        assertLt(wethBalAfter, wethBalBefore, "WETH should decrease");
    }
}
