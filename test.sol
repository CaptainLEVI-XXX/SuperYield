// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title Advanced Execution Engine
 * @notice Manages leveraged positions across multiple venues with automatic rate optimization
 */
contract AdvancedExecutionEngine {
    using SafeTransferLib for address;
    
    // ========== TYPES ==========
    
    struct VenueData {
        address lendingPool;
        uint256 supplyRate;
        uint256 borrowRate;
        uint256 availableLiquidity;
        uint256 maxLTV;
        bool isActive;
    }
    
    struct Position {
        address collateralAsset;
        address debtAsset;
        uint256 collateralAmount;
        uint256 debtAmount;
        address currentVenue;
        uint256 targetLTV;        // Target in basis points (7500 = 75%)
        uint256 ltvLowerBand;     // Lower band (7000 = 70%)
        uint256 ltvUpperBand;     // Upper band (8000 = 80%)
        uint256 lastRebalanceTime;
        bool isFixedRate;
        uint256 fixedRateExpiry;
    }
    
    struct FixedRateOpportunity {
        address protocol;     // Morpho V2, Term Finance
        uint256 fixedRate;
        uint256 duration;
        uint256 minAmount;
        uint256 maxAmount;
    }
    
    // ========== STATE ==========
    
    mapping(address => VenueData) public venues;
    mapping(bytes32 => Position) public positions;
    mapping(address => uint256) public reserves; // Asset => reserve amount
    
    uint256 public constant RESERVE_RATIO = 1000;  // 10% in basis points
    uint256 public constant MIN_HEALTH_FACTOR = 115e16; // 1.15
    uint256 public constant RATE_DIFF_THRESHOLD = 50; // 0.5% in basis points
    uint256 public constant REBALANCE_COOLDOWN = 1 hours;
    
    address public vault;
    address public keeper;
    address public flashloanAggregator; // Instadapp aggregator
    
    // Offchain computed values (updated by keeper)
    mapping(bytes32 => uint256) public offchainCarryMetrics;
    mapping(address => uint256) public offchainOptimalLTVs;
    
    // ========== EVENTS ==========
    
    event VenueSwitched(bytes32 indexed positionId, address from, address to, uint256 apr);
    event FixedRateAllocated(bytes32 indexed positionId, address protocol, uint256 rate, uint256 duration);
    event RebalanceExecuted(bytes32 indexed positionId, uint256 newLTV);
    event EmergencyDeleveraged(bytes32 indexed positionId, uint256 amount);
    
    // ========== CORE LOGIC ==========
    
    /**
     * @notice Deploy capital with automatic venue selection
     * @param collateralAsset Asset to use as collateral
     * @param amount Amount to deploy
     * @param debtAsset Asset to borrow
     * @param targetLeverage Target leverage (3e18 = 3x)
     */
    function deployCapital(
        address collateralAsset,
        uint256 amount,
        address debtAsset,
        uint256 targetLeverage
    ) external onlyVault {
        // 1. Calculate reserve allocation
        uint256 reserveAmount = (amount * RESERVE_RATIO) / 10000;
        uint256 deployAmount = amount - reserveAmount;
        
        // 2. Update reserves (keep in best yielding venue)
        _allocateReserve(collateralAsset, reserveAmount);
        
        // 3. Check fixed rate opportunities
        FixedRateOpportunity memory fixedOpp = _evaluateFixedRates(collateralAsset, debtAsset, deployAmount);
        
        if (_shouldUseFixedRate(fixedOpp, collateralAsset, debtAsset)) {
            _allocateToFixedRate(collateralAsset, deployAmount, fixedOpp);
        } else {
            // 4. Select best venue for floating rate
            address bestVenue = _selectOptimalVenue(collateralAsset, debtAsset, deployAmount);
            
            // 5. Create leveraged position
            _createLeveragedLoop(bestVenue, collateralAsset, deployAmount, debtAsset, targetLeverage);
        }
    }
    
    /**
     * @notice Rebalance positions based on rates and LTV
     * @dev Called by keeper with offchain computed metrics
     */
    function rebalancePositions(
        bytes32[] calldata positionIds,
        uint256[] calldata optimalLTVs,
        uint256[] calldata carryMetrics
    ) external onlyKeeper {
        for (uint256 i = 0; i < positionIds.length; i++) {
            Position storage pos = positions[positionIds[i]];
            
            // Skip if cooldown not met
            if (block.timestamp < pos.lastRebalanceTime + REBALANCE_COOLDOWN) continue;
            
            // Update offchain metrics
            offchainCarryMetrics[positionIds[i]] = carryMetrics[i];
            offchainOptimalLTVs[pos.collateralAsset] = optimalLTVs[i];
            
            // 1. Check if venue switch needed (better rates available)
            address newVenue = _shouldSwitchVenue(pos);
            if (newVenue != address(0) && newVenue != pos.currentVenue) {
                _switchVenue(positionIds[i], pos, newVenue);
            }
            
            // 2. Check if LTV adjustment needed
            uint256 currentLTV = _getCurrentLTV(pos);
            if (currentLTV > pos.ltvUpperBand) {
                _deleveragePosition(positionIds[i], pos, currentLTV);
            } else if (currentLTV < pos.ltvLowerBand) {
                _releveragePosition(positionIds[i], pos, currentLTV);
            }
            
            pos.lastRebalanceTime = block.timestamp;
        }
    }
    
    /**
     * @notice Switch position to better venue atomically
     */
    function _switchVenue(bytes32 positionId, Position storage pos, address newVenue) internal {
        // Use flashloan to switch venues atomically
        bytes memory params = abi.encode(
            positionId,
            pos.currentVenue,
            newVenue,
            pos.collateralAmount,
            pos.debtAmount
        );
        
        address[] memory assets = new address[](1);
        assets[0] = pos.debtAsset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = pos.debtAmount;
        
        IFlashLoanAggregator(flashloanAggregator).flashLoan(
            assets,
            amounts,
            0, // route automatically selected
            params
        );
        
        pos.currentVenue = newVenue;
        emit VenueSwitched(positionId, pos.currentVenue, newVenue, venues[newVenue].borrowRate);
    }
    
    /**
     * @notice Flashloan callback for venue switching
     */
    function executeOperation(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory premiums,
        address initiator,
        bytes memory params
    ) external returns (bool) {
        require(msg.sender == flashloanAggregator, "Unauthorized");
        
        (
            bytes32 positionId,
            address oldVenue,
            address newVenue,
            uint256 collateralAmount,
            uint256 debtAmount
        ) = abi.decode(params, (bytes32, address, address, uint256, uint256));
        
        // 1. Repay debt at old venue
        assets[0].safeApprove(oldVenue, amounts[0]);
        ILendingPool(oldVenue).repay(assets[0], amounts[0], 2, address(this));
        
        // 2. Withdraw collateral from old venue
        ILendingPool(oldVenue).withdraw(positions[positionId].collateralAsset, collateralAmount, address(this));
        
        // 3. Supply collateral to new venue
        positions[positionId].collateralAsset.safeApprove(newVenue, collateralAmount);
        ILendingPool(newVenue).supply(positions[positionId].collateralAsset, collateralAmount, address(this), 0);
        
        // 4. Borrow from new venue (debt + premium)
        ILendingPool(newVenue).borrow(assets[0], amounts[0] + premiums[0], 2, 0, address(this));
        
        // 5. Approve flashloan repayment
        assets[0].safeApprove(flashloanAggregator, amounts[0] + premiums[0]);
        
        return true;
    }
    
    /**
     * @notice Evaluate fixed rate opportunities
     */
    function _evaluateFixedRates(
        address collateral,
        address debt,
        uint256 amount
    ) internal view returns (FixedRateOpportunity memory best) {
        // Check Morpho V2 fixed rates
        uint256 morphoRate = IMorphoV2(MORPHO_V2).getFixedRate(collateral, debt);
        
        // Check Term Finance auction rates
        uint256 termRate = ITermFinance(TERM_FINANCE).getAuctionRate(collateral, debt);
        
        if (morphoRate > termRate) {
            best.protocol = MORPHO_V2;
            best.fixedRate = morphoRate;
            best.duration = 30 days;
        } else {
            best.protocol = TERM_FINANCE;
            best.fixedRate = termRate;
            best.duration = 28 days; // Term's standard
        }
        
        best.minAmount = 1000e18; // Example min
        best.maxAmount = amount;
    }
    
    /**
     * @notice Decide between fixed and floating rate
     */
    function _shouldUseFixedRate(
        FixedRateOpportunity memory opp,
        address collateral,
        address debt
    ) internal view returns (bool) {
        // Get best floating rate
        address bestVenue = _selectOptimalVenue(collateral, debt, opp.maxAmount);
        uint256 floatingNet = venues[bestVenue].supplyRate - venues[bestVenue].borrowRate;
        
        // Get carry metric from offchain computation
        bytes32 pairId = keccak256(abi.encodePacked(collateral, debt));
        uint256 carryAdjustment = offchainCarryMetrics[pairId];
        
        // Fixed is better if: fixedRate > floatingNet + carryAdjustment + 200bps
        return opp.fixedRate > floatingNet + carryAdjustment + 200;
    }
    
    /**
     * @notice Select optimal venue based on rates and liquidity
     */
    function _selectOptimalVenue(
        address collateral,
        address debt,
        uint256 amount
    ) internal view returns (address bestVenue) {
        uint256 bestScore = 0;
        
        address[3] memory venueList = [AAVE_V3, COMPOUND_V3, MORPHO_BLUE];
        
        for (uint256 i = 0; i < venueList.length; i++) {
            VenueData memory venue = venues[venueList[i]];
            if (!venue.isActive) continue;
            
            // Check liquidity
            if (venue.availableLiquidity < amount) continue;
            
            // Score = supplyRate - borrowRate (net carry)
            uint256 score = venue.supplyRate > venue.borrowRate ? 
                venue.supplyRate - venue.borrowRate : 0;
            
            if (score > bestScore) {
                bestScore = score;
                bestVenue = venueList[i];
            }
        }
        
        require(bestVenue != address(0), "No suitable venue");
    }
    
    /**
     * @notice Check if should switch to better venue
     */
    function _shouldSwitchVenue(Position memory pos) internal view returns (address) {
        VenueData memory current = venues[pos.currentVenue];
        address bestVenue = _selectOptimalVenue(pos.collateralAsset, pos.debtAsset, pos.collateralAmount);
        VenueData memory best = venues[bestVenue];
        
        // Switch if rate difference > threshold
        uint256 currentNet = current.supplyRate - current.borrowRate;
        uint256 bestNet = best.supplyRate - best.borrowRate;
        
        if (bestNet > currentNet + RATE_DIFF_THRESHOLD) {
            return bestVenue;
        }
        
        return address(0);
    }
    
    /**
     * @notice Emergency deleverage when approaching liquidation
     */
    function emergencyDeleverage(bytes32 positionId) external {
        Position storage pos = positions[positionId];
        uint256 healthFactor = _getHealthFactor(pos);
        
        require(healthFactor < MIN_HEALTH_FACTOR, "Not emergency");
        
        // Deleverage 30% immediately
        uint256 deleverageAmount = pos.debtAmount * 30 / 100;
        
        // Flash loan to repay debt
        bytes memory params = abi.encode(positionId, deleverageAmount, true);
        
        address[] memory assets = new address[](1);
        assets[0] = pos.debtAsset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = deleverageAmount;
        
        IFlashLoanAggregator(flashloanAggregator).flashLoan(
            assets,
            amounts,
            0,
            params
        );
        
        emit EmergencyDeleveraged(positionId, deleverageAmount);
    }
    
    /**
     * @notice Allocate reserves to best yielding venue
     */
    function _allocateReserve(address asset, uint256 amount) internal {
        address bestVenue = address(0);
        uint256 bestRate = 0;
        
        address[3] memory venueList = [AAVE_V3, COMPOUND_V3, MORPHO_BLUE];
        
        for (uint256 i = 0; i < venueList.length; i++) {
            if (venues[venueList[i]].supplyRate > bestRate) {
                bestRate = venues[venueList[i]].supplyRate;
                bestVenue = venueList[i];
            }
        }
        
        // Supply to best venue for yield
        asset.safeApprove(bestVenue, amount);
        ILendingPool(bestVenue).supply(asset, amount, address(this), 0);
        
        reserves[asset] += amount;
    }
    
    /**
     * @notice Compute optimal LTV band based on volatility (offchain helper)
     */
    function computeOptimalLTVBand(
        address collateral,
        address debt,
        uint256 volatility,
        uint256 correlation
    ) external pure returns (uint256 target, uint256 lower, uint256 upper) {
        // Target = 75% - (volatility * correlation factor)
        target = 7500 - (volatility * correlation / 100);
        lower = target - 500;  // 5% band
        upper = target + 500;
        
        // Safety caps
        if (upper > 8200) upper = 8200; // Max 82%
        if (lower < 6000) lower = 6000; // Min 60%
    }
    
    // ========== MODIFIERS ==========
    
    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }
    
    modifier onlyKeeper() {
        require(msg.sender == keeper, "Only keeper");
        _;
    }
}