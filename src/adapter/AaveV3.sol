// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {IPoolDataProvider} from "../interfaces/IAavePoolV3.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ProtocolAdapter} from "./BaseAdapter.sol";
import {Admin2Step} from "../abstract/Admin2Step.sol";
import {console} from "forge-std/console.sol";

/**
 * @title AaveV3Adapter
 * @notice Adapter for reading Aave V3 positions
 */
contract AaveV3Adapter is ProtocolAdapter, Admin2Step {
    IPoolDataProvider public immutable dataProvider;
    IOracle public immutable oracle;

    struct MarketInfo {
        address collateralToken;
        address debtToken;
    }

    mapping(bytes32 => MarketInfo) public markets;

    constructor(address _dataProvider, address _oracle, address _owner) {
        dataProvider = IPoolDataProvider(_dataProvider);
        oracle = IOracle(_oracle);
        _setAdmin(_owner);
    }

    function registerMarket(address collateralToken, address debtToken) external onlyAdmin returns (bytes32 marketId) {
        marketId = keccak256(abi.encodePacked(collateralToken, debtToken, "AaveV3"));
        markets[marketId] = MarketInfo({collateralToken: collateralToken, debtToken: debtToken});
    }

    function getPositionUsd(address collateralToken, address debtToken, address borrower)
        external
        view
        override
        returns (uint256 collateralUsd, uint256 debtUsd)
    {
        return getPositionUsd(keccak256(abi.encodePacked(collateralToken, debtToken, "AaveV3")), borrower);
    }

    function getPositionUsd(bytes32 marketId, address borrower)
        public
        view
        override
        returns (uint256 collateralUsd, uint256 debtUsd)
    {
        MarketInfo memory market = markets[marketId];

        // Get collateral balance (aToken balance)
        (uint256 collateralBalance,,,,,,,,) = dataProvider.getUserReserveData(market.collateralToken, borrower);

        // Get debt balance
        (, uint256 stableDebt, uint256 variableDebt,,,,,,) = dataProvider.getUserReserveData(market.debtToken, borrower);
        uint256 totalDebt = stableDebt + variableDebt;

        // Convert to USD using Aave's oracle
        uint256 collateralPrice = oracle.getPrice(market.collateralToken, address(0));
        uint256 debtPrice = oracle.getPrice(market.debtToken, address(0));

        uint8 collateralDecimals = IERC20Metadata(market.collateralToken).decimals();
        uint8 debtDecimals = IERC20Metadata(market.debtToken).decimals();

        collateralUsd = (collateralBalance * collateralPrice) / (10 ** collateralDecimals);
        debtUsd = (totalDebt * debtPrice) / (10 ** debtDecimals);
    }

    function getTokens(bytes32 marketId) external view override returns (address collateralToken, address debtToken) {
        MarketInfo memory market = markets[marketId];
        return (market.collateralToken, market.debtToken);
    }

    function usdToTokenUnits(address token, uint256 usdAmount18) external view override returns (uint256) {
        // usdAmount18 is always in 18 decimals
        uint256 price = oracle.getPrice(token, address(0)); // 18 decimals
        uint8 decimals = IERC20Metadata(token).decimals();

        // (usd * 10^decimals) / price
        return (usdAmount18 * (10 ** decimals)) / price;
    }

    function tokenUnitsToUsd(address token, uint256 units) external view override returns (uint256) {
        uint256 price = oracle.getPrice(token, address(0)); // 18 decimals
        uint8 decimals = IERC20Metadata(token).decimals();

        // returns 18 decimals USD
        return (units * price) / (10 ** decimals);
    }

    function lltv(bytes32 marketId) external view override returns (uint256) {
        MarketInfo memory market = markets[marketId];
        (,, uint256 liquidationThreshold,,,,,,,) = dataProvider.getReserveConfigurationData(market.collateralToken);
        return liquidationThreshold * 1e14; // Convert BPS to WAD
    }
}
