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

- Receives 5000 USDC from QueueManager
    ↓
- Analyzes market conditions:
    - Current lending rates: 5% supply, 3% borrow
    - Fixed rates available: 4% for 30 days
    - Current positions: 80% looped, 10% fixed, 10% reserve
    ↓
- Makes allocation:
    - 4000 USDC → Loop Engine (maintain 80%)
    - 500 USDC → Fixed Rate (opportunity)
    - 500 USDC → Reserves (liquidity)


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

#### Rebalancer : Position Adjuster
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


#### OracleManager.sol
Responsibility: Provides reliable price feeds for ALL calculations


#### Smart contract architecture
- SuperVault.sol (ERC4626 + QueueManager + ReserveManager)
- StrategyManager.sol
- LoopEngine.sol
- PositionManager.sol
- Rebalancer.sol
- FixedRateAllocator.sol
- PreLiquidationGuard.sol
- OracleManager.sol

we can have a EngineManager to handle strategy Manger ,LoopEngine, Rebalancer , Why?
These three contracts will interact with each other a lot and we can have a single contract to handle all the interactions.
but the problem will be that we will loose modularity of each contract.


what if ? vault -> DaimondProxy { facet1:StrategyManager - facet2:LoopEngine - facet3:Rebalancer }(the problem will how these facet will interact with each other, all the storage will at DiamondProxy but facet can read other facet storage, but in terms of calling the facet function we can use delegatecall which will be expensive)
- this architecture will be modular and we facets interact with each other than it will be expensive on gas.


#### Final thoughts:
- Vault(erc4626,queueManager,reserveManager). 
    - this can be a Immuatable vault.
    - depicts trust for user interfacing contract.
- Then we can have Execution engine(looping,position,rebalancer)
    - this can be a mutable contract.
    - startegies can be changed but the important part is main components will be internal so we will have less gas cost for each transaction.

- Independent Liquidator contract and Oracle contract



#### Open position flow: 
 - for opening an position 
    - venue Info(ex:aave,compound)
        - for venue info we need an protocolId/VenueType/
        - supply amount
        - supplied asset
        - borrowed asset
        - supply denomiaton token
        - borrow denomiation token
        - leverage
        - optimal LTV Band

- It should check first the venue is supported for not

- what should it do ?
- check the diamond funds for the required asset
- create a new Position to track
- maintains a storage for supply amount,borrowed amount,leverage,ltv,health factor etc
- call the loop engine to create a position
- it should also return an positionID for that position
```solidity
struct PositionParams{
    uint256 supplyAmount;
    uint32 leverage;
    address suppliedAsset;
    address borrowAsset;
    address suppliedDenominationToken;
    address borrowDenominationToken;
    uint8 lowerBand;
    uint8 upperBand;
    bytes memory swapCalldata;
}
mapping(uint8 venueId=>mapping(uint8 venueType=>bool)) public isVenueSupported;

function openPosition(uint8 venueId,uint8 venueType,PositionParams calldata params){
    
    if !isVenueSupported[venueId][venueType] return error;
    if params.suppliedAsset.balanceOf(address(this)) - unloopedReserve < params.supplyAmount) revert;
    // other checks for input params;
    bytes32 positionId = pointer++;
    positionInfo[positionId]= params;
    if (venuueType==FixedRate){
        _executeFixedRate(fixedRateParams);
    }else{
      ILoopEngine(diamond).loop(LoopParams);
    }
    emit OpenPosition(positionId);
    
}
```
#### Close position flow:
- check if the position is already closed? if so return error 
- close the position for the given positionID
    - involves calling the loop engine to pay the debt and withdraw the collateral
    - update the position storage
    - delete the position from the storage
    - return the positionID

#### Close all positions for an Venue ? IS IT NEEDED?
- check all the openPosition for the given venue
- close all the positions for the given venue
    - involves calling the loop engine to pay the debt and withdraw the collateral for each position
    - update the position storage
    - delete the position from the storage

#### Switch Position venue flow: 
- it should involve something with closing an existing position and opening a new position with different venue 
- or it can involve closing an existing position with adding funds to other venue similar venue;
- we need to check that the current closed leveraged position should match with other leverage position.that means ....
- only funds can be transferred to other venue no swapping of assets to different asset
#### thought process: - May be we need something that stores the type of leverage position: for ex: Supplied asset, borrowed asset
- these assets should be same for switching position. isPositionSwitchable[suppliedAsset][borrowedAsset] = true;
        
#### Rebalance Position
-- it can be leverage or releverage




##### Check Before : 
- In the case of upgrading the contract you will find at several positions we used specific storage slots for storing the data to avoid storage collisions. Please note that ac:
- CASE- I
``` solidity
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract A{
mapping(address=>bool) public isCheck;
uint256 public count;
mapping(address=>uint256) public balance;

function something() public{
    isCheck[msg.sender] =  true;
    count++;
    balance[msg.sender] +=1;
}
//67047

}

contract B{
struct Data{
    mapping(address=>bool) isCheck;
    uint256 count;
    mapping(address=>uint256) balance;
}

bytes32 public constant DATA_STORAGE = 0x1edd0f8a85d839e3b1cb7825274c24d70cd41e8d831c8c66c337eeab7922063a;
function dataStorage() internal pure returns(Data storage _data){
    bytes32 position = DATA_STORAGE;
    assembly {
        _data.slot := position
    }
}


function something() public {
    Data storage data = dataStorage();
    data.isCheck[msg.sender] =  true;
    data.count++;
    data.balance[msg.sender] += 1;
}

function isCheck() public view returns(bool){
    return dataStorage().isCheck[msg.sender];
}

function count() public view returns(uint256){  
    return dataStorage().count;
}
}

//67150 ---- the additional gas is due to invokation of the dataStorage() function

```


