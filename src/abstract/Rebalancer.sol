// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DexHelper} from "./DexHelper.sol";
import {IInstaFlashReceiverInterface, IInstaFlashAggregatorInterface} from "../interfaces/IInstaDappFlashLoan.sol";
import {IUniversalLendingWrapper} from "../interfaces/IUniversalLendingWrapper.sol";
import {Venue} from "../abstract/Venue.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {LibCall} from "@solady/utils/LibCall.sol";

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
        bytes memory data = abi.encode(leverageData, LoopType.Leverage);

        // Execute flash loan for leverage
        flashAggregator.flashLoan(
            toArray(leverageData.borrowAsset), toArray(leverageData.flashLoanAmount), routeForFlashLoan, data, ""
        );
    }

    function deleverage(DeleverageData memory deleverageData, uint16 routeForFlashLoan) internal {
        bytes memory data = abi.encode(deleverageData, LoopType.Deleverage);

        // Execute flash loan for deleverage
        flashAggregator.flashLoan(
            toArray(deleverageData.borrowAsset), toArray(deleverageData.repayAmount), routeForFlashLoan, data, ""
        );
    }

    function rebalance(RebalanceData memory rebalanceData, uint16 routeForFlashLoan) internal {
        bytes memory data = abi.encode(rebalanceData, LoopType.Rebalance);

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

        (, LoopType loopType) = abi.decode(data, (bytes, LoopType));

        if (loopType == LoopType.Leverage) {
            _executeLeverage(data, assets[0], amounts[0], premiums[0]);
        } else if (loopType == LoopType.Deleverage) {
            _executeDeleverage(data, assets[0], amounts[0], premiums[0]);
        } else if (loopType == LoopType.Rebalance) {
            _executeRebalance(data, assets[0], amounts[0], premiums[0]);
        }

        return true;
    }

    function _executeLeverage(bytes memory data, address flashAsset, uint256 flashAmount, uint256 premium) internal {
        (LeverageData memory leverageData,) = abi.decode(data, (LeverageData, LoopType));
        // Position storage position = positions[leverageData.positionId];
        VenueInfo memory venue = venues[leverageData.venue];

        // Step 1: Swap borrowed asset to supply asset
        uint256 swapOutput = leverageData.supplyAsset.balanceOf(address(this));
        if (leverageData.borrowAsset != leverageData.supplyAsset) {
            flashAsset.safeApprove(getDexRouter(leverageData.swapCalldata.identifier), flashAmount);
            performSwap(leverageData.swapCalldata);
            swapOutput = leverageData.supplyAsset.balanceOf(address(this)) - swapOutput;
        } else {
            swapOutput = flashAmount;
        }
        // Step 2: Supply everything (initial + swapped) to protocol
        uint256 totalSupply = leverageData.initialSupply + swapOutput;
        leverageData.supplyAsset.safeApprove(venue.router, totalSupply);

        bytes memory supplyCalldata = calldataGenerator.getCalldata(
            leverageData.supplyAsset,
            totalSupply,
            address(this),
            0, // SUPPLY
            venue.id
        );
        venue.router.callContract(supplyCalldata);
        /// @notice can we use multi-call to get the call-data for both supply + borrow
        // Step 3: Borrow to repay flash loan
        uint256 borrowAmount = flashAmount + premium;
        bytes memory borrowCalldata = calldataGenerator.getCalldata(
            leverageData.borrowAsset,
            borrowAmount,
            address(this),
            2, // BORROW
            venue.id
        );
        venue.router.callContract(borrowCalldata);

        // Step 4: Repay flash loan
        flashAsset.safeApprove(address(flashAggregator), borrowAmount);

        // Update position state
        // position.totalSupplied = totalSupply;
        // position.totalBorrowed = borrowAmount;
        // position.status = PositionStatus.Active;
    }

    function _executeDeleverage(bytes memory data, address flashAsset, uint256 flashAmount, uint256 premium) internal {
        (DeleverageData memory deleverageData,) = abi.decode(data, (DeleverageData, LoopType));
        // Position storage position = positions[deleverageData.positionId];
        VenueInfo memory venue = venues[deleverageData.venue];

        // Step 1: Repay all debt to protocol
        flashAsset.safeApprove(venue.router, deleverageData.repayAmount);
        bytes memory repayCalldata = calldataGenerator.getCalldata(
            deleverageData.borrowAsset,
            deleverageData.repayAmount,
            address(this),
            3, // REPAY
            venue.id
        );
        venue.router.callContract(repayCalldata);

        // Step 2: Withdraw all collateral
        bytes memory withdrawCalldata = calldataGenerator.getCalldata(
            deleverageData.supplyAsset,
            deleverageData.withdrawAmount,
            address(this),
            1, // WITHDRAW
            venue.id
        );
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
        (RebalanceData memory rebalanceData,) = abi.decode(data, (RebalanceData, LoopType));
        // Position storage position = positions[rebalanceData.positionId];

        VenueInfo memory fromVenue = venues[rebalanceData.fromVenue];
        VenueInfo memory toVenue = venues[rebalanceData.toVenue];

        // Step 1: Repay debt on source venue
        flashAsset.safeApprove(fromVenue.router, rebalanceData.moveBorrowAmount);
        bytes memory repayCalldata = calldataGenerator.getCalldata(
            rebalanceData.borrowAsset,
            rebalanceData.moveBorrowAmount,
            address(this),
            3, // REPAY
            fromVenue.id
        );
        fromVenue.router.callContract(repayCalldata);

        // Step 2: Withdraw collateral from source venue
        bytes memory withdrawCalldata = calldataGenerator.getCalldata(
            rebalanceData.supplyAsset,
            rebalanceData.moveSupplyAmount,
            address(this),
            1, // WITHDRAW
            fromVenue.id
        );
        fromVenue.router.callContract(withdrawCalldata);

        // Step 3: Supply to target venue
        rebalanceData.supplyAsset.safeApprove(toVenue.router, rebalanceData.moveSupplyAmount);
        bytes memory supplyCalldata = calldataGenerator.getCalldata(
            rebalanceData.supplyAsset,
            rebalanceData.moveSupplyAmount,
            address(this),
            0, // SUPPLY
            toVenue.id
        );
        toVenue.router.callContract(supplyCalldata);

        // Step 4: Borrow from target venue to repay flash loan
        uint256 borrowAmount = flashAmount + premium;
        bytes memory borrowCalldata = calldataGenerator.getCalldata(
            rebalanceData.borrowAsset,
            borrowAmount,
            address(this),
            2, // BORROW
            toVenue.id
        );
        toVenue.router.callContract(borrowCalldata);

        // Step 5: Repay flash loan
        flashAsset.safeApprove(address(flashAggregator), borrowAmount);

        // Update position state
        // position.currentVenue = rebalanceData.toVenue;
        // position.status = PositionStatus.Active;
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
