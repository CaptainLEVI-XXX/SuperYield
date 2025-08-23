// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
// Minimal engine interface the vault expects.

interface IExecutionEngine {
    function deployCapital(uint256 amount) external;
    function recallCapital(uint256 amount) external returns (uint256);
    function getDeployedValue() external view returns (uint256);
}
