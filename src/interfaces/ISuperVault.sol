// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ISuperVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function asset() external view returns (address);
    function balanceOf(address owner) external view returns (uint256);

    function approve(address spender, uint256 amount) external;
}
