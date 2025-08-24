// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract UniversalLendingWrapper {
    // Protocol identifiers
    uint8 constant AAVE_V3 = 0;
    uint8 constant AAVE_V2 = 1;
    uint8 constant COMPOUND_V3 = 2;
    uint8 constant COMPOUND_V2 = 3;
    uint8 constant MORPHO_AAVE = 4;
    uint8 constant SPARK = 5;
    uint8 constant RADIANT = 6;

    // Operation types (universal across protocols)
    uint8 constant SUPPLY = 0;
    uint8 constant WITHDRAW = 1;
    uint8 constant BORROW = 2;
    uint8 constant REPAY = 3;

    error InvalidOperation();
    error InvalidProtocol();

    /**
     * @notice Universal calldata generator for any lending protocol
     * @param asset The asset address (or cToken for Compound V2)
     * @param amount The amount
     * @param receiver The receiver/onBehalfOf address
     * @param operation Operation type (0-3)
     * @param protocol Protocol identifier (0-6)
     * @return data The encoded calldata
     */
    function getCalldata(address asset, uint256 amount, address receiver, uint8 operation, uint8 protocol)
        external
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
                    // supply
                    mstore(ptr, 0x617ba037)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(add(ptr, 0x64), 0) // referralCode
                    mstore(data, 0x84)
                }
                case 1 {
                    // withdraw
                    mstore(ptr, 0x69328dec)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 2 {
                    // borrow
                    mstore(ptr, 0xa415bcad)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2) // variable rate
                    mstore(add(ptr, 0x64), 0) // referralCode
                    mstore(add(ptr, 0x84), receiver)
                    mstore(data, 0xa4)
                }
                case 3 {
                    // repay
                    mstore(ptr, 0x573ade81)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2) // variable rate
                    mstore(add(ptr, 0x64), receiver)
                    mstore(data, 0x84)
                }
                default {
                    mstore(0x00, 0x1a8e2176)
                    revert(0x00, 0x04)
                }
            }
            case 1 {
                switch operation
                case 0 {
                    // supply
                    mstore(ptr, 0x617ba037)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(add(ptr, 0x64), 0) // referralCode
                    mstore(data, 0x84)
                }
                case 1 {
                    // withdraw
                    mstore(ptr, 0x69328dec)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 2 {
                    // borrow
                    mstore(ptr, 0xa415bcad)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2) // variable rate
                    mstore(add(ptr, 0x64), 0) // referralCode
                    mstore(add(ptr, 0x84), receiver)
                    mstore(data, 0xa4)
                }
                case 3 {
                    // repay
                    mstore(ptr, 0x573ade81)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), 2) // variable rate
                    mstore(add(ptr, 0x64), receiver)
                    mstore(data, 0x84)
                }
                default {
                    mstore(0x00, 0x1a8e2176)
                    revert(0x00, 0x04)
                }
            }
            // COMPOUND V3 (Comet)
            case 2 {
                switch operation
                case 0 {
                    // supply
                    mstore(ptr, 0xf2b9fdb8) // supply(address,uint256)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 1 {
                    // withdraw
                    mstore(ptr, 0xf3fef3a3) // withdraw(address,uint256)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 2 {
                    // borrow - same as withdraw in V3
                    mstore(ptr, 0xf3fef3a3)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 3 {
                    // repay - same as supply in V3
                    mstore(ptr, 0xf2b9fdb8)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                default {
                    mstore(0x00, 0x1a8e2176)
                    revert(0x00, 0x04)
                }
            }
            // COMPOUND V2
            case 3 {
                switch operation
                case 0 {
                    // mint
                    mstore(ptr, 0xa0712d68) // mint(uint256)
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                case 1 {
                    // redeem
                    mstore(ptr, 0xdb006a75) // redeem(uint256)
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                case 2 {
                    // borrow
                    mstore(ptr, 0xc5ebeaec) // borrow(uint256)
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                case 3 {
                    // repayBorrow
                    mstore(ptr, 0x0e752702) // repayBorrow(uint256)
                    mstore(add(ptr, 0x04), amount)
                    mstore(data, 0x24)
                }
                default {
                    mstore(0x00, 0x1a8e2176)
                    revert(0x00, 0x04)
                }
            }
            // MORPHO
            case 4 {
                switch operation
                case 0 {
                    // supply
                    mstore(ptr, 0x0c0a769b) // supply selctor for Morpho
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 1 {
                    // withdraw
                    mstore(ptr, 0x69328dec)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(data, 0x44)
                }
                case 2 {
                    // borrow
                    mstore(ptr, 0x4b8a3529)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                case 3 {
                    // repay
                    mstore(ptr, 0x5ceae9c4)
                    mstore(add(ptr, 0x04), asset)
                    mstore(add(ptr, 0x24), amount)
                    mstore(add(ptr, 0x44), receiver)
                    mstore(data, 0x64)
                }
                default {
                    mstore(0x00, 0x1a8e2176)
                    revert(0x00, 0x04)
                }
            }
            default {
                mstore(0x00, 0x3db16044) // InvalidProtocol selector
                revert(0x00, 0x04)
            }

            mstore(0x40, add(data, add(mload(data), 0x20)))
        }
    }

    /**
     * @notice Simplified for common case - when receiver is always msg.sender
     * @dev Even more gas efficient when receiver is known
     */
    function getCalldataSimple(address asset, uint256 amount, uint8 operation, uint8 protocol)
        external
        view
        returns (bytes memory data)
    {
        return this.getCalldata(asset, amount, msg.sender, operation, protocol);
    }

    /**
     * @notice Pack multiple operations for batching
     * @dev Format: [protocol(1)][operation(1)][asset(20)][amount(10)]
     */
    function packOp(
        uint8 protocol,
        uint8 operation,
        address asset,
        uint80 amount // 80 bits is enough for most amounts
    ) external pure returns (bytes32) {
        return bytes32(
            uint256(protocol) << 248 | uint256(operation) << 240 | uint256(uint160(asset)) << 80 | uint256(amount)
        );
    }
}
