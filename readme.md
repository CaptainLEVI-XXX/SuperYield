# SuperYield Loop Vault - Technical Documentation

> **Note**: These contracts are prototypes built for just as an prototype.Chances are there for any bugs preferably to access control or some logic errors.


![SuperYield Architecture](src/image/superyield.png)


---

## Architecture Design

### Core Design Philosophy

**Hybrid Approach**: Partially monolithic ExecutionEngine with modular adapters

- **Benefits**: $20-50 gas savings per transaction, atomic operations, reduced complexity
- **Tradeoff**: Less modularity in core components for significant UX improvement

### How It Compares to InstaDapp Lite

#### InstaDapp Lite Architecture:
- Single monolithic contract with ERC4626 + leverage logic
- Customized for specific strategies (e.g., wstETH/ETH)
- Gas-optimized but less flexible
- Not open-source (analyzed via Etherscan transactions)

#### SuperYield Architecture:
- Three main components with clear separation of concerns
- Supports multiple protocols and strategies
- Modular adapters for protocol integration
- Open and extensible design

---

## Core Contracts & Features

### 1. SuperVault (ERC4626 Vault)
**File**: `src/SuperVault.sol`

#### Main Features:
- ERC4626 compliant with async withdrawal queue system
- Reserve management (10% kept idle for instant withdrawals)
- Batched withdrawal processing for gas efficiency
- Integration with ExecutionEngine for capital deployment

#### Key Components:
- Instant withdrawals from reserves
- Queued withdrawals with batch processing
- Price per share (PPS) tracking with NAV calculation
- Emergency pause functionality
- Reentrancy protection using transient storage

### 2. StrategyManager (ExecutionEngine)
**File**: `src/engine/ExecutionEngine.sol`

#### Main Features:
- Flash loan-based leveraged position management
- Multi-venue support (Aave, Compound, Morpho)
- Position migration and rebalancing between protocols
- Integration with pre-liquidation system

#### Key Components:
- Position opening/closing with InstaDapp flash loans
- Venue migration for rate optimization
- Gas-optimized rebalancing operations
- Universal lending protocol integration

### 3. PreLiquidationManager
**File**: `src/liquidation/PreLiquidation.sol`

#### Main Features:
- Inspired by Morpho Blue pre-liquidation system
- Supports multiple protocols (Aave V3, Morpho, Spark, extensible)
- Linear LIF/LCF scaling based on LTV position
- Both keeper-funded and flash loan liquidations

#### Pre-Liquidation Mechanics:
LTV Range: [preLltv → protocolLltv]
├── At preLltv: Minimal intervention (LIF=1.01, LCF=5%)
├── At protocolLltv: Maximum intervention (LIF=1.10, LCF=50%)
└── Linear interpolation between bounds
Keeper Incentive: Profit = SeizedCollateral × LIF - RepaidDebt

### 4. UniversalLendingWrapper (ULW)
**File**: `src/UniversalLendingWrapper.sol`

#### Main Features:
- Assembly-based calldata generation for gas optimization
- Support for multiple protocols (Aave V3/V2, Compound V3/V2, Morpho)
- Batch operation support (supply+borrow, repay+withdraw)
- Minimal memory allocation and efficient selector encoding

### 5. OracleAggregator
**File**: `src/OracleAgg.sol`

#### Main Features:
- Multi-source price feeds with automatic failover
- Supports Chainlink, Uniswap V3 TWAP, and custom oracles
- Price deviation checking between sources
- Staleness detection and validation

### 6. Asset Wrappers
**Files**: `src/AssetWrapper.sol`, `src/EthWrapper.sol`

#### Main Features:
- Seamless deposits/withdrawals with asset conversion
- ETH ↔ WETH conversion for native ETH support
- DEX integration with whitelisted routers
- Token swaps between vault asset and user tokens

---

## Main System Flows

### 1. Deposit Flow
User → SuperVault.deposit()
├── Transfer assets from user
├── Mint shares based on current PPS
├── Update vault state (totalIdle)
└── Keep reserves for instant withdrawals
Alternative: ETH/Asset Wrappers
├── EthWrapper: ETH → WETH → Vault Asset → Deposit
└── AssetWrapper: User Token → Vault Asset → Deposit

### 2. Withdrawal Flow

#### Instant Withdrawal:
User → SuperVault.withdraw()
├── Check reserves availability
├── Transfer assets directly from reserves
└── Update vault state

#### Async Withdrawal:
User → SuperVault.requestWithdrawal()
├── Lock user shares in vault
├── Add to withdrawal queue
└── Wait for batch processing
Admin → SuperVault.processWithdrawals()
├── Calculate assets for batch
├── Ensure liquidity (recall from engine if needed)
└── Mark requests as processed
User → SuperVault.claimWithdrawal()
├── Transfer assets to user
├── Burn locked shares
└── Update claimable assets

### 3. Open Position Flow
Admin → StrategyManager.openPosition()
├── 1. Take supply asset from vault (e.g., 5000 USDC)
├── 2. Flash loan additional supply asset (e.g., 4000 USDC)
├── 3. Supply total to protocol (9000 USDC)
├── 4. Borrow target asset (e.g., 1.4 WETH)
├── 5. Swap borrowed asset to supply asset (WETH→USDC)
├── 6. Repay flash loan (4000 USDC + premium)
└── 7. Store position data (74% LTV achieved)

### 4. Close Position Flow
Admin → StrategyManager.closePosition()
├── 1. Flash loan borrowed asset (1.4 WETH)
├── 2. Repay all debt to protocol
├── 3. Withdraw all collateral (9000 USDC)
├── 4. Swap collateral to borrowed asset (USDC→WETH)
├── 5. Repay flash loan (1.4 WETH + premium)
└── 6. Return remaining assets to vault

### 5. Migrate Position Flow
Admin → StrategyManager.migratePosition()
├── 1. Flash loan borrowed asset amount (e.g., 1.4 WETH)
├── 2. Repay all debt on source venue (e.g., Aave)
├── 3. Withdraw all collateral from source venue (9000 USDC)
├── 4. Supply collateral to target venue (e.g., Morpho)
├── 5. Borrow debt asset from target venue (1.4 WETH + premium)
├── 6. Repay flash loan (1.4 WETH + premium)
└── 7. Update position venue and status to 'Migrated'

### 6. Pre-liquidation Flow

#### Regular Pre-liquidation:
Keeper → PreLiquidationManager.preLiquidate()
├── 1. Check position health (LTV > preLLTV threshold)
├── 2. Calculate optimal repay/seize amounts using linear scaling
├── 3. Keeper provides debt tokens
├── 4. Execute partial liquidation via StrategyManager
├── 5. Transfer seized collateral to keeper
└── 6. Keeper profits from liquidation bonus

#### Flash Loan Pre-liquidation:
Keeper → PreLiquidationManager.preLiquidateWithFlashLoan()
├── 1. Check position health
├── 2. Flash loan debt tokens
├── 3. Execute liquidation → receive collateral
├── 4. Swap collateral to debt tokens via DEX
├── 5. Repay flash loan + premium
└── 6. Send remaining profit to keeper (capital-free operation)

---

## Design Decisions & Tradeoffs

### 1. Monolithic vs Modular Architecture
**Decision**: Hybrid approach with core ExecutionEngine and modular adapters

- **Benefits**: Reduced gas costs, atomic operations, simplified state management
- **Tradeoffs**: Less modularity in core components

### 2. Single Contract vs Separated Looping Logic
**Decision**: Combined StrategyManager with integrated looping

- **Rationale**: Dependencies between position management and looping operations
- **Benefits**: Lower gas costs, reduced complexity
- **Tradeoffs**: Larger contract size

### 3. Fixed-Term Integration
**Decision**: Not implemented in current version 

- Because of the different operational complexity (Term Finance auctions, Pendle PT/YT splits) I though it would be best if we dont integrate this in the current version,but we can have Separate strategy vaults for fixed-term protocols
- **Future**: Two-tier system with FixedYieldManager for term products