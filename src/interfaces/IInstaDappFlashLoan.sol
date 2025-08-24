// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Instadapp FlashLoan Aggragtor FlashLoanReceiver Interface

interface IInstaFlashReceiverInterface {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) external returns (bool);
}

// Instadapp FlashLoan Aggragtor
interface IInstaFlashAggregatorInterface {
    function flashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 route,
        bytes calldata data,
        bytes calldata instaData
    ) external;

    function getRoutes() external returns (uint16[] memory routes);
    function getBestRoutes(address[] memory tokens, uint256[] memory amounts)
        external
        returns (uint16[] memory, uint256, bytes[] memory);
}
