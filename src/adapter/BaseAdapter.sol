// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ProtocolAdapter
 * @notice Simplified adapters that only provide position data and conversions
 * @dev No longer executes liquidations - only provides read functions
 */
abstract contract ProtocolAdapter {
    struct PositionInfo {
        uint256 collateralUsd;
        uint256 debtUsd;
        address collateralToken;
        address debtToken;
    }

    /**
     * @notice Get position in USD terms
     */
    function getPositionUsd(bytes32 marketId, address borrower)
        external
        view
        virtual
        returns (uint256 collateralUsd, uint256 debtUsd);

    /**
     * @notice Get token addresses for a market
     */
    function getTokens(bytes32 marketId) external view virtual returns (address collateralToken, address debtToken);

    /**
     * @notice Convert USD to token units
     */
    function usdToTokenUnits(address token, uint256 usdAmount) external view virtual returns (uint256);

    /**
     * @notice Convert token units to USD
     */
    function tokenUnitsToUsd(address token, uint256 units) external view virtual returns (uint256);

    /**
     * @notice Get protocol's liquidation threshold
     */
    function lltv(bytes32 marketId) external view virtual returns (uint256);
}
