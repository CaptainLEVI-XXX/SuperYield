// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// Oracle returns price to convert collateral units into debt-asset units. Scaled to 1e18.
interface IOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

interface ICustomOracle {
    function getPrice(address base, address quote) external view returns (uint256);
}
