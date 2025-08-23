// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LibCall} from "@solady/utils/LibCall.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";

abstract contract DexHelper {
    using LibCall for address;
    using CustomRevert for bytes4;

    error DexHelper__InvalidInput();
    error DexHelper__RouteNotWhitelisted();

    event LogUpdateWhitelist(
        string indexed name, address whitelistedRouter, address whitelistedApproval, bool indexed status
    );
    event LogRouteSet(bytes32 indexed identifier);

    struct RouteInfo {
        address router;
        bool status;
        string name;
    }

    struct RouteStorage {
        mapping(bytes32 => RouteInfo) routes;
    }

    struct DexSwapCalldata {
        bytes swapCalldata;
        bytes32 identifier;
    }

    bytes32 public constant ROUTE_STORAGE = keccak256("super.dex.route.storage");

    function routeInfo() internal pure returns (RouteStorage storage _routeStorage) {
        bytes32 position = ROUTE_STORAGE;
        assembly {
            _routeStorage.slot := position
        }
    }

    function whitelistRoute(string calldata name, address _router) public virtual returns (bytes32) {
        bytes32 identifier = keccak256(abi.encodePacked(name, _router));
        routeInfo().routes[identifier] = RouteInfo({router: _router, status: true, name: name});
        emit LogRouteSet(identifier);
        return identifier;
    }

    function updateRouteStatus(bytes32[] memory identifier, bool[] memory status) public virtual returns (bool) {
        uint256 length_ = identifier.length;

        if ((length_ != status.length)) {
            revert DexHelper__InvalidInput();
        }

        for (uint256 i = 0; i < length_; i++) {
            RouteInfo storage routeInfo_ = routeInfo().routes[identifier[i]];
            routeInfo_.status = status[i];
            emit LogUpdateWhitelist(routeInfo_.name, routeInfo_.router, routeInfo_.router, status[i]);
        }
        return true;
    }

    function getRouteIdentifier(string calldata name, address _router) public pure returns (bytes32) {
        bytes32 identifier = keccak256(abi.encodePacked(name, _router));
        return identifier;
    }

    function performSwap(DexSwapCalldata memory swapCalldata) public virtual returns (bytes memory result) {
        RouteInfo memory routeInfo_ = routeInfo().routes[swapCalldata.identifier];
        if (!routeInfo_.status) DexHelper__RouteNotWhitelisted.selector.revertWith();
        address router = routeInfo_.router;
        result = router.callContract(swapCalldata.swapCalldata);
    }

    function performSwapWithValue(DexSwapCalldata memory swapCalldata, uint256 value)
        public
        virtual
        returns (bytes memory result)
    {
        RouteInfo memory routeInfo_ = routeInfo().routes[swapCalldata.identifier];
        if (!routeInfo_.status) DexHelper__RouteNotWhitelisted.selector.revertWith();
        address router = routeInfo_.router;
        result = router.callContract(value, swapCalldata.swapCalldata);
    }
}
