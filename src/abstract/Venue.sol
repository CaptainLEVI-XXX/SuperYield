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

    struct VenueStorage {
        mapping(bytes32 => VenueInfo) venues;
    }
    // keccak256("superyield.venue.storage")
    bytes32 public constant VENUE_STORAGE_POSITION =0xa44cd558ff4abd55ee3c3c199924a9a5bd7c3b20a558e2a057c2f0cd990edde7;

    function _venueStorage() internal pure returns (VenueStorage storage venueStorage) {
        bytes32 position = VENUE_STORAGE_POSITION;
        assembly {
            venueStorage.slot := position
        }
    }

    function registerVenue(address router, uint8 identifier, address adapter) public virtual {
        bytes32 identifier_ = keccak256(abi.encodePacked(router));
        _venueStorage().venues[identifier_] =
            VenueInfo({router: router, active: true, id: identifier, adapter: IProtocolAdapter(adapter)});
    }

    function getVenueInfo(address router) public view returns (VenueInfo memory) {
        bytes32 identifier_ = keccak256(abi.encodePacked(router));
        return _venueStorage().venues[identifier_];
    }

    function setVenueStatus(bytes32 venueId, bool status) external virtual {
        _venueStorage().venues[venueId].active = status;
    }
}
