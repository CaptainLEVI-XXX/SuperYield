// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * ============ Libraries ============
 */
library WadMath {
    uint256 internal constant WAD = 1e18;

    function wMul(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return (a * b) / WAD;
        }
    }

    function wDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "DIV0");
        unchecked {
            return (a * WAD) / b;
        }
    }

    function mulDivDown(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        require(d != 0, "DIV0");
        unchecked {
            return (a * b) / d;
        }
    }
}
