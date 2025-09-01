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

    error ZeroAddress();
    error InsufficientLiquidity();
    error NotAuthorized();
    error ZeroShares();
    error VaultIsPaused();
    error ZeroAsset();
    error InsufficientShares(uint256 shares);
    error InvalidLength();
    error RequestAlreadyHandled(address user, uint256 requestId);
    error NotClaimable();
    error OperationLocked();
    error RecallFailed(uint256 requested, uint256 actual);

    event WithdrawalRequested(address user, uint256 indexed requestId, uint256 shares);
    event WithdrawalProcessed(address user, uint256 indexed requestId, uint256 assets, uint256 ppsLocked);
    event WithdrawalClaimed(address user, uint256 id, uint256 assets, address receiver);
    event CapitalDeployed(uint256 amount);
    event CapitalRecalled(uint256 amount);

    address public immutable executionEngine;

    struct VaultMetadata {
        address underlyingAsset;
        string name;
        string symbol;
    }

    VaultMetadata public vaultMetadata;

    // Async State - only variables we actually need
    uint256 public totalPendingShares;
    uint256 public totalClaimableAssets;

    int256 public totalDeployedToEngine;

    enum WithdrawalStatus {
        PENDING,
        PROCESSED,
        CLAIMED
    }

    struct WithdrawalRequest {
        uint256 shares;
        uint256 assets;
        uint256 ppsLocked;
        uint64 requestTime;
        uint64 processTime;
        WithdrawalStatus status;
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
        if (Lock.isUnlocked()) OperationLocked.selector.revertWith();
        Lock.unlock();
        _;
        Lock.lock();
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
        _deposit(msg.sender, receiver, assets, shares);
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
        _deposit(msg.sender, receiver, assets, shares);
    }

    // Instant Withdrawal path (from available idle funds)
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

        // Check if we have enough idle funds for instant withdrawal
        uint256 availableIdle = _getAvailableIdle();
        if (availableIdle < assets) {
            InsufficientLiquidity.selector.revertWith();
        }

        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
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

        assets = previewRedeem(shares);

        // Check if we have enough idle funds for instant redemption
        uint256 availableIdle = _getAvailableIdle();
        if (availableIdle < assets) {
            InsufficientLiquidity.selector.revertWith();
        }

        _withdraw(msg.sender, receiver, owner, assets, shares);
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
            status: WithdrawalStatus.PENDING
        });

        totalPendingShares += shares;

        emit WithdrawalRequested(msg.sender, requestId, shares);
    }

    function processWithdrawals(address[] calldata users, uint256[] calldata requestIds) external onlyAdmin {
        if (users.length != requestIds.length) InvalidLength.selector.revertWith();

        uint256 totalAssetNeeded;

        // Process each withdrawal request
        for (uint256 i = 0; i < users.length;) {
            WithdrawalRequest storage request = withdrawalRequests[users[i]][requestIds[i]];
            if (request.status != WithdrawalStatus.PENDING) {
                revert();
            }

            // Use rounding up to avoid precision loss
            uint256 assetForReq = (request.shares * request.ppsLocked + 1e18 - 1) / 1e18;

            request.assets = assetForReq;
            request.status = WithdrawalStatus.PROCESSED;
            request.processTime = uint64(block.timestamp);

            unchecked {
                totalAssetNeeded += assetForReq;
                totalPendingShares -= request.shares;
                totalClaimableAssets += assetForReq;
                i += 1;
            }

            emit WithdrawalProcessed(users[i], requestIds[i], assetForReq, request.ppsLocked);
        }

        // Ensure we have enough idle funds for the whole batch
        _ensureIdle(totalAssetNeeded);
    }

    function claimWithdrawal(uint256 requestId, address receiver)
        external
        lockUnlock
        notPaused
        returns (uint256 assets)
    {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender][requestId];
        if (request.status != WithdrawalStatus.PROCESSED) NotClaimable.selector.revertWith();

        uint256 currentIdle = asset().balanceOf(address(this));
        if (currentIdle < request.assets) InsufficientLiquidity.selector.revertWith();

        assets = request.assets;
        request.status = WithdrawalStatus.CLAIMED;

        unchecked {
            totalClaimableAssets -= assets;
        }

        // Burn the locked shares and transfer assets
        _burn(address(this), request.shares);
        asset().safeTransfer(receiver, assets);

        emit WithdrawalClaimed(msg.sender, requestId, assets, receiver);
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 idleBalance = asset().balanceOf(address(this));

        try IExecutionEngine(executionEngine).getDeployedValue(address(this)) returns (uint256 deployedValue) {
            uint256 gross = idleBalance + deployedValue;
            return gross > totalClaimableAssets ? gross - totalClaimableAssets : 0;
        } catch {
            // Fallback if execution engine fails
            return idleBalance > totalClaimableAssets ? (idleBalance - totalClaimableAssets) : 0;
        }
    }

    function getPricePerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 1e18;
        }
        return (totalAssets() * 1e18) / supply;
    }

    function _getAvailableIdle() internal view returns (uint256) {
        uint256 balance = asset().balanceOf(address(this));
        return balance > totalClaimableAssets ? balance - totalClaimableAssets : 0;
    }

    function _reserveTarget() internal view returns (uint256) {
        return totalAssets().calculateReserveAmount();
    }

    // Ensure the vault has enough idle funds, recall from engine if needed
    function _ensureIdle(uint256 assets) internal {
        uint256 currentIdle = _getAvailableIdle();

        if (currentIdle < assets) {
            uint256 shortfall;
            unchecked {
                shortfall = assets - currentIdle;
            }
            _recallFromEngine(shortfall);
        }
    }

    function provideFundsToEngine(uint256 amount) external {
        if (msg.sender != executionEngine && msg.sender != admin()) NotAuthorized.selector.revertWith();
        _provideFundsToEngine(amount);
    }

    function _provideFundsToEngine(uint256 amount) internal {
        uint256 reserveTarget = _reserveTarget();
        uint256 availableIdle = _getAvailableIdle();

        if (amount > availableIdle || availableIdle - amount < reserveTarget) {
            InsufficientLiquidity.selector.revertWith();
        }

        asset().safeTransfer(executionEngine, amount);
        unchecked {
            totalDeployedToEngine += int256(amount);
        }

        emit CapitalDeployed(amount);
    }

    function recallFromEngine(uint256 amount) external onlyAdmin lockUnlock notPaused returns (uint256 recalled) {
        recalled = _recallFromEngine(amount);
    }

    function _recallFromEngine(uint256 amount) internal returns (uint256 recalled) {
        recalled = IExecutionEngine(executionEngine).recallCapital(amount);

        if (recalled != amount) {
            RecallFailed.selector.revertWith();
        }
        unchecked {
            totalDeployedToEngine -= int256(recalled);
        }

        emit CapitalRecalled(recalled);
        return recalled;
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

    receive() external payable {
        OperationLocked.selector.revertWith();
    }
}
