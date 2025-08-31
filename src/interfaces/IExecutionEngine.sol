// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
// Minimal engine interface the vault expects.

interface IExecutionEngine {
    function deployCapital(uint256 amount) external;
    function recallCapital(uint256 amount) external returns (uint256);
    function getDeployedValue(address vault) external view returns (uint256);
}

interface IStrategyManager {
    function executePreLiquidation(uint256 positionId, uint256 repayAmount, uint256 seizeAmount, address keeper)
        external
        returns (uint256, uint256);

    function getPosition(uint256 positionId) external view returns (uint256 collateral, uint256 debt);
}
