// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract UniversalLendingWrapper {
    // Protocol identifiers
    uint8 public constant AAVE_V3 = 0;
    uint8 public constant AAVE_V2 = 1;
    uint8 public constant COMPOUND_V3 = 2;
    uint8 public constant COMPOUND_V2 = 3;
    uint8 public constant MORPHO_AAVE = 4;

    // Operation types
    uint8 public constant SUPPLY = 0;
    uint8 public constant WITHDRAW = 1;
    uint8 public constant BORROW = 2;
    uint8 public constant REPAY = 3;

    error InvalidOperation();
    error InvalidProtocol();

    // New batch function for supply + borrow
    function getBatchSupplyBorrow(
        address supplyAsset,
        uint256 supplyAmount,
        address borrowAsset,
        uint256 borrowAmount,
        address receiver,
        uint8 protocol
    ) external pure returns (bytes memory supplyData, bytes memory borrowData) {
        supplyData = _getCalldata(supplyAsset, supplyAmount, receiver, SUPPLY, protocol);
        borrowData = _getCalldata(borrowAsset, borrowAmount, receiver, BORROW, protocol);
    }

    // New batch function for repay + withdraw (for deleveraging)
    function getBatchRepayWithdraw(
        address repayAsset,
        uint256 repayAmount,
        address withdrawAsset,
        uint256 withdrawAmount,
        address receiver,
        uint8 protocol
    ) external pure returns (bytes memory repayData, bytes memory withdrawData) {
        repayData = _getCalldata(repayAsset, repayAmount, receiver, REPAY, protocol);
        withdrawData = _getCalldata(withdrawAsset, withdrawAmount, receiver, WITHDRAW, protocol);
    }

    // New function that returns packed calldata for multicall execution
    function getMulticallData(
        address supplyAsset,
        uint256 supplyAmount,
        address borrowAsset,
        uint256 borrowAmount,
        address receiver,
        uint8 protocol
    ) external pure returns (bytes memory multicallData) {
        bytes memory supplyData = _getCalldata(supplyAsset, supplyAmount, receiver, SUPPLY, protocol);
        bytes memory borrowData = _getCalldata(borrowAsset, borrowAmount, receiver, BORROW, protocol);

        // Pack both calldatas with their lengths for easier parsing
        assembly {
            multicallData := mload(0x40)
            let ptr := add(multicallData, 0x20)

            // Store number of calls (2)
            mstore(ptr, 2)
            ptr := add(ptr, 0x20)

            // Store first calldata length and data
            let supplyLen := mload(supplyData)
            mstore(ptr, supplyLen)
            ptr := add(ptr, 0x20)

            // Copy supply calldata
            let supplyDataPtr := add(supplyData, 0x20)
            for { let i := 0 } lt(i, supplyLen) { i := add(i, 0x20) } {
                mstore(add(ptr, i), mload(add(supplyDataPtr, i)))
            }
            ptr := add(ptr, supplyLen)

            // Store second calldata length and data
            let borrowLen := mload(borrowData)
            mstore(ptr, borrowLen)
            ptr := add(ptr, 0x20)

            // Copy borrow calldata
            let borrowDataPtr := add(borrowData, 0x20)
            for { let i := 0 } lt(i, borrowLen) { i := add(i, 0x20) } {
                mstore(add(ptr, i), mload(add(borrowDataPtr, i)))
            }
            ptr := add(ptr, borrowLen)

            // Set total length
            mstore(multicallData, sub(ptr, add(multicallData, 0x20)))
            mstore(0x40, ptr)
        }
    }

    // Make the original function internal to reuse logic
    function _getCalldata(address asset, uint256 amount, address receiver, uint8 operation, uint8 protocol)
        internal
        pure
        returns (bytes memory data)
    {
        assembly {
            data := mload(0x40)
            let ptr := add(data, 0x20)

            switch protocol
            // AAVE V3
            case 0 {
                switch operation
                case 0 {
                    // supply(address,uint256,address,uint16)
                    mstore(ptr, shl(224, 0x617ba037))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(add(ptr, 0x64), 0)
                    mstore(data, 0x84)
                }
                case 1 {
                    // withdraw(address,uint256,address)
                    mstore(ptr, shl(224, 0x69328dec))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 2 {
                    // borrow(address,uint256,uint256,uint16,address)
                    mstore(ptr, shl(224, 0xa415bcad))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2) // variable rate
                    mstore(add(ptr, 0x64), 0) // referralCode
                    mstore(add(ptr, 0x84), receiver)
                    mstore(data, 0xa4)
                }
                case 3 {
                    // repay(address,uint256,uint256,address)
                    mstore(ptr, shl(224, 0x573ade81))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2) // variable rate
                    mstore(add(ptr, 0x64), receiver)
                    mstore(data, 0x84)
                }
                default {
                    mstore(0x00, shl(224, 0x1a8e2176))
                    revert(0x00, 0x04)
                }
            }
            // AAVE V2 (same as V3)
            case 1 {
                switch operation
                case 0 {
                    mstore(ptr, shl(224, 0x617ba037))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(add(ptr, 0x64), 0)
                    mstore(data, 0x84)
                }
                case 1 {
                    mstore(ptr, shl(224, 0x69328dec))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 2 {
                    mstore(ptr, shl(224, 0xa415bcad))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2)
                    mstore(add(ptr, 0x64), 0)
                    mstore(add(ptr, 0x84), receiver)
                    mstore(data, 0xa4)
                }
                case 3 {
                    mstore(ptr, shl(224, 0x573ade81))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2)
                    mstore(add(ptr, 0x64), receiver)
                    mstore(data, 0x84)
                }
                default {
                    mstore(0x00, shl(224, 0x1a8e2176))
                    revert(0x00, 0x04)
                }
            }
            // COMPOUND V3
            case 2 {
                switch operation
                case 0 {
                    // supply(address,uint256)
                    mstore(ptr, shl(224, 0xf2b9fdb8))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 1 {
                    // withdraw(address,uint256)
                    mstore(ptr, shl(224, 0xf3fef3a3))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 2 {
                    // borrow = withdraw in V3
                    mstore(ptr, shl(224, 0xf3fef3a3))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 3 {
                    // repay = supply in V3
                    mstore(ptr, shl(224, 0xf2b9fdb8))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                default {
                    mstore(0x00, shl(224, 0x1a8e2176))
                    revert(0x00, 0x04)
                }
            }
            // COMPOUND V2
            case 3 {
                switch operation
                case 0 {
                    // mint(uint256)
                    mstore(ptr, shl(224, 0xa0712d68))
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                case 1 {
                    // redeem(uint256)
                    mstore(ptr, shl(224, 0xdb006a75))
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                case 2 {
                    // borrow(uint256)
                    mstore(ptr, shl(224, 0xc5ebeaec))
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                case 3 {
                    // repayBorrow(uint256)
                    mstore(ptr, shl(224, 0x0e752702))
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                default {
                    mstore(0x00, shl(224, 0x1a8e2176))
                    revert(0x00, 0x04)
                }
            }
            // MORPHO
            case 4 {
                switch operation
                case 0 {
                    mstore(ptr, shl(224, 0x0c0a769b))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 1 {
                    mstore(ptr, shl(224, 0x69328dec))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 2 {
                    mstore(ptr, shl(224, 0x4b8a3529))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 3 {
                    mstore(ptr, shl(224, 0x5ceae9c4))
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                default {
                    mstore(0x00, shl(224, 0x1a8e2176))
                    revert(0x00, 0x04)
                }
            }
            default {
                mstore(0x00, shl(224, 0x3db16044))
                revert(0x00, 0x04)
            }

            mstore(0x40, add(data, add(mload(data), 0x20)))
        }
    }

    // Keep the original external function for backwards compatibility
    function getCalldata(address asset, uint256 amount, address receiver, uint8 operation, uint8 protocol)
        external
        pure
        returns (bytes memory data)
    {
        return _getCalldata(asset, amount, receiver, operation, protocol);
    }

    function getCalldataSimple(address asset, uint256 amount, uint8 operation, uint8 protocol)
        external
        view
        returns (bytes memory data)
    {
        return _getCalldata(asset, amount, msg.sender, operation, protocol);
    }

    function packOp(uint8 protocol, uint8 operation, address asset, uint80 amount) external pure returns (bytes32) {
        return bytes32(
            uint256(protocol) << 248 | uint256(operation) << 240 | uint256(uint160(asset)) << 80 | uint256(amount)
        );
    }
}
