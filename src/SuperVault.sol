// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {ERC4626} from "@solady/tokens/ERC4626.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {Pausable} from "./abstract/Pausable.sol";
abstract contract SuperVault is ERC4626,Admin2Step,Pausable {

    constructor(address _admin){
        _setAdmin(_admin);
    }

    

    function pause() public virtual override onlyAdmin{
    }

    function unpause() public virtual override onlyAdmin{
    }
    
}