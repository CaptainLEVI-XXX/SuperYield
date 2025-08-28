// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// Oracle returns price to convert collateral units into debt-asset units. Scaled to 1e18.
interface IOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}
