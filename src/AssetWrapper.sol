// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {ISuperVault} from "./interfaces/ISuperVault.sol";
import {DexHelper} from "./abstract/DexHelper.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";

contract AssetVaultWrapper is Admin2Step, DexHelper {
    using SafeTransferLib for address;
    using CustomRevert for bytes4;

    error AssetVaultWrapper__UnexpectedWithdrawAmount();

    event LogRescueFunds(address indexed token, uint256 amount);

    ISuperVault internal immutable vault;
    address internal immutable asset;
    address internal immutable incomingAsset;

    constructor(address vault_, address owner_, address incomingAsset_) {
        vault = ISuperVault(vault_);
        asset = vault.asset();
        incomingAsset = incomingAsset_;

        // approve stETH to vault for deposits
        asset.safeApprove(vault_, type(uint256).max);

        _setAdmin(owner_);

        // Whitelist routes
        whitelistRoute("1INCH-V6-A", 0x111111125421cA6dc452d289314280a0f8842A65);
        whitelistRoute("PARASWAP-V6-A", 0x6A000F20005980200259B80c5102003040001068);
        whitelistRoute("ZEROX-V4-A", 0xDef1C0ded9bec7F1a1670819833240f027b25EfF);
        whitelistRoute("KYBER-AGGREGATOR-A", 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5);
    }

    function whitelistRoute(string memory name, address _router) public virtual override onlyAdmin returns (bytes32) {
        return super.whitelistRoute(name, _router);
    }

    function updateRouteStatus(bytes32[] calldata identifier, bool[] calldata status)
        public
        virtual
        override
        onlyAdmin
        returns (bool)
    {
        return super.updateRouteStatus(identifier, status);
    }

    function deposit(bytes32 route_, bytes calldata swapCalldata_, address receiver_, uint256 amount_)
        external
        returns (uint256 shares)
    {
        uint256 balanceBefore_ = asset.balanceOf(address(this));

        incomingAsset.safeTransferFrom(msg.sender, address(this), amount_);

        performSwap(DexSwapCalldata({swapCalldata: swapCalldata_, identifier: route_}));

        uint256 depositAmount_ = asset.balanceOf(address(this)) - balanceBefore_ - 1;

        // deposit output into vault for msg.sender as receiver
        shares = vault.deposit(depositAmount_, receiver_);
    }

    function mint(bytes32 route_, bytes calldata swapCalldata_, address receiver_, uint256 amount_)
        external
        returns (uint256 assets)
    {
        uint256 balanceBefore_ = asset.balanceOf(address(this));

        incomingAsset.safeTransferFrom(msg.sender, address(this), amount_);

        performSwap(DexSwapCalldata({swapCalldata: swapCalldata_, identifier: route_}));

        uint256 depositAmount_ = asset.balanceOf(address(this)) - balanceBefore_ - 1;
        // deposit output into vault for msg.sender as receiver
        assets = vault.mint(depositAmount_, receiver_);
    }

    function withdraw(bytes32 route_, uint256 amount_, bytes calldata swapCalldata_, address receiver_)
        external
        returns (uint256 tokenAmount)
    {
        uint256 balanceBefore = asset.balanceOf(address(this));

        vault.withdraw(amount_, address(this), msg.sender);

        uint256 vaultWithdrawnAmount = asset.balanceOf(address(this)) - balanceBefore;

        // -1 to account for potential rounding errors
        if (vaultWithdrawnAmount < amount_ - 1) AssetVaultWrapper__UnexpectedWithdrawAmount.selector.revertWith();

        // approve stETH
        asset.safeApprove(routeInfo().routes[route_].router, vaultWithdrawnAmount);

        performSwap(DexSwapCalldata({swapCalldata: swapCalldata_, identifier: route_}));

        tokenAmount = incomingAsset.balanceOf(address(this));

        // transfer eth to receiver (usually msg.sender)
        incomingAsset.safeTransfer(receiver_, tokenAmount);
    }

    function redeem(bytes32 route_, uint256 shares, bytes calldata swapCalldata_, address receiver_)
        external
        returns (uint256 tokenAmount)
    {
        uint256 balanceBefore = asset.balanceOf(address(this));

        vault.redeem(shares, address(this), msg.sender);

        uint256 vaultWithdrawnAmount = asset.balanceOf(address(this)) - balanceBefore;

        // -1 to account for potential rounding errors
        if (vaultWithdrawnAmount < shares - 1) AssetVaultWrapper__UnexpectedWithdrawAmount.selector.revertWith();

        // approve stETH
        asset.safeApprove(routeInfo().routes[route_].router, vaultWithdrawnAmount);

        performSwap(DexSwapCalldata({swapCalldata: swapCalldata_, identifier: route_}));

        tokenAmount = incomingAsset.balanceOf(address(this));

        // transfer eth to receiver (usually msg.sender)
        incomingAsset.safeTransfer(receiver_, tokenAmount);
    }

    /**
     * @dev Returns ethereum address
     */
    function getEthAddr() internal pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function rescueFunds(address[] memory _tokens) external returns (uint256[] memory) {
        uint256 _length = _tokens.length;
        uint256[] memory _rescueAmounts = new uint256[](_length);

        for (uint256 i = 0; i < _length; i++) {
            if (_tokens[i] == getEthAddr()) {
                _rescueAmounts[i] = address(this).balance;

                (bool sent,) = admin().call{value: _rescueAmounts[i]}("");
                require(sent, "Failed to send Ether");
            } else {
                _rescueAmounts[i] = _tokens[i].balanceOf(address(this));

                _tokens[i].safeTransfer(admin(), _rescueAmounts[i]);
            }

            emit LogRescueFunds(_tokens[i], _rescueAmounts[i]);
        }

        return _rescueAmounts;
    }

    receive() external payable {}
}
