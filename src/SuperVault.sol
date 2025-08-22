// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC4626} from "@solady/tokens/ERC4626.sol";
import {Admin2Step} from "./abstract/Admin2Step.sol";
import {Pausable} from "./abstract/Pausable.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Lock} from "./libraries/Lock.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {Reserve} from "./libraries/Reserve.sol";
import {IExecutionEngine} from "./interfaces/IExecutionEngine.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";

contract SuperVault is ERC20, ERC4626, Admin2Step, Pausable {
    using CustomRevert for bytes4;
    using SafeTransferLib for address;
    using Reserve for uint256;

    error AsyncOnly();
    error ZeroAddress();
    error InsufficentLiquidity(uint256 amount);
    error InsufficientClaimableAssets(uint256 amount);
    error NotAuthorize();
    error ZeroShares();
    error VaultIsPaused();
    error ZeroAsset();
    error InsufficientShares(uint256 shares);
    error InvalidLength();
    error RequestAlreadyHandled(address user, uint256 requestId);
    error NotClaimable(address user, uint256 requestId);
    error OperationLocked();

    event WithdrawalRequested(address user, uint256 indexed requestId, uint256 shares);
    event WithdrawalProcessed(address user, uint256 indexed requestId, uint256 assets, uint256 ppsLocked);
    event WithdrawalClaimed(address user, uint256 id, uint256 assets);
    event CapitalDeployed(uint256 amount);
    event CapitalRecalled(uint256 amount);

    address public immutable executionEngine;

    struct VaultMetadata {
        address underlyingAsset;
        string name;
        string symbol;
    }

    VaultMetadata public vaultMetadata;

    struct VaultState {
        uint256 totalIdle;
        uint256 totalDeployed;
        uint64 lastUpdateTime;
    }

    VaultState public vaultState;

    // Async State
    uint256 public totalPendingShares;
    uint256 public totalClaimableAssets;

    // Per user Async State
    struct WithdrawalRequest {
        uint256 shares;
        uint256 assets;
        uint256 ppsLocked;
        uint64 requestTime;
        uint64 processTime;
        bool claimed;
        bool processed;
    }

    mapping(address => mapping(uint256 => WithdrawalRequest)) public withdrawalRequests;
    mapping(address => uint256) public nextRequestId;

    constructor(
        address _admin,
        address _executionEngine,
        address _underlyingAsset,
        string memory _name,
        string memory _symbol
    ) {
        if (_admin == address(0) || _executionEngine == address(0)) ZeroAddress.selector.revertWith();
        _setAdmin(_admin);
        executionEngine = _executionEngine;
        vaultMetadata = VaultMetadata(_underlyingAsset, _name, _symbol);
    }

    modifier notPaused() {
        if (isPaused()) VaultIsPaused.selector.revertWith();
        _;
    }

    /// @notice Locks the function execution to prevent reentrancy attacks
    /// 80% more gas-efficient than normal reentrancy guard(sload)
    modifier lockUnlock() {
        if (!Lock.isUnlocked()) OperationLocked.selector.revertWith();
        Lock.lock();
        _;
        Lock.unlock();
    }

    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        lockUnlock
        notPaused
        returns (uint256 shares)
    {
        if (assets == 0) ZeroAsset.selector.revertWith();
        if (receiver == address(0)) ZeroAddress.selector.revertWith();

        shares = previewDeposit(assets);

        vaultState.totalIdle += assets;
        vaultState.lastUpdateTime = uint64(block.timestamp);

        _deposit(msg.sender, receiver, assets, shares);

        //_deposit() already Emits Deposit event
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        lockUnlock
        notPaused
        returns (uint256 assets)
    {
        if (shares == 0) ZeroShares.selector.revertWith();
        if (receiver == address(0)) ZeroAddress.selector.revertWith();

        assets = previewMint(shares);

        vaultState.totalIdle += assets;
        vaultState.lastUpdateTime = uint64(block.timestamp);

        _deposit(msg.sender, receiver, assets, shares);

        //_deposit() already Emits Deposit event
    }

    // Instant Withdrawal path (from Reserves)
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        lockUnlock
        notPaused
        returns (uint256 shares)
    {
        if (assets == 0) ZeroAsset.selector.revertWith();
        if (receiver == address(0) || owner == address(0)) ZeroAddress.selector.revertWith();
        /// @notice check whether the required assets are available in reserves

        shares = previewWithdraw(assets);

        vaultState.totalIdle -= assets;
        vaultState.lastUpdateTime = uint64(block.timestamp);

        // Try instant from reserves (idle)
        // _ensureInstantLiquidity(assets);

        _withdraw(msg.sender, receiver, owner, assets, shares);

        //_withdraw() already Emits Withdraw event
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        lockUnlock
        notPaused
        returns (uint256 assets)
    {
        if (shares == 0) ZeroShares.selector.revertWith();
        if (receiver == address(0) || owner == address(0)) ZeroAddress.selector.revertWith();
        /// @notice check whether the required assets are available in reserves

        assets = previewRedeem(shares);

        vaultState.totalIdle -= assets;
        vaultState.lastUpdateTime = uint64(block.timestamp);

        // Try instant from reserves (idle)
        // _ensureInstantLiquidity(assets);

        _withdraw(msg.sender, receiver, owner, assets, shares);

        //_withdraw() already Emits Withdraw event
    }

    //Async withdrawal Path
    function requestWithdrawal(uint256 shares) external lockUnlock notPaused returns (uint256 requestId) {
        if (shares == 0) ZeroShares.selector.revertWith();

        uint256 balance = balanceOf(msg.sender);
        if (balance < shares) InsufficientShares.selector.revertWith(balance);

        //Lock shares by moving them to the vault
        _transfer(msg.sender, address(this), shares);

        requestId = nextRequestId[msg.sender];

        unchecked {
            nextRequestId[msg.sender]++;
        }

        withdrawalRequests[msg.sender][requestId] = WithdrawalRequest({
            shares: shares,
            assets: 0,
            ppsLocked: getPricePerShare(),
            requestTime: uint64(block.timestamp),
            processTime: 0,
            claimed: false,
            processed: false
        });

        totalPendingShares += shares;

        emit WithdrawalRequested(msg.sender, requestId, shares);
    }

    function processWithdrawals(address[] calldata users, uint256[] calldata requestIds) external onlyAdmin {
        if (users.length != requestIds.length) InvalidLength.selector.revertWith();

        uint256 totalAssetNeeded;
        // First Pass: Compute the total assets needed for the batch
        /// @notice we could process it in 2 pass: for first we could calculate the total assets needed and then in
        //       second pass we could move the shares to claimable But that would be inefficient , if transactions is reverted in
        // any stage EVM will revert all the changes made in the transaction.
        for (uint256 i = 0; i < users.length; i++) {
            WithdrawalRequest storage request = withdrawalRequests[users[i]][requestIds[i]];
            if (request.processed && request.claimed) {
                RequestAlreadyHandled.selector.revertWith(requestIds[i], users[i]);
            }
            uint256 assetForReq = request.shares * request.ppsLocked / 1e18;
            request.assets = assetForReq;
            request.processed = true;
            request.processTime = uint64(block.timestamp);
            unchecked {
                totalAssetNeeded += assetForReq;
                totalPendingShares -= request.shares;
                totalClaimableAssets += assetForReq;
            }

            emit WithdrawalProcessed(users[i], requestIds[i], assetForReq, request.ppsLocked);
        }
        //Insure Liquidity is available for the whole batch
        _ensureIdle(totalAssetNeeded);
    }

    function claimWithdrawal(uint256 requestId, address receiver)
        external
        lockUnlock
        notPaused
        returns (uint256 assets)
    {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender][requestId];
        if (!request.processed || request.claimed) NotClaimable.selector.revertWith(requestId, msg.sender);
        if (request.assets > vaultState.totalIdle) InsufficentLiquidity.selector.revertWith(requestId);
        assets = request.assets;
        request.claimed = true;
        unchecked {
            vaultState.totalIdle -= assets;
            totalClaimableAssets -= assets;
        }
        _withdraw(msg.sender, receiver, msg.sender, assets, request.shares);
        emit WithdrawalClaimed(msg.sender, requestId, assets);
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 totalDeployed = vaultState.totalDeployed;
        uint256 gross = vaultState.totalIdle + totalDeployed;

        // Exclude Claimable Assets: Already Marked to Leave the vault
        if (gross > totalClaimableAssets) {
            return gross - totalClaimableAssets;
        }

        /// @notice will gross always be greater than totalClaimableAssets
        return 0;
    }

    function getPricePerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 1e18;
        }
        return (totalAssets() * 1e18) / supply;
    }

    function _reserveTarget() internal view returns (uint256) {
        return totalAssets().calculateReserveAmount();
    }

    // ensure the vault has enough funds idle full from engine if needed
    function _ensureIdle(uint256 assets) internal {
        uint256 reserveTarget = _reserveTarget();

        uint256 requiredIdle = reserveTarget + assets;
        if (requiredIdle > totalAssets()) {
            uint256 shortfall = requiredIdle - vaultState.totalIdle;

            /// @notice pull the funds back from the Engine

            unchecked {
                vaultState.totalIdle += shortfall;
                vaultState.totalDeployed -= shortfall;
            }
        }
    }

    function provideFundsToEngine(uint256 amount) external {
        if (msg.sender != executionEngine || msg.sender != admin()) NotAuthorize.selector.revertWith();
        uint256 reserveTarget = _reserveTarget();
        uint256 idle = vaultState.totalIdle;

        if (amount > idle || idle - amount < reserveTarget) InsufficentLiquidity.selector.revertWith();

        unchecked {
            vaultState.totalIdle -= amount;
            vaultState.totalDeployed += amount;
        }

        asset().safeApprove(executionEngine, amount);
        IExecutionEngine(executionEngine).deployCapital(amount);

        emit CapitalDeployed(amount);
    }

    function recallFromEngine(uint256 amount) external onlyAdmin lockUnlock notPaused returns (uint256 recalled) {
        recalled = _recallFromEngine(amount);
    }

    function _recallFromEngine(uint256 amount) internal returns (uint256 recalled) {
        recalled = IExecutionEngine(executionEngine).recallCapital(amount);
        if (recalled != 0) {
            vaultState.totalIdle += recalled;
            vaultState.totalDeployed = recalled > vaultState.totalDeployed ? 0 : (vaultState.totalDeployed - recalled);
            emit CapitalRecalled(recalled);
        }
    }

    function pause() public virtual override onlyAdmin {
        super.pause();
    }

    function unpause() public virtual override onlyAdmin {
        super.unpause();
    }

    function name() public view virtual override(ERC20) returns (string memory) {
        return vaultMetadata.name;
    }

    function symbol() public view virtual override(ERC20) returns (string memory) {
        return vaultMetadata.symbol;
    }

    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return IERC20Metadata(vaultMetadata.underlyingAsset).decimals();
    }

    function asset() public view virtual override returns (address) {
        return vaultMetadata.underlyingAsset;
    }
}
