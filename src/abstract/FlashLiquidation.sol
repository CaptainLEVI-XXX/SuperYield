// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import {DexHelper} from "./DexHelper.sol";
// import {IInstaFlashReceiverInterface, IInstaFlashAggregatorInterface} from "../interfaces/IInstaDappFlashLoan.sol";

// abstract contract FlashLiquidation is DexHelper, IInstaFlashReceiverInterface {

//     /// @notice Data structure for flash loan execution
//     /// @dev Contains all necessary information for executing a flash loan pre-liquidation
//     /// @param marketKey Unique key identifying the market configuration
//     /// @param keeper Address of the keeper executing the pre-liquidation
//     /// @param seizeAmount Amount of collateral to seize (in USD)
//     /// @param collateralToken Address of the collateral token
//     /// @param debtToken Address of the debt token to repay
//     struct FlashLoanData {
//         bytes32 marketKey;
//         address keeper;
//         uint256 seizeAmount;
//         uint256 repayUnits;
//         address collateralToken;
//         address debtToken;
//         uint16 routeForFlashLoan;
//     }

//     IInstaFlashAggregatorInterface public flashAggregator;

//     /// @notice Thrown when flash loan operation fails
//     error FlashLoanFailed();

//     /// @notice Thrown when flash loan callback is invalid or unauthorized
//     error InvalidFlashLoanCallback();

//     function initializeflashLiquidator(address _flashAggregator) public virtual {
//         flashAggregator = IInstaFlashAggregatorInterface(_flashAggregator);
//     }

//     function flashLoan(FlashLoanData memory flashLoanData) internal {
//         bytes memory data = abi.encode(flashLoanData);
//         flashAggregator.flashLoan(
//             toArray(flashLoanData.debtToken), toArray(flashLoanData.repayUnits), flashLoanData.routeForFlashLoan, data, ""
//         );
//     }

//         /// @notice Flash loan callback function called by flash loan provider
//     /// @dev Implements IInstaFlashReceiverInterface - executes liquidation and repays flash loan
//     /// @param assets Array of asset addresses that were borrowed
//     /// @param amounts Array of amounts that were borrowed
//     /// @param premiums Array of premium amounts to pay for the flash loan
//     /// @param initiator Address that initiated the flash loan (should be this contract)
//     /// @param params Encoded FlashLoanData containing liquidation parameters
//     /// @return success True if the operation was successful
//     function executeOperation(
//         address[] calldata assets,
//         uint256[] calldata amounts,
//         uint256[] calldata premiums,
//         address initiator,
//         bytes calldata params
//     ) external returns (bool) {
//         if (msg.sender != flashLoanProvider) revert InvalidFlashLoanCallback();
//         if (initiator != address(this)) revert InvalidFlashLoanCallback();

//         FlashLoanData memory flashData = abi.decode(params, (FlashLoanData));

//         MarketConfig storage config = markets[flashData.marketKey];

//         // Calculate amounts in USD
//         uint256 repayUsd = config.adapter.tokenUnitsToUsd(flashData.debtToken, amounts[0]);

//         LiquidationAmounts memory liquidationAmounts = LiquidationAmounts({
//             repayAmount: repayUsd,
//             seizeAmount: flashData.seizeAmount,
//             lif: 0, // Already calculated
//             lcf: 0  // Already calculated
//         });

//         // Execute the actual liquidation
//         (uint256 actualRepaidUsd, uint256 actualSeizedUsd) = _executeLiquidation(
//             config,
//             liquidationAmounts,
//             flashData.keeper,
//             true // is flash loan
//         );

//         // Convert seized collateral to debt token to repay flash loan
//         uint256 seizedUnits = config.adapter.usdToTokenUnits(
//             flashData.collateralToken,
//             actualSeizedUsd
//         );

//         // Swap collateral to debt token if different
//         if (flashData.collateralToken != flashData.debtToken) {
//             _swapForRepayment(
//                 flashData.collateralToken,
//                 flashData.debtToken,
//                 seizedUnits,
//                 amounts[0] + premiums[0]
//             );
//         }

//         // Approve flash loan repayment
//         uint256 totalRepay = amounts[0] + premiums[0];
//         flashData.debtToken.safeApprove(flashLoanProvider, totalRepay);

//         // Send profit to keeper
//         uint256 remaining = IERC20(flashData.debtToken).balanceOf(address(this)) - totalRepay;
//         if (remaining > 0) {
//             flashData.debtToken.safeTransfer(flashData.keeper, remaining);
//             keeperProfits[flashData.keeper] += remaining;
//         }

//         return true;
//     }

//     function toArray(address item) internal pure returns (address[] memory) {
//         address[] memory array = new address[](1);
//         array[0] = item;
//         return array;
//     }

//     function toArray(uint256 item) internal pure returns (uint256[] memory) {
//         uint256[] memory array = new uint256[](1);
//         array[0] = item;
//         return array;
//     }

// }
