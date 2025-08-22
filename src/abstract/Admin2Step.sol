// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Inspired from the @solady ------ A different approach toward Ownable2Step

abstract contract Admin2Step {
    /// @dev The caller is not authorized to call the function.
    error Admin2Step_Unauthorized();

    /// @dev The `pendingAdmin` does not have a valid handover request.
    error Admin2Step_NoHandoverRequest();

    /// @dev Cannot double-initialize.
    error Admin2Step_NewAdminIsZeroAddress();

    /// @dev The adminship is transferred from `oldAdmin` to `newAdmin`.

    event AdminshipTransferred(address indexed oldAdmin, address indexed newAdmin);

    /// @dev An adminship handover to `pendingAdmin` has been requested.
    event AdminshipHandoverRequested(address indexed pendingAdmin);

    /// @dev The adminship handover to `pendingAdmin` has been canceled.
    event AdminshipHandoverCanceled(address indexed pendingAdmin);

    /// @dev The admin slot is given by:

    /// @dev keccak256("Hashstack._ADMIN_SLOT")
    bytes32 internal constant _ADMIN_SLOT = 0x728a99fd4f405dacd9be416f0ab5362a3b8a45ae01e04e4531610f3b47f0f332;
    /// @dev keccak256("Hashstack.admin._PENDING_ADMIN_SLOT")
    bytes32 internal constant _PENDING_ADMIN_SLOT = 0xd6dfe080f721daab5530894dccfcc2993346c67103e2bcc8748bf87935f5b4d9;
    /// @dev keccak256("Hashstack.admin._HANDOVERTIME_ADMIN_SLOT_SEED")
    bytes32 internal constant _HANDOVERTIME_ADMIN_SLOT_SEED =
        0x6550ab69b2fd0d6b77d1a3569484949e74afb818f9de20661d5d5d6082bcd5de;

    /// @dev Sets the admin directly without authorization guard.
    function _setAdmin(address _newAdmin) internal virtual {
        assembly ("memory-safe") {
            if eq(_newAdmin, 0) {
                // Load pre-defined error selector for zero address
                mstore(0x00, 0x4869eb34) // NewAdminIsZeroAddress error
                revert(0x1c, 0x04)
            }
            /// @dev `keccak256(bytes("AdminshipTransferred(address,address)"))
            log3(
                0, 0, 0x04d129ae6ee1a7d168abd097a088e4f07a0292c23aefc0e49b5603d029b8543f, sload(_ADMIN_SLOT), _newAdmin
            )
            sstore(_ADMIN_SLOT, _newAdmin)
        }
    }

    /// @dev Throws if the sender is not the admin.
    function _checkAdmin() internal view virtual {
        assembly ("memory-safe") {
            // If the caller is not the stored admin, revert.
            if iszero(eq(caller(), sload(_ADMIN_SLOT))) {
                mstore(0x00, 0x591f9739) // `Admin2Step_Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Returns how long a two-step adminship handover is valid for in seconds.
    /// Override to return a different value if needed.
    /// Made internal to conserve bytecode. Wrap it in a public function if needed.
    function _adminHandoverValidFor() internal view virtual returns (uint64) {
        return 3 * 86400;
    }

    /// @dev Request a two-step adminship handover to the caller.
    /// The request will automatically expire in 72 hoursby default.
    function requestAdminTransfer(address _pendingOwner) public virtual onlyAdmin {
        unchecked {
            uint256 expires = block.timestamp + _adminHandoverValidFor();
            assembly ("memory-safe") {
                sstore(_PENDING_ADMIN_SLOT, _pendingOwner)
                sstore(_HANDOVERTIME_ADMIN_SLOT_SEED, expires)
                // Emit the {AdminshipHandoverRequested} event.
                log2(0, 0, 0xa391cf6317e44c1bf84ce787a20d5a7193fa44caff9e68b0597edf3cabd29fb7, _pendingOwner)
            }
        }
    }

    /// @dev Cancels the two-step adminship handover to the caller, if any.
    function cancelAdminTransfer() public virtual onlyAdmin {
        assembly ("memory-safe") {
            // Compute and set the handover slot to 0.
            sstore(_PENDING_ADMIN_SLOT, 0x0)
            sstore(_HANDOVERTIME_ADMIN_SLOT_SEED, 0x0)
            // Emit the {SuperAdminshipHandoverCanceled} event.
            log2(0, 0, 0x1570624318df302ecdd05ea20a0f8b0f8931a0cb8f4f1f8e07221e636988aa7b, caller())
        }
    }

    /// @dev Allows the admin to complete the two-step adminship handover to `pendingAdmin`.
    /// Reverts if there is no existing adminship handover requested by `pendingAdmin`.
    function acceptAdminTransfer() public virtual {
        /// @solidity memory-safe-assembly

        address pendingAdmin;
        assembly ("memory-safe") {
            pendingAdmin := sload(_PENDING_ADMIN_SLOT)

            // Check that the sender is the pending admin
            if iszero(eq(caller(), pendingAdmin)) {
                mstore(0x00, 0x591f9739) // Unauthorized error
                revert(0x1c, 0x04)
            }
            // If the handover does not exist, or has expired.
            if gt(timestamp(), sload(_HANDOVERTIME_ADMIN_SLOT_SEED)) {
                mstore(0x00, 0x12c74381) // `Admin2Step_NoHandoverRequest()`.
                revert(0x1c, 0x04)
            }
            // Set the handover slot to 0.
            sstore(_HANDOVERTIME_ADMIN_SLOT_SEED, 0)
            sstore(_PENDING_ADMIN_SLOT, 0)
        }
        _setAdmin(pendingAdmin);
    }

    /// @dev Returns the admin of the contract.
    function admin() public view virtual returns (address result) {
        assembly ("memory-safe") {
            result := sload(_ADMIN_SLOT)
        }
    }

    /// @dev Returns the expiry timestamp for the two-step adminship handover to `pendingAdmin`.
    function adminHandoverExpiresAt() public view virtual returns (uint256 result) {
        assembly ("memory-safe") {
            // Load the handover slot.
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /// @dev Marks a function as only callable by the admin.
    modifier onlyAdmin() virtual {
        _checkAdmin();
        _;
    }
}
