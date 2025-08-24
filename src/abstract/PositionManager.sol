// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {IInstaFlashAggregatorInterface} from "./interfaces/IInstaDappFlashLoan.sol";
import {IInstaFlashReceiverInterface} from "./interfaces/IInstaDappFlashLoan.sol";
import {LibCall} from "@solady/utils/LibCall.sol";
import {DexHelper} from "./abstract/DexHelper.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {IULW} from "./interfaces/IULW.sol";

contract PositionManager is Initializable, IInstaFlashReceiverInterface, DexHelper, UUPSUpgradeable, Admin2Step {
    using SafeTransferLib for address;
    using CustomRevert for bytes4;
    using LibCall for address;

    enum AllocationType {
        Float,
        Fixed
    }

    struct VenueInfo {
        uint64 activePositions;
        address router;
        AllocationType allocationType;
        string name;
    }

    struct VenueStorage {
        mapping(bytes32 venueIdentifier => VenueInfo) venueInfo;
    }

    enum LoopType {
        Leverage,
        Deleverage
    }

    struct PositionInfo {
        address supplyAsset;
        address borrowAsset;
        address denominationTokenForSupply;
        address denominationTokenForBorrow;
        bytes32 venueIdentifier;
        uint256 supplyAmount;
        uint8 leverage;
        uint64 minLtv;
        uint64 maxLtv;
    }

    struct PositionStorage {
        uint256 nextPosId;
        mapping(uint256 positionId => PositionInfo) positionInfo;
        mapping(uint256 positionId => AllocationType) positionType;
    }

    struct InterfaceInfo {
        IInstaFlashAggregatorInterface aggregator;
        IULW ulw;
    }

    struct LoopFlashLoanInfo {
        address supplyAsset;
        address borrowAsset;
        uint256 supplyAmount;
        uint256 flashLoanAmount;
        uint8 leverage;
        DexSwapCalldata swapCalldata;
        bytes32 venueIdentifier;
    }

    struct UnLoopFlashLoanInfo {
        address supplyAsset;
        address borrowAsset;
        address repayAmount;
        uint256 withdrawAmount;
        DexSwapCalldata swapCalldata;
        bytes32 venueIdentifier;
    }
    // let say you want to deploy 4000 USDC at 4x leverage
    // 1. calculate flashLoan amount needed

    error ActivePosition();

    event RegisteredVenue(bytes32 indexed venueIdentifier, address router, AllocationType allocationType, string name);

    bytes32 public constant VENUE_STORAGE = keccak256("super.erc1967.venue.storage");
    bytes32 public constant POSITION_STORAGE = keccak256("super.erc1967.position.storage");
    bytes32 public constant FLASH_LOAN_INTERFACE = keccak256("super.erc1967.flash.loan.interface");

    function venueStorage() internal pure returns (VenueStorage storage _venueStorage) {
        bytes32 position = VENUE_STORAGE;
        assembly {
            _venueStorage.slot := position
        }
    }

    function positionStorage() internal pure returns (PositionStorage storage _positionStorage) {
        bytes32 position = POSITION_STORAGE;
        assembly {
            _positionStorage.slot := position
        }
    }

    function interfaceInfo() internal pure returns (InterfaceInfo storage _interfaceInfo) {
        bytes32 position = FLASH_LOAN_INTERFACE;
        assembly {
            _interfaceInfo.slot := position
        }
    }

    constructor() {
        _disableInitializers();
    }

    function intialize(address instadappExecutor, address ulw) public initializer {
        InterfaceInfo storage interfaceInfo_ = interfaceInfo();
        interfaceInfo_.aggregator = IInstaFlashAggregatorInterface(instadappExecutor);
        _setAdmin(msg.sender);
        interfaceInfo_.ulw = IULW(ulw);
    }

    function registerVenue(string memory name, address router, AllocationType allocationType)
        external
        returns (bytes32)
    {
        /// check the incoming calldata
        /// @notice we need something else through which we can know what function to call on the router
        bytes32 venueIdentifier = keccak256(abi.encodePacked(name, router));
        VenueStorage storage venueStorage_ = venueStorage();
        venueStorage_.venueInfo[venueIdentifier] =
            VenueInfo({activePositions: 0, router: router, allocationType: allocationType, name: name});
        venueStorage_.isSupported[venueIdentifier] = true;
        emit RegisteredVenue(venueIdentifier, router, allocationType, name);
        return venueIdentifier;
    }

    function deleteVenue(bytes32 venueIdentifier) external {
        VenueStorage storage venueStorage_ = venueStorage();
        if (venueStorage_.venueInfo[venueIdentifier].activePositions > 0) ActivePosition.selector.revertWith();

        venueStorage().venueInfo[venueIdentifier] = VenueInfo(0, 0, address(0), AllocationType.Float, "");
    }

    function openPosition(
        PositionInfo memory positionInfo,
        DexSwapCalldata memory swapCalldata,
        AllocationType allocationType
    ) public {
        /// @notice perform checks for for incoming calldata
        /// 1. check if the venue is supported
        /// 2. check if contract has enough funds to open the required position
        /// 3. check if the position is within the optimal LTV band
        /// 4. check if the supplied asset , borrowed , denomination asset are valid

        _validatePositionCalldata(positionInfo);
        PositionStorage storage positionStorage_ = positionStorage();
        // Increment the position id
        positionStorage_.nextPosId++;
        // Store the position Info
        positionStorage_.positionInfo[positionStorage_.nextPosId] = positionInfo;
        // store the allocation type
        positionStorage_.positionType[positionStorage_.nextPosId] = allocationType;

        if (allocationType == AllocationType.Float) {
            /// @dev Call the loop engine to open a position on the required venue

            leverage(
                LoopFlashLoanInfo({
                    supplyAsset: positionInfo.supplyAsset,
                    borrowAsset: positionInfo.borrowAsset,
                    supplyAmount: positionInfo.supplyAmount,
                    flashLoanAmount: positionInfo.flashLoanAmount,
                    leverage: positionInfo.leverage,
                    swapCalldata: swapCalldata,
                    identifier: positionInfo.identifier
                })
            );
        }
    }

    function closePosition(
        uint256 positionId,
        DexSwapCalldata memory swapCalldata,
        uint256 repayAmount,
        uint256 withdrawAmount
    ) public {
        /// @Todo check if the position is open
        /// check is the position is valid
        PositionStorage storage positionStorage_ = positionStorage();
        PositionInfo memory positionInfo = positionStorage_.positionInfo[positionId];

        deleverage(
            UnLoopFlashLoanInfo({
                supplyAsset: positionInfo.supplyAsset,
                borrowAsset: positionInfo.borrowAsset,
                repayAmount: repayAmount,
                withdrawAmount: withdrawAmount,
                swapCalldata: swapCalldata,
                venueIdentifier: positionInfo.identifier
            })
        );
    }

    function leverage(LoopFlashLoanInfo memory loopFlashLoanInfo) public {
        bytes memory data = abi.encode(loopFlashLoanInfo, LoopType.Leverage);
        interfaceInfo().aggregator.flashLoan(
            [loopFlashLoanInfo.supplyAsset], [loopFlashLoanInfo.supplyAmount], 0, data, ""
        );
    }

    /**
     * @notice Initiates an unloop operation to decrease leverage
     * @dev This function starts the unlooping process by executing a flash loan
     *      to repay borrowed tokens and withdraw supplied tokens
     * @param params The parameters for the unloop operation
     * @return True if the operation was initiated successfully
     */
    function deleverage(UnLoopFlashLoanInfo memory unLoopFlashLoanInfo) public {
        bytes memory data = abi.encode(unLoopFlashLoanInfo, LoopType.Deleverage);
        interfaceInfo().aggregator.flashLoan(
            [unLoopFlashLoanInfo.borrowAsset], [unLoopFlashLoanInfo.repayAmount], 0, data, ""
        );
    }

    ///@dev Inherit {IInstaFlashReceiverInterface}
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) external returns (bool) {
        if (msg.sender != address(interfaceInfo().aggregator)) InvalidCaller.selector.revertWith();

        (, LoopType loopType) = abi.decode(data, (LoopType));

        if (loopType == LoopType.Leverage) {
            (LoopFlashLoanInfo memory loopFlashLoanInfo) = abi.decode(data, (LoopFlashLoanInfo));
            _executeLeverage(loopFlashLoanInfo, premiums[0]);
        } else {
            (UnLoopFlashLoanInfo memory unLoopFlashLoanInfo) = abi.decode(data, (UnLoopFlashLoanInfo));
            _executeDeleverage(unLoopFlashLoanInfo, premiums[0]);
        }
    }

    function _executeLeverage(LoopFlashLoanInfo memory loopFlashLoanInfo, uint256 premium) internal {
        uint256 supply_amount = loopFlashLoanInfo.supplyAmount + loopFlashLoanInfo.flashLoanAmount;
        uint256 flashLoanRepaymentAmount = loopFlashLoanInfo.flashLoanAmount + premium;
        address router = venueStorage().venueInfo[loopFlashLoanInfo.identifier].router;
        IULW calldataForAction = interfaceInfo().ulw;

        loopFlashLoanInfo.supplyAsset.safeApprove(router, supply_amount);
        /// @notice we need a way to directly call the router function with the required calldata
        bytes memory supplyCalldata =
            calldataForAction.prepareCalldata(supply_amount, loopFlashLoanInfo.supplyAsset, address(this), 0, 0);
        router.callContract(supplyCalldata);
        bytes memory borrowCalldata = calldataForAction.prepareCalldata(
            flashLoanRepaymentAmount, loopFlashLoanInfo.borrowAsset, address(this), 2, 0
        );
        router.callContract(borrowCalldata);

        // get the dex Router

        address dexRouter = routeInfo().routes[loopFlashLoanInfo.swapCalldata.identifier].router;

        dexRouter.safeApprove(dexRouter, flashLoanRepaymentAmount);
        // perform swap
        performSwap(loopFlashLoanInfo.swapCalldata);

        // Repay the flash Loan
        loopFlashLoanInfo.supplyAsset.safeApprove(msg.sender, flashLoanRepaymentAmount);
    }

    /**
     * @notice Executes the core unloop logic during flash loan callback
     * @dev This function performs the following steps:
     *      1. Repays borrowed tokens using flash loan funds
     *      2. Withdraws supplied tokens from Aave
     *      3. Swaps withdrawn tokens to repay the flash loan
     *      5. Repays the flash loan
     */
    function _executeDeleverage(UnLoopFlashLoanInfo memory unLoopFlashLoanInfo, uint256 premium) internal {
        uint256 flashLoanRepaymentAmount = unLoopFlashLoanInfo.repayAmount + premium;
        address router = venueStorage().venueInfo[unLoopFlashLoanInfo.venueIdentifier].router;

        unLoopFlashLoanInfo.borrowAsset.safeApprove(router, unLoopFlashLoanInfo.repayAmount);
        bytes memory repayCalldata = calldataForAction.prepareCalldata(
            unLoopFlashLoanInfo.repayAmount, unLoopFlashLoanInfo.borrowAsset, address(this), 3, 0
        );
        // repayed the borrowed amount
        router.callContract(repayCalldata);

        // withdraw the supplied amount
        bytes memory withdrawCalldata = calldataForAction.prepareCalldata(
            unLoopFlashLoanInfo.withdrawAmount, unLoopFlashLoanInfo.supplyAsset, address(this), 1, 0
        );
        router.callContract(withdrawCalldata);

        //swap the supplied amount to borrow amount
        address dexRouter = routeInfo().routes[unLoopFlashLoanInfo.swapCalldata.identifier].router;
        dexRouter.safeApprove(dexRouter, unLoopFlashLoanInfo.withdrawAmount);
        performSwap(unLoopFlashLoanInfo.swapCalldata);

        //Repay the flash loan
        unLoopFlashLoanInfo.borrowAsset.safeApprove(msg.sender, flashLoanRepaymentAmount);
    }

    function _validatePositionCalldata(PositionInfo memory positionInfo) internal {}

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function vaultRegister(address vault, string memory name) external {}
}
