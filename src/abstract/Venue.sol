// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract Venue {
    struct VenueInfo {
        address router;
        bool active;
        uint8 id;
    }
    // venue info

    mapping(bytes32 => VenueInfo) public venues;

    function registerVenue(address router, uint8 identifier) public virtual {
        bytes32 identifier_ = keccak256(abi.encodePacked(router));
        venues[identifier_] = VenueInfo({router: router, active: true, id: identifier});
    }

    function getVenueInfo(address router) public view returns (VenueInfo memory) {
        bytes32 identifier_ = keccak256(abi.encodePacked(router));
        return venues[identifier_];
    }

    function setVenueStatus(bytes32 venueId, bool status) external virtual {
        venues[venueId].active = status;
    }
}
