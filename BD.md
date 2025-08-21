## Super Yield Breakdown

### The Big Picture Flow : How the Money will flow in the system
1. User Deposit $1000 in the vault
2. vault mint shares to user
3. Strategy Manager decides what to do with the money
4. Loop Engine creates Leveraged position on markets.
5. Position Manager watches the health of the position.
6. Rebalancer maintains the optimal leverage.
7. User withdraw with profit.


### What contract do we need

#### ERC4626 Vault 
- user interface to deposit/withdraw,
- should track the NAV,PPS and can handle async withdrawals requests. 
- could also choose between ERC-7540 or ERC-7575 for showcasing of handling multiple looping over different chains ? should we actually use one of these, not sure what sort of advantages it bring in terms of capital efficiency but probably would increase complexity of the system for now

#### QueueManager : Responsible for batching deposit and withdrawal requests
- can use some sort Epoch based queueing system to batch deposit and withdrawal requests
- or can use some strict size of queue after fully filled 
- Best option would be to have this queue Manager processDeposit and processWithdrawal function public and can be called by external service or by any user.
- Need to restric the size of loops because larger size may cause DOS attack.


#### ReserveManager :  
- to keep liquidity in the case of withdrawal requests (may be 10% of total assets).
- Use reserves for instant withdrawals and intent-centric swaps {is it like CowSwap an orderbook based swap if so then it would be not a good idea to built this [hold for now] }


##### Final thoughts:
- probably we can have single contract that should handle ERC4626,Batching and reserve logic
- by this way we can save a lot of gas on unnecessary external calls .
- we can name this vault as SuperVault.
- Do we need to make this vault upgradeable? Not sure Now!


#### StrategyManager : Decides what to do with the money
- 


#### LoopEngine: Leverage Creator
- creates and manage leverage position on markets.
    - A flow would be 
        - Receive 4000USDC to deploy at 4x leverage
        - STEP 1 : 
            - calculate flashLoan amount needed
            - Have 4000 USDC
            - Need to borrow 12000 USDC
        - Step 2 :
            - flash Borrow 12000 USDC
            - supply all 16000 USDC on a market
            - Borrow 12000 USDC from same market(75% LTV)
            - Repay Flash Loan
    - RESULT: 
        - Supplied: 16000 USDC
        - Borrowed: 12000 USDC
        - Net exposure: 4000 USDC at 4x leverage
- This contract should handle creating leverage position,selecting best venue(aave or compund),
managing flash loans and position accounting.

#### PositionManager : Health Checker

- continuously monitors the health of the position.
    - Every Hour (calls by the keeper)
        - Check position at AAVE: 
            - Supplied 16000 USDC
            - Borrowed 12000 USDC
            - Current LTV: 75%
        - Evaluate health of the position
            - If LTV < 70% : flag for re-leverage(make more profit)
            - If LTV 70%-80% : All is well (optimal LTV band).
            - If LTV > 80% : flag for de-leverage(getting risky).
            - If LTV > 82% : Emergency - immediate action required.
            
-  this contract monitors real time LTV across all positions , health factor at each venue,Aggregate portfolio health , trigger condition for rebalacning.

#### Rebalancer :  Position Adjuster
- Adjusts the position to maintain optimal LTV.
- Rebalancing Scenarios: 
    - 1: Market drops , LTV increases
        - price drop causes: 
            - collateral Value : $16000 -> $14000
            - debt vaule: $12000(unchanged)
            - new LTV = 12000/14000 = 85.71% (DANGER!)
        - rebalancer action: 
            - Flash borrows 3000 USDC 
            - repay 3000 USDC debt to aave
            - withdraw 3500$ collateral from aave
            - swap to 3500 USDC
            - repays the flash loan
        - New Position: 
            - Supplied: 10500 USDC
            - Borrowed: 9000 USDC
            - LTV: 85.71% -> 75% (safe)
    
    - 2: Market rises , LTV decreases
        - LTV dropped to 68%
        - rebalancer action: 
            - calculate additional borrow capacity
            - borrow more from aave
            - supply borrowed amount back
            - increase leveraged to 75%

- the contract handles adjusting leverage up and down,emergency deleveraging,venue migration for better rates,maintaing optimal LTV band; 


#### Fixed Rate Allocator : The Yield Optimizer
- Allocates to fixed rate protocols when profitable
- Current State: 
    - Variable rate(looped): 12 % APY
    - morpho offerring : 14% fixed fro 30 days.

- Allocator Logic: 
    - if (fixedRate - variableRate > 2 %)
        - Allocates 20% of capital to fixed rate protocol
- Execution Flow: 
     - unwind 20% of loops
     - Deposit to morpho fixed term
     - Lock for 30 days at 14% APY   

- Fixed rate returns recursive looping (Pendle integration): Pendle has about $6B+ TVL, yet there is not auto-looping vaults for the same. Also add a way to enable this as well.

#### Pre-Liquidation Guard (The Safety Net)

- Position approaching danger:
    LTV: 81% and rising
    ↓
- Guard detects risk:
    - Checks every block
    - Sees LTV > 82%
    ↓
- Immediate action:
    1. Use reserves to repay debt
    2. OR flash loan to deleverage
    3. OR trigger Morpho pre-liquidation
    ↓
- Result:
    - Position saved
    - No liquidation penalty
    - LTV back to safe zone

