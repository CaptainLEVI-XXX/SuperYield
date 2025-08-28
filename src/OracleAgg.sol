// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainlinkOracle, IUniswapV3Pool,ICustomOracle} from "./interfaces/IOracle.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {TickMath} from "./libraries/TickMath.sol";

contract OracleAggregator {
    using TickMath for int24;
    using CustomRevert for bytes4;

    enum OracleType {
        None,
        Chainlink,
        UniV3TWAP,
        Custom
    }

    struct OracleConfig {
        OracleType oracleType;
        address source; // Chainlink feed or Uniswap pool
        uint256 maxDeviation; // Max % deviation between oracles (1e18 = 100%)
        uint256 maxStaleness; // Max seconds before considered stale
        bool isActive;
    }

    struct PriceFeed {
        address base; // Base token
        address quote; // Quote token (USD for most cases)
        OracleConfig primary; // Primary oracle
        OracleConfig fback; // Fallback oracle
        uint8 decimals; // Price decimals
    }

    // Admin
    address public owner;
    mapping(address => bool) public whitelistedOracles;

    // Price feeds: asset => quote => feed
    mapping(address => mapping(address => PriceFeed)) public priceFeeds;

    // TWAP settings
    uint32 public constant TWAP_PERIOD = 600; // 10 minutes

    // Constants
    uint256 public constant WAD = 1e18;
    address public constant USD = address(0); // Represents USD quote

    // Events
    event OracleConfigured(address indexed base, address indexed quote, OracleType oracleType, address source);
    event OracleWhitelisted(address indexed oracle, bool status);
    event PriceUpdated(address indexed base, address indexed quote, uint256 price);

    // Errors
    error OracleNotWhitelisted();
    error StalePrice();
    error PriceDeviation();
    error InvalidOracle();
    error NoOracleConfigured();
    error NotOwner();

    modifier onlyOwner() {
        if(msg.sender!=owner) NotOwner.selector.revertWith();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    // ======================== CONFIGURATION ========================

    function configurePriceFeed(address base, address quote, OracleConfig memory primary, OracleConfig memory fback)
        external
        onlyOwner
    {
        if(!whitelistedOracles[primary.source]) OracleNotWhitelisted.selector.revertWith();
        if (fback.source != address(0)) {
            if(!whitelistedOracles[fback.source]) OracleNotWhitelisted.selector.revertWith();
        }

        uint8 decimals = 18; // Default
        if (primary.oracleType == OracleType.Chainlink) {
            decimals = IChainlinkOracle(primary.source).decimals();
        }

        priceFeeds[base][quote] =
            PriceFeed({base: base, quote: quote, primary: primary, fback: fback, decimals: decimals});

        emit OracleConfigured(base, quote, primary.oracleType, primary.source);
    }

    function whitelistOracle(address oracle, bool status) external onlyOwner {
        whitelistedOracles[oracle] = status;
        emit OracleWhitelisted(oracle, status);
    }

    // ======================== PRICE QUERIES ========================

    /**
     * @notice Get price of base token in quote token
     * @param base Base token address
     * @param quote Quote token address (use address(0) for USD)
     * @return price Price with 18 decimals
     */
    function getPrice(address base, address quote) external view returns (uint256 price) {
        PriceFeed memory feed = priceFeeds[base][quote];
        if (feed.primary.source == address(0))  NoOracleConfigured.selector.revertWith();

        (uint256 primaryPrice, bool primaryValid) = _getOraclePrice(feed.primary, base, quote);

        if (!primaryValid && feed.fback.source != address(0)) {
            // Try fallback
            (uint256 fallbackPrice, bool fallbackValid) = _getOraclePrice(feed.fback, base, quote);
            if (!fallbackValid) StalePrice.selector.revertWith();
            return fallbackPrice;
        }

        if (!primaryValid) StalePrice.selector.revertWith();

        // If both primary and fallback exist, check deviation
        if (feed.fback.source != address(0)) {
            (uint256 fallbackPrice, bool fallbackValid) = _getOraclePrice(feed.fback, base, quote);
            if (fallbackValid) {
                uint256 deviation = _calculateDeviation(primaryPrice, fallbackPrice);
                if (deviation > feed.primary.maxDeviation) PriceDeviation.selector.revertWith();
            }
        }

        return primaryPrice;
    }

    /**
     * @notice Get price from specific oracle type
     */
    function _getOraclePrice(OracleConfig memory config, address base, address quote)
        internal
        view
        returns (uint256 price, bool valid)
    {
        if (!config.isActive) return (0, false);

        if (config.oracleType == OracleType.Chainlink) {
            return _getChainlinkPrice(config);
        } else if (config.oracleType == OracleType.UniV3TWAP) {
            return _getUniV3TWAPPrice(config, base);
        } else if (config.oracleType == OracleType.Custom) {
            return _getCustomPrice(config, base, quote);
        }

        return (0, false);
    }

    /**
     * @notice Get Chainlink price
     */
    function _getChainlinkPrice(OracleConfig memory config) internal view returns (uint256 price, bool valid) {
        IChainlinkOracle oracle = IChainlinkOracle(config.source);

        try oracle.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return (0, false);
            if (block.timestamp - updatedAt > config.maxStaleness) return (0, false);

            uint8 decimals = oracle.decimals();
            // forge-lint: disable-next-line(unsafe-typecast)
            price = uint256(answer) * WAD / (10 ** decimals);
            return (price, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Get Uniswap V3 TWAP price
     */
    function _getUniV3TWAPPrice(OracleConfig memory config, address base)
        internal
        view
        returns (uint256 price, bool valid)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(config.source);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(TWAP_PERIOD)));

            // Calculate price from tick
            price = _getQuoteAtTick(arithmeticMeanTick, base, pool.token0());

            // Check staleness (simplified - in production check pool activity)
            return (price, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Get custom oracle price (for specialized oracles)
     */
    function _getCustomPrice(OracleConfig memory config, address base, address quote)
        internal
        view
        returns (uint256 price, bool valid)
    {
        // Call custom oracle interface
        // This could be Pendle oracle, Term oracle, etc.
        ICustomOracle oracle = ICustomOracle(config.source);
        try oracle.getPrice(base, quote) returns (uint256 p) {
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    // ======================== HELPERS ========================

    function _calculateDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 avg = (price1 + price2) / 2;
        return diff * WAD / avg;
    }

    function _getQuoteAtTick(int24 tick, address baseToken, address token0)
        internal
        pure
        returns (uint256 quote)
    {
        uint160 sqrtRatioX96 = tick.getSqrtPriceAtTick();
        uint256 sqrtRatioX96AsUint256 = uint256(sqrtRatioX96);

        // Calculate price based on token ordering
        if (baseToken == token0) {
            // price = (sqrtRatioX96 / 2^96)^2
            quote = sqrtRatioX96AsUint256 * sqrtRatioX96AsUint256 * WAD >> 192;
        } else {
            // price = 1 / (sqrtRatioX96 / 2^96)^2
            quote = (1 << 192) * WAD / (sqrtRatioX96AsUint256 * sqrtRatioX96AsUint256);
        }
    }

    // ======================== ADAPTER FUNCTIONS ========================

    /**
     * @notice Get price for liquidation calculations
     * @dev Returns price in 18 decimals for consistency
     */
    function getPriceForLiquidation(address collateral, address debt) external view returns (uint256) {
        // Try to get collateral/debt price directly
        PriceFeed memory directFeed = priceFeeds[collateral][debt];
        if (directFeed.primary.source != address(0)) {
            return this.getPrice(collateral, debt);
        }

        // Otherwise get both in USD and calculate
        uint256 collateralUsd = this.getPrice(collateral, USD);
        uint256 debtUsd = this.getPrice(debt, USD);

        return collateralUsd * WAD / debtUsd;
    }
}
