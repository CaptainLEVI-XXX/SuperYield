// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceOracleSimple {
    function getPrice(address asset) external view returns (uint256);
}

contract ConstantOracle is IPriceOracleSimple {
    mapping(address => uint256) public px;

    function getPrice(address asset) external view returns (uint256) {
        return px[asset];
    }

    function setPrice(address asset, uint256 _px) external {
        px[asset] = _px;
    }
}
