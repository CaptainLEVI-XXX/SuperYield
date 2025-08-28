// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IUniversalLendingWrapper {
    function getCalldata(address asset, uint256 amount, address receiver, uint8 operation, uint8 protocol)
        external
        view
        returns (bytes memory data);
}
