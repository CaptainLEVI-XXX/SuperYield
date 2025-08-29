// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./Base.t.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {Venue} from "../src/abstract/Venue.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {StrategyManager} from "../src/ExecutionEngine.sol";
import {IChainlinkOracle} from "../src/interfaces/IOracle.sol";

contract LeverageTest is BaseTest {
    using SafeTransferLib for address;

    function testOpenPosition() public {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6; //$ 7000 dollar worth of USDC
        DexHelper.DexSwapCalldata memory swapData = _buildSwapParams(WETH, USDC, 1e18, address(strategyManager));
        uint256 gasBefore = gasleft();
        vm.prank(admin);
        strategyManager.openPosition(
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
        console.log("Gas used: ", gasBefore - gasAfter);
        //1,012,791 ---- gas  used our executeOperation is 544,307--gas used by FlashLoan = 468,484
        //1,010.336
        //1020727
    }

    function testClosePosition() public {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6; //$ 7000 dollar worth of USDC
        DexHelper.DexSwapCalldata memory swapData = _buildSwapParams(WETH, USDC, 1e18, address(strategyManager));

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

        // uint256 withdrawAmount = aUSDC.balanceOf(address(strategyManager));
        // console.log("Withdraw amount: ", withdrawAmount);

        DexHelper.DexSwapCalldata memory swapCallData =
            _buildSwapParams(USDC, WETH, FIVE_THOUSAND_DOLLAR, address(strategyManager));

        uint256 gasBefore = gasleft();
        vm.prank(admin);
        strategyManager.closePosition(positionId, 1e18, FIVE_THOUSAND_DOLLAR, swapCallData, 5);

        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter); //391318  //1405303
    }

    function testRebalancePosition() public {
        vm.prank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));
        uint256 flashLoanAmount = 4000e6; //$ 7000 dollar worth of USDC
        DexHelper.DexSwapCalldata memory swapData = _buildSwapParams(WETH, USDC, 1e18, address(strategyManager));
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

        // bytes32 venue2 = keccak256(abi.encodePacked(COMPOUND_V3_USDC));

        uint256 gasBefore = gasleft();

        vm.prank(admin);
        strategyManager.rebalancePosition(positionId, venue, swapData, 5);

        uint256 gasAfter = gasleft();
        console.log("Gas used: ", gasBefore - gasAfter);
        //417194
    }

    function testRebalanceLTV() public {
        vm.startPrank(alice);
        superVault.deposit(LARGE_AMOUNT_USDC, alice);
        vm.stopPrank();

        bytes32 venue = keccak256(abi.encodePacked(AAVE_V3_POOL));

        // Step 1: Open position supplying USDC and borrowing WETH
        uint256 flashLoanAmount = 4000e6; // $4000 USDC worth
        DexHelper.DexSwapCalldata memory swapData = _buildSwapParams(WETH, USDC, 1e18, address(strategyManager));

        vm.prank(admin);
        uint256 positionId = strategyManager.openPosition(
            address(superVault),
            address(USDC),
            address(WETH),
            5000e6, // deposit 5000 USDC
            1e18,
            flashLoanAmount,
            venue,
            5,
            swapData
        );

        // Step 2: Compute actual current LTV using oracle
        uint256 wethPrice = _getWETHPriceInUSDC(); // e.g. ~4600e6
        (,,,, uint256 totalSupplied, uint256 totalBorrowed,) = strategyManager.positions(positionId);

        // normalize decimals
        uint256 borrowedInUSDC = (totalBorrowed * wethPrice) / 1e18; // WETH -> USDC
        uint256 suppliedInUSDC = totalSupplied; // already USDC 6 decimals

        uint256 currentLTV = (borrowedInUSDC * 1e18) / suppliedInUSDC;
        console.log("Current LTV: %s", currentLTV);

        // Step 3: Pick a higher target LTV (leverage case)
        uint256 targetLTV = 97e16; // +5%

        // Step 4: Off-chain math for how much more borrow & flashloan needed
        // Example: want to move borrow ratio from currentLTV → targetLTV
        uint256 targetBorrowInUSDC = (suppliedInUSDC * targetLTV) / 1e18;
        uint256 deltaBorrowInUSDC = targetBorrowInUSDC - borrowedInUSDC;

        uint256 deltaBorrowInWETH = (deltaBorrowInUSDC * 1e18) / wethPrice; // back to WETH
        uint256 flashLoanNeeded = deltaBorrowInUSDC; // in USDC

        DexHelper.DexSwapCalldata memory swapCalldata =
            _buildSwapParams(WETH, USDC, deltaBorrowInWETH, address(strategyManager));

        // Step 5: Call rebalance
        vm.prank(admin);
        strategyManager.rebalanceToTargetLTV(positionId, targetLTV, deltaBorrowInWETH, flashLoanNeeded, swapCalldata, 5);

        // Step 6: Verify LTV moved closer
        (,,,, totalSupplied, totalBorrowed,) = strategyManager.positions(positionId);
        borrowedInUSDC = (totalBorrowed * wethPrice) / 1e18;
        suppliedInUSDC = totalSupplied;

        uint256 newLTV = (borrowedInUSDC * 1e18) / suppliedInUSDC;
        console.log("New LTV: %s", newLTV);

        assertApproxEqAbs(newLTV, targetLTV, 0.01e18); // within 1%
    }

    function _getWETHPriceInUSDC() internal view returns (uint256) {
        // Chainlink ETH/USD feed (8 decimals), convert to USDC 6 decimals
        IChainlinkOracle feed = IChainlinkOracle(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        (, int256 price,,,) = feed.latestRoundData();
        return uint256(price) * 1e6 / 1e8; // scale to USDC decimals
    }
}
