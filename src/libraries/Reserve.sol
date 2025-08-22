// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library Reserve {
    uint256 public constant RESERVE_RATIO = 1000;

    function calculateReserveAmount(uint256 _totalAssets) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            // result = RESERVE_RATIO * _totalAssets / 10000
            result := div(mul(RESERVE_RATIO, _totalAssets), 10000)
        }
    }
}
