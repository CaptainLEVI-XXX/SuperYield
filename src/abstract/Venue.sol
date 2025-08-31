// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";

abstract contract Venue {
    struct VenueInfo {
        IProtocolAdapter adapter;
        address router;
        bool active;
        uint8 id;
    }
    // venue info

    mapping(bytes32 => VenueInfo) public venues;

    function registerVenue(address router, uint8 identifier, address adapter) public virtual {
        bytes32 identifier_ = keccak256(abi.encodePacked(router));
        venues[identifier_] =
            VenueInfo({router: router, active: true, id: identifier, adapter: IProtocolAdapter(adapter)});
    }

    function getVenueInfo(address router) public view returns (VenueInfo memory) {
        bytes32 identifier_ = keccak256(abi.encodePacked(router));
        return venues[identifier_];
    }

    function setVenueStatus(bytes32 venueId, bool status) external virtual {
        venues[venueId].active = status;
    }
}
