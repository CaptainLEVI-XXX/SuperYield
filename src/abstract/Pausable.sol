// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

abstract contract Pausable {
    bytes32 private constant _PAUSED_SLOT = keccak256("super.vault.paused.slot");

    event Paused();
    event Unpaused();

    function pause() public virtual {
        bytes32 slot = _PAUSED_SLOT;
        assembly ("memory-safe") {
            sstore(slot, 0x01)
        }
        emit Paused();
    }

    function unpause() public virtual {
        bytes32 slot = _PAUSED_SLOT;
        assembly ("memory-safe") {
            sstore(slot, 0x00)
        }
        emit Unpaused();
    }

    function isPaused() public view returns (bool flag) {
        bytes32 slot = _PAUSED_SLOT;
        assembly ("memory-safe") {
            flag := sload(slot)
        }
    }
}
