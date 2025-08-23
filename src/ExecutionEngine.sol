// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {DexHelper} from "./abstract/DexHelper.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {Initializable} from "@solady/utils/Initializable.sol";

contract ExecutionEngine is DexHelper, Admin2Step, UUPSUpgradeable, Initializable {
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) public initializer {
        _setAdmin(owner);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
