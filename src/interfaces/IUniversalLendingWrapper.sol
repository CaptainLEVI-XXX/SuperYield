// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IUniversalLendingWrapper {
    function getCalldata(address asset, uint256 amount, address receiver, uint8 operation, uint8 protocol)
        external
        view
        returns (bytes memory data);
    function getBatchSupplyBorrow(
        address supplyAsset,
        uint256 supplyAmount,
        address borrowAsset,
        uint256 borrowAmount,
        address receiver,
        uint8 protocol
    ) external view returns (bytes memory supplyData, bytes memory borrowData);

    function getBatchRepayWithdraw(
        address repayAsset,
        uint256 repayAmount,
        address withdrawAsset,
        uint256 withdrawAmount,
        address receiver,
        uint8 protocol
    ) external view returns (bytes memory repayData, bytes memory withdrawData);
}
