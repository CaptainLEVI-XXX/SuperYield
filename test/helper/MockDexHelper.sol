// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DexHelper} from "../../src/abstract/DexHelper.sol";

contract MockDexHelper is DexHelper {
    function whitelistRoute(string memory name, address _router) public virtual override returns (bytes32) {
        return super.whitelistRoute(name, _router);
    }

    function updateRouteStatus(bytes32[] calldata identifier, bool[] calldata status)
        public
        virtual
        override
        returns (bool)
    {
        return super.updateRouteStatus(identifier, status);
    }

    function exposedPerformSwap(DexSwapCalldata memory data) external returns (bytes memory) {
        return performSwap(data);
    }
}
