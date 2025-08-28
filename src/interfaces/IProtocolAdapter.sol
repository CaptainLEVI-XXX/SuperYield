// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IProtocolAdapter {
    function getPositionUsd(bytes32 marketId, address borrower)
        external
        view
        returns (uint256 collateralUsd, uint256 debtUsd);

    function getTokens(bytes32 marketId) external view returns (address collateralToken, address debtToken);

    function usdToTokenUnits(address token, uint256 usdAmount) external view returns (uint256);

    function tokenUnitsToUsd(address token, uint256 units) external view returns (uint256);

    function lltv(bytes32 marketId) external view returns (uint256);
}
