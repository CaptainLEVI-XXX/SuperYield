// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {ISuperVault} from "./interfaces/ISuperVault.sol";
import {DexHelper} from "./abstract/DexHelper.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {LibCall} from "@solady/utils/LibCall.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract EthVaultWrapper is Admin2Step, DexHelper {
    using SafeTransferLib for address;
    using CustomRevert for bytes4;
    using LibCall for address;

    error EthVaultWrapper__UnexpectedWithdrawAmount();

    event LogRescueFunds(address indexed token, uint256 amount);

    ISuperVault internal immutable vault;
    address internal immutable asset;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    constructor(address vault_, address owner_) {
        vault = ISuperVault(vault_);
        asset = vault.asset();

        // approve stETH to vault for deposits
        asset.safeApprove(vault_, type(uint256).max);

        _setAdmin(owner_);
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

    function deposit(DexSwapCalldata memory swapCalldata, address receiver_)
        external
        payable
        returns (uint256 shares)
    {
        uint256 balanceBefore = asset.balanceOf(address(this));

        WETH.call{value: msg.value}("");

        WETH.safeApprove(getDexRouter(swapCalldata.identifier), msg.value);

        performSwap(swapCalldata);

        uint256 depositAmount_ = asset.balanceOf(address(this)) - balanceBefore;

        // deposit output into vault for msg.sender as receiver
        shares = vault.deposit(depositAmount_, receiver_);
    }

    function withdraw(DexSwapCalldata memory swapCalldata_, uint256 amount_, address receiver_)
        external
        returns (uint256 ethAmount_)
    {
        uint256 balanceBefore = asset.balanceOf(address(this));

        vault.withdraw(amount_, address(this), msg.sender);

        uint256 vaultWithdrawnAmount = asset.balanceOf(address(this)) - balanceBefore;

        // -1 to account for potential rounding errors
        if (vaultWithdrawnAmount < amount_ - 1) {
            revert EthVaultWrapper__UnexpectedWithdrawAmount();
        }

        // approve stETH
        asset.safeApprove(getDexRouter(swapCalldata_.identifier), vaultWithdrawnAmount);

        performSwap(swapCalldata_);

        IWETH(WETH).withdraw(WETH.balanceOf(address(this)));

        ethAmount_ = address(this).balance;

        // transfer eth to receiver (usually msg.sender)
        payable(receiver_).transfer(ethAmount_);
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
