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
        uint256 borrowAmount;
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
            toArray(leverageData.supplyAsset), toArray(leverageData.flashLoanAmount), routeForFlashLoan, data, ""
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
        uint256 gasBefore = gasleft();
        require(msg.sender == address(flashAggregator), "Invalid caller");
        require(initiator == address(this), "Invalid initiator");

        LoopType loopType = LoopType(uint8(data[0]));
        bytes memory params = data[1:]; // Rest of the data

        if (loopType == LoopType.Leverage) {
            _executeLeverage(params, premiums[0]);
        } else if (loopType == LoopType.Deleverage) {
            _executeDeleverage(params, premiums[0]);
        } else if (loopType == LoopType.Rebalance) {
            _executeRebalance(params, premiums[0]);
        }
        uint256 gasAfter = gasleft();
        console.log("Gas used for our Operation Execute: ", gasBefore - gasAfter);

        return true;
    }

    // gas used: 544307 approx.
    function _executeLeverage(bytes memory data, uint256 premium) internal {
        LeverageData memory leverageData = abi.decode(data, (LeverageData));
        VenueInfo memory venue = _venueStorage().venues[leverageData.venue];

        uint256 totalSupply = leverageData.initialSupply + leverageData.flashLoanAmount;
        uint256 flashLoanRepayAmount = leverageData.flashLoanAmount + premium;

        (bytes memory supplyCalldata, bytes memory borrowCalldata) = calldataGenerator.getBatchSupplyBorrow(
            leverageData.supplyAsset,
            totalSupply,
            leverageData.borrowAsset,
            leverageData.borrowAmount,
            address(this),
            venue.id
        );

        //Execute both operations
        leverageData.supplyAsset.safeApprove(venue.router, totalSupply);
        venue.router.callContract(supplyCalldata);
        venue.router.callContract(borrowCalldata);

        leverageData.borrowAsset.safeApprove(
            getDexRouter(leverageData.swapCalldata.identifier), leverageData.borrowAmount
        );
        performSwap(leverageData.swapCalldata);

        //Transfer back to flash loan
        leverageData.supplyAsset.safeTransfer(address(flashAggregator), flashLoanRepayAmount);
    }

    function _executeDeleverage(bytes memory data, uint256 premium) internal {

        DeleverageData memory deleverageData = abi.decode(data, (DeleverageData));
        VenueInfo memory venue = _venueStorage().venues[deleverageData.venue];

        uint256 flashLoanRepayAmount = deleverageData.repayAmount + premium;

        // Step 1: Repay all debt to protocol
        deleverageData.borrowAsset.safeApprove(venue.router, deleverageData.repayAmount);

        (bytes memory repayCalldata, bytes memory withdrawCalldata) = calldataGenerator.getBatchRepayWithdraw(
            deleverageData.borrowAsset,
            deleverageData.repayAmount,
            deleverageData.supplyAsset,
            deleverageData.withdrawAmount,
            address(this),
            venue.id
        );
        // Step3: Repay debt
        venue.router.callContract(repayCalldata);

        // Step 2: Withdraw all collateral
        venue.router.callContract(withdrawCalldata);

        //  Swap supply asset to borrow asset to repay flash loan
        deleverageData.supplyAsset.safeApprove(
            getDexRouter(deleverageData.swapCalldata.identifier), flashLoanRepayAmount
        );
        performSwap(deleverageData.swapCalldata);

        // Repay flash loan
        deleverageData.borrowAsset.safeTransfer(address(flashAggregator), flashLoanRepayAmount);

        // // Step 5: Send remaining funds to vault
        // uint256 remaining = c.supplyAsset.balanceOf(address(this));
        // if (remaining > 0) {
        //     .supplyAsset.safeTransfer(position.vault, remaining);
        // }
    }

    function _executeRebalance(bytes memory data, uint256 premium) internal {
        RebalanceData memory rebalanceData = abi.decode(data, (RebalanceData));

        VenueInfo memory fromVenue = _venueStorage().venues[rebalanceData.fromVenue];
        VenueInfo memory toVenue = _venueStorage().venues[rebalanceData.toVenue];

        //Repay debt on source venue
        rebalanceData.borrowAsset.safeApprove(fromVenue.router, rebalanceData.moveBorrowAmount);

        (bytes memory repayCalldata, bytes memory withdrawCalldata) = calldataGenerator.getBatchRepayWithdraw(
            rebalanceData.borrowAsset,
            rebalanceData.moveBorrowAmount,
            rebalanceData.supplyAsset,
            rebalanceData.moveSupplyAmount,
            address(this),
            fromVenue.id
        );
        fromVenue.router.callContract(repayCalldata);

        // Withdraw collateral from source venue
        fromVenue.router.callContract(withdrawCalldata);

        //Supply to target venue
        rebalanceData.supplyAsset.safeApprove(toVenue.router, rebalanceData.moveSupplyAmount);

        //Borrow from target venue to repay flash loan
        uint256 borrowAmount = rebalanceData.moveBorrowAmount + premium;

        (bytes memory supplyCalldata, bytes memory borrowCalldata) = calldataGenerator.getBatchSupplyBorrow(
            rebalanceData.supplyAsset,
            rebalanceData.moveSupplyAmount,
            rebalanceData.borrowAsset,
            borrowAmount,
            address(this),
            toVenue.id
        );
        //Supply to target venue
        toVenue.router.callContract(supplyCalldata);
        //Borrow from target venue to repay flash loan
        toVenue.router.callContract(borrowCalldata);

        //Repay flash loan
        rebalanceData.borrowAsset.safeTransfer(address(flashAggregator), borrowAmount);
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
