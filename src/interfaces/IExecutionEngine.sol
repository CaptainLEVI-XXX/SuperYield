// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
// Minimal engine interface the vault expects.

interface IExecutionEngine {
    function deployCapital(uint256 amount) external;
    function recallCapital(uint256 amount) external returns (uint256);
    function getDeployedValue(address vault) external view returns (uint256);
}

interface IStrategyManager {
    function executePreLiquidation(
        bytes32 protocolId,
        bytes32 marketId,
        address debtToken,
        address collateralToken,
        uint256 repayAmount,
        uint256 seizeAmount,
        address keeper
    ) external returns (uint256 actualRepaid, uint256 actualSeized);

    function getPosition(bytes32 protocolId, bytes32 marketId)
        external
        view
        returns (uint256 collateral, uint256 debt);
}
