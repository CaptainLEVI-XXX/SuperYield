// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract ExecutionStorage {
    enum PositionStatus {
        Inactive,
        Active,
        Migrated
    }

    struct Position {
        address vault;
        address supplyAsset;
        address borrowAsset;
        bytes32 currentVenue;
        uint256 totalSupplied;
        uint256 totalBorrowed;
        PositionStatus status;
    }

    struct PositionStorage {
        uint256 nextPositionId;
        mapping(uint256 => Position) positions;
    }

    struct VaultInfo {
        mapping(address => uint256[]) vaultPositions;
        mapping(address => bool) vaults;
    }

    address preLiquidationManager;
    //vault positions
    // mapping(address => uint256[]) public vaultPositions;

    // address public preLiquidationManager;

    // mapping(address => uint256) public reserves; // asset => amount

    // mapping(address => bool) public vaults;
    // mapping(address => mapping(address => uint256)) public vaultReserves; // vault => asset => amount

    error OperationLocked();

    event PositionOpened(uint256 indexed positionId, address vault, bytes32 venue);
    event PositionClosed(uint256 indexed positionId, uint256 finalAmount);
    event PositionRebalanced(uint256 indexed positionId, bytes32 from, bytes32 to);
    event ReservesUpdated(address asset, uint256 amount);

    error InvalidCaller();
    //keccak256("vault.storage.strategy.manager")

    bytes32 public constant VAULT_INFO_STORAGE = 0x4b447290613135138bf05d4f5bb11b41bfd01c54a8048e80ad8255e3b5bbc234;
    //keccak256("position.storage.startegy.manager")
    bytes32 public constant POSITION_STORAGE = 0xbbe13fcdc9f28acfc2599f6f86642e1e48a217e88d8f2f5994bfae2cced0e0ca;

    function _vaultStorage() internal pure returns (VaultInfo storage vaultInfo) {
        bytes32 position = VAULT_INFO_STORAGE;
        assembly {
            vaultInfo.slot := position
        }
    }

    function _positionStorage() internal pure returns (PositionStorage storage positionStorage) {
        bytes32 position = VAULT_INFO_STORAGE;
        assembly {
            positionStorage.slot := position
        }
    }
}
