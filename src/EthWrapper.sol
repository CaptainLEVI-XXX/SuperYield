// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.13;

// import {Address} from "@solady/utils/Address.sol";
// // import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
// // import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
// import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// interface IUserModule is IERC20Upgradeable {
//     function deposit(
//         uint256 assets_,
//         address receiver_
//     ) external returns (uint256 shares_);

//     function withdraw(
//         uint256 assets_,
//         address receiver_,
//         address owner_
//     ) external returns (uint256 shares_);
// }

// contract Events {
//     event LogUpdateWhitelist(
//         string indexed name,
//         address whitelistedRouter,
//         address whitelistedApproval,
//         bool indexed status
//     );

//     event LogUpdateWhitelistStatus(string indexed name, bool indexed status);

//     event LogRescueFunds(address indexed token, uint256 indexed amount);
// }

// contract ConstantVariables {
//     struct RouterHelper {
//         address router;
//         address approval;
//         bool status;
//     }

//     IERC20Upgradeable internal constant STETH =
//         IERC20Upgradeable(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

//     /// @notice Rescue funds will be transfered to this address upon collection.
//     address public constant RESCUE_TRANSFERS =
//         0x4F6F977aCDD1177DCD81aB83074855EcB9C2D49e;
// }

// contract EthVaultWrapperV2 is Ownable, Events, ConstantVariables {
//     using SafeERC20Upgradeable for IERC20Upgradeable;

//     error EthVaultWrapper__OutputInsufficient();
//     error EthVaultWrapper__UnexpectedWithdrawAmount();
//     error EthVaultWrapper__InvalidInput();
//     error EthVaultWrapper__OnlyWhitelisted();

//     /***********************************|
//     |           STATE VARIABLES         |
//     |__________________________________*/

//     IUserModule internal immutable vault;

//     /// @notice mapping to store allowed route names to their
//     ///         whitelisted router, approval address and status.
//     mapping(string => RouterHelper) public whitelistedRoutes;

//     constructor(address vault_, address owner_) {
//         vault = IUserModule(vault_);

//         // approve stETH to vault for deposits
//         STETH.approve(vault_, type(uint256).max);

//         _transferOwnership(owner_);

//         // Whitelist routes
//         whitelistingConstructorHelper(
//             "1INCH-V6-A",
//             0x111111125421cA6dc452d289314280a0f8842A65
//         );
//         whitelistingConstructorHelper(
//             "PARASWAP-V6-A",
//             0x6A000F20005980200259B80c5102003040001068
//         );
//         whitelistingConstructorHelper(
//             "ZEROX-V4-A",
//             0xDef1C0ded9bec7F1a1670819833240f027b25EfF
//         );
//         whitelistingConstructorHelper(
//             "KYBER-AGGREGATOR-A",
//             0x6131B5fae19EA4f9D964eAc0408E4408b66337b5
//         );
//     }

//     function whitelistingConstructorHelper(
//         string memory name,
//         address routerAddress
//     ) internal {
//         whitelistedRoutes[name] = RouterHelper({
//             router: routerAddress,
//             approval: routerAddress,
//             status: true
//         });

//         emit LogUpdateWhitelist(name, routerAddress, routerAddress, true);
//     }

//     /// @notice Update whitelisted name, routers, approval
//     ///         addresses and their status.
//     function updateWhitelist(
//         string[] memory name_,
//         address[] memory routers_,
//         address[] memory approvals_,
//         bool[] memory status_
//     ) public onlyOwner {
//         uint256 length_ = name_.length;

//         if (
//             (length_ != routers_.length) ||
//             (length_ != approvals_.length) ||
//             (length_ != status_.length)
//         ) {
//             revert EthVaultWrapper__InvalidInput();
//         }

//         for (uint256 i = 0; i < length_; i++) {
//             whitelistedRoutes[name_[i]] = RouterHelper({
//                 router: routers_[i],
//                 approval: approvals_[i],
//                 status: status_[i]
//             });

//             emit LogUpdateWhitelist(
//                 name_[i],
//                 routers_[i],
//                 approvals_[i],
//                 status_[i]
//             );
//         }
//     }

//     /// @notice Update status of routes.
//     function updateWhitelistStatus(
//         string[] memory name_,
//         bool[] memory status_
//     ) public onlyOwner {
//         uint256 length_ = name_.length;

//         if (length_ != status_.length) {
//             revert EthVaultWrapper__InvalidInput();
//         }

//         for (uint256 i = 0; i < length_; i++) {
//             RouterHelper storage helperStorage = whitelistedRoutes[name_[i]];

//             helperStorage.status = status_[i];

//             emit LogUpdateWhitelistStatus(name_[i], status_[i]);
//         }
//     }

//     /// @notice deposits msg.value as stETH into ETH vault. returns shares amount
//     /// @param route_ Route string through which swap will go, e.g. "1INCH-A"
//     /// @param swapCalldata_ swap data for ETH -> stETH to call AggregationRouter with
//     /// @param minStEthIn_ minimum expected stETH to be deposited
//     /// @param receiver_ receiver of iToken shares from deposit
//     /// @return actual amount of shares received
//     function deposit(
//         string calldata route_,
//         bytes calldata swapCalldata_,
//         uint256 minStEthIn_,
//         address receiver_
//     ) external payable returns (uint256) {
//         RouterHelper memory helper_ = whitelistedRoutes[route_];

//         if (!helper_.status) {
//             revert EthVaultWrapper__OnlyWhitelisted();
//         }

//         uint256 balanceBefore_ = STETH.balanceOf(address(this));

//         // swap msg.value to stETH via 1inch
//         Address.functionCallWithValue(
//             helper_.router,
//             swapCalldata_,
//             msg.value,
//             "EthVaultWrapper: swap fail"
//         );

//         uint256 depositAmount_ = STETH.balanceOf(address(this)) - balanceBefore_ - 1;

//         // ensure expected minimum output
//         if (depositAmount_ < minStEthIn_) {
//             revert EthVaultWrapper__OutputInsufficient();
//         }

//         // deposit output into vault for msg.sender as receiver
//         return vault.deposit(depositAmount_, receiver_);
//     }

//     /// @notice withdraws amount_ of stETH from msg.sender as owner and swaps it to ETH then transfers to msg.sender
//     /// @param route_ Route string through which swap will go, e.g. "1INCH-A"
//     /// @param amount_ amount of stETH to withdraw
//     /// @param swapCalldata_ swap data for stETH -> ETH to call AggregationRouter with
//     /// @param minEthOut_ minimum expected output ETH
//     /// @param receiver_ receiver of withdrawn ETH
//     /// @return ethAmount_ actual output ETH
//     function withdraw(
//         string calldata route_,
//         uint256 amount_,
//         bytes calldata swapCalldata_,
//         uint256 minEthOut_,
//         address receiver_
//     ) external returns (uint256 ethAmount_) {
//         RouterHelper memory helper_ = whitelistedRoutes[route_];

//         if (!helper_.status) {
//             revert EthVaultWrapper__OnlyWhitelisted();
//         }

//         uint256 stEthBalanceBefore = STETH.balanceOf(address(this));
//         uint256 withdrawFee = vault.getWithdrawFee(amount_);
//         // withdraw amount from vault with msg.sender as owner & this contract as receiver
//         // withdrawn amount = amount - fee
//         vault.withdraw(amount_, address(this), msg.sender);

//         uint256 vaultWithdrawnAmount =
//             STETH.balanceOf(address(this)) - stEthBalanceBefore;

//         // -1 to account for potential rounding errors
//         if (vaultWithdrawnAmount + withdrawFee < amount_ - 1) {
//             revert EthVaultWrapper__UnexpectedWithdrawAmount();
//         }

//         // approve stETH
//         STETH.approve(helper_.approval, vaultWithdrawnAmount);

//         // swap stETH to ETH
//         Address.functionCall(
//             helper_.router,
//             swapCalldata_,
//             "EthVaultWrapper: swap fail"
//         );

//         ethAmount_ = address(this).balance;

//         // ensure expected minimum output
//         if (ethAmount_ < minEthOut_) {
//             revert EthVaultWrapper__OutputInsufficient();
//         }

//         // transfer eth to receiver (usually msg.sender)
//         payable(receiver_).transfer(ethAmount_);
//     }

//     /**
//      *@dev Returns ethereum address
//      */
//     function getEthAddr() internal pure returns (address) {
//         return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
//     }

//     function rescueFunds(
//         address[] memory _tokens
//     ) external returns (uint256[] memory) {
//         uint256 _length = _tokens.length;
//         uint256[] memory _rescueAmounts = new uint256[](_length);

//         for (uint256 i = 0; i < _length; i++) {
//             if (_tokens[i] == getEthAddr()) {
//                 _rescueAmounts[i] = address(this).balance;

//                 (bool sent, ) = RESCUE_TRANSFERS.call{value: _rescueAmounts[i]}("");
//                 require(sent, "Failed to send Ether");
//             } else {
//                 _rescueAmounts[i] = IERC20Upgradeable(_tokens[i]).balanceOf(
//                     address(this)
//                 );

//                 IERC20Upgradeable(_tokens[i]).safeTransfer(
//                     RESCUE_TRANSFERS,
//                     _rescueAmounts[i]
//                 );
//             }

//             emit LogRescueFunds(_tokens[i], _rescueAmounts[i]);
//         }

//         return _rescueAmounts;
//     }

//     receive() external payable {}
// }
