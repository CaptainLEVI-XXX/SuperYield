// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DexHelper} from "./DexHelper.sol";
import {IInstaFlashReceiverInterface, IInstaFlashAggregatorInterface} from "../interfaces/IInstaDappFlashLoan.sol";
import {IUniversalLendingWrapper} from "../interfaces/IUniversalLendingWrapper.sol";
import {Venue} from "../abstract/Venue.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {LibCall} from "@solady/utils/LibCall.sol";
import {console} from "forge-std/console.sol";

contract Rebalancer is DexHelper, Venue, IInstaFlashReceiverInterface {
    using SafeTransferLib for address;
    using LibCall for address;

    enum LoopType {
        Leverage,
        Deleverage,
        Rebalance
    }

    struct LeverageData {
        address supplyAsset;
        address borrowAsset;
        uint256 initialSupply;
        uint256 flashLoanAmount;
        bytes32 venue;
        DexSwapCalldata swapCalldata;
    }

    struct DeleverageData {
        address supplyAsset;
        address borrowAsset;
        uint256 repayAmount;
        uint256 withdrawAmount;
        bytes32 venue;
        DexSwapCalldata swapCalldata;
    }

    struct RebalanceData {
        address supplyAsset;
        address borrowAsset;
        bytes32 fromVenue;
        bytes32 toVenue;
        uint256 moveSupplyAmount;
        uint256 moveBorrowAmount;
        DexSwapCalldata swapCalldata;
    }

    IInstaFlashAggregatorInterface public flashAggregator;
    IUniversalLendingWrapper public calldataGenerator;

    function _initializeRebalancer(address _flashAggregator, address _calldataGenerator) internal {
        flashAggregator = IInstaFlashAggregatorInterface(_flashAggregator);
        calldataGenerator = IUniversalLendingWrapper(_calldataGenerator);
    }

    function leverage(LeverageData memory leverageData, uint16 routeForFlashLoan) internal {
        // bytes memory data = abi.encode(LoopType.Leverage, leverageData);
        bytes memory data = abi.encodePacked(uint8(LoopType.Leverage), abi.encode(leverageData));

        // Execute flash loan for leverage
        flashAggregator.flashLoan(
            toArray(leverageData.borrowAsset), toArray(leverageData.flashLoanAmount), routeForFlashLoan, data, ""
        );
    }

    function deleverage(DeleverageData memory deleverageData, uint16 routeForFlashLoan) internal {
        bytes memory data = abi.encodePacked(uint8(LoopType.Deleverage), abi.encode(deleverageData));

        // Execute flash loan for deleverage
        flashAggregator.flashLoan(
            toArray(deleverageData.borrowAsset), toArray(deleverageData.repayAmount), routeForFlashLoan, data, ""
        );
    }

    function rebalance(RebalanceData memory rebalanceData, uint16 routeForFlashLoan) internal {
        bytes memory data = abi.encodePacked(uint8(LoopType.Rebalance), abi.encode(rebalanceData));

        // Execute flash loan for rebalance
        flashAggregator.flashLoan(
            toArray(rebalanceData.borrowAsset), toArray(rebalanceData.moveBorrowAmount), routeForFlashLoan, data, ""
        );
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) external returns (bool) {
        require(msg.sender == address(flashAggregator), "Invalid caller");
        require(initiator == address(this), "Invalid initiator");

        LoopType loopType = LoopType(uint8(data[0]));
        bytes memory params = data[1:]; // Rest of the data

        if (loopType == LoopType.Leverage) {
            _executeLeverage(params, assets[0], amounts[0], premiums[0]);
        } else if (loopType == LoopType.Deleverage) {
            _executeDeleverage(params, assets[0], amounts[0], premiums[0]);
        } else if (loopType == LoopType.Rebalance) {
            _executeRebalance(params, assets[0], amounts[0], premiums[0]);
        }

        return true;
    }

    // gas used: 1010336
    function _executeLeverage(bytes memory data, address flashAsset, uint256 flashAmount, uint256 premium) internal {
        LeverageData memory leverageData = abi.decode(data, (LeverageData));
        VenueInfo memory venue = venues[leverageData.venue];

        // Step 1: Swap borrowed asset to supply asset
        uint256 swapOutput = leverageData.supplyAsset.balanceOf(address(this));
        flashAsset.safeApprove(getDexRouter(leverageData.swapCalldata.identifier), flashAmount);
        performSwap(leverageData.swapCalldata);
        swapOutput = leverageData.supplyAsset.balanceOf(address(this)) - swapOutput;

        // Step 2: Get batch calldata for supply + borrow
        uint256 totalSupply = leverageData.initialSupply + swapOutput;
        uint256 borrowAmount = flashAmount + premium;

        (bytes memory supplyCalldata, bytes memory borrowCalldata) = calldataGenerator.getBatchSupplyBorrow(
            leverageData.supplyAsset, totalSupply, leverageData.borrowAsset, borrowAmount, address(this), venue.id
        );

        // Step 3: Execute both operations
        leverageData.supplyAsset.safeApprove(venue.router, totalSupply);
        venue.router.callContract(supplyCalldata);
        venue.router.callContract(borrowCalldata);

        // Step 4: Transfer back to flash loan
        flashAsset.safeTransfer(address(flashAggregator), borrowAmount);
    }

    function _executeDeleverage(bytes memory data, address flashAsset, uint256 flashAmount, uint256 premium) internal {
        DeleverageData memory deleverageData = abi.decode(data, (DeleverageData));
        // Position storage position = positions[deleverageData.positionId];
        VenueInfo memory venue = venues[deleverageData.venue];

        // Step 1: Repay all debt to protocol
        flashAsset.safeApprove(venue.router, deleverageData.repayAmount);

        (bytes memory repayCalldata, bytes memory withdrawCalldata) = calldataGenerator.getBatchRepayWithdraw(
            deleverageData.borrowAsset,
            deleverageData.repayAmount,
            deleverageData.supplyAsset,
            deleverageData.withdrawAmount,
            address(this),
            venue.id
        );
        venue.router.callContract(repayCalldata);

        // Step 2: Withdraw all collateral
        venue.router.callContract(withdrawCalldata);

        // Step 3: Swap supply asset to borrow asset to repay flash loan
        uint256 flashRepayAmount = flashAmount + premium;
        uint256 swapInput = flashRepayAmount; // Calculate based on DEX quote
        uint256 swapOutput = deleverageData.borrowAsset.balanceOf(address(this));
        if (deleverageData.supplyAsset != deleverageData.borrowAsset) {
            deleverageData.supplyAsset.safeApprove(getDexRouter(deleverageData.swapCalldata.identifier), swapInput);
            performSwap(deleverageData.swapCalldata);
            swapOutput = deleverageData.borrowAsset.balanceOf(address(this)) - swapOutput;
            require(swapOutput >= flashRepayAmount, "Insufficient swap output");
        }

        // Step 4: Repay flash loan
        flashAsset.safeApprove(address(flashAggregator), flashRepayAmount);

        // // Step 5: Send remaining funds to vault
        // uint256 remaining = c.supplyAsset.balanceOf(address(this));
        // if (remaining > 0) {
        //     .supplyAsset.safeTransfer(position.vault, remaining);
        // }
    }

    function _executeRebalance(bytes memory data, address flashAsset, uint256 flashAmount, uint256 premium) internal {
        RebalanceData memory rebalanceData = abi.decode(data, (RebalanceData));
        // Position storage position = positions[rebalanceData.positionId];

        VenueInfo memory fromVenue = venues[rebalanceData.fromVenue];
        VenueInfo memory toVenue = venues[rebalanceData.toVenue];

        // Step 1: Repay debt on source venue
        flashAsset.safeApprove(fromVenue.router, rebalanceData.moveBorrowAmount);

        (bytes memory repayCalldata, bytes memory withdrawCalldata) = calldataGenerator.getBatchRepayWithdraw(
            rebalanceData.borrowAsset,
            rebalanceData.moveBorrowAmount,
            rebalanceData.supplyAsset,
            rebalanceData.moveSupplyAmount,
            address(this),
            fromVenue.id
        );
        fromVenue.router.callContract(repayCalldata);

        // Step 2: Withdraw collateral from source venue
        fromVenue.router.callContract(withdrawCalldata);

        // Step 3: Supply to target venue
        rebalanceData.supplyAsset.safeApprove(toVenue.router, rebalanceData.moveSupplyAmount);

        // Step 4: Borrow from target venue to repay flash loan
        uint256 borrowAmount = flashAmount + premium;

        (bytes memory supplyCalldata, bytes memory borrowCalldata) = calldataGenerator.getBatchSupplyBorrow(
            rebalanceData.supplyAsset,
            rebalanceData.moveSupplyAmount,
            rebalanceData.borrowAsset,
            borrowAmount,
            address(this),
            toVenue.id
        );
        toVenue.router.callContract(supplyCalldata);
        toVenue.router.callContract(borrowCalldata);

        // Step 5: Repay flash loan
        flashAsset.safeTransfer(address(flashAggregator), borrowAmount);
    }

    function toArray(address item) internal pure returns (address[] memory) {
        address[] memory array = new address[](1);
        array[0] = item;
        return array;
    }

    function toArray(uint256 item) internal pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = item;
        return array;
    }
}
