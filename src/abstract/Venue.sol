// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract Venue{

    struct VenueInfo {
        address router;
        bool active;
        uint8 id;
    }
    // venue info
    mapping(bytes32 => VenueInfo) public venues;

    function registerVenue(bytes32 venueId, address router,uint8 identifier) public virtual {
        venues[venueId] = VenueInfo({router: router, active: true, id: identifier});
    }

    function setVenueStatus(bytes32 venueId, bool status) external virtual {
        venues[venueId].active = status;
    }
    
}
