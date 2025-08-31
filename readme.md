#### Architecture Design

- How InstaDapp Lite works:
    - instadapp is not open-source but after debugging several transaction via etherscan, I found that it have only A single main contract that has all the logic of ERC4626 + performs leverage logic with flashLoan within integrated platforms.
    - Possible explanation is this design is gas saver(as less components -> less interaction -> save gass).
    - Vault is customized for the startegy that they have built. for ex: currently they are supporting westh/ETH ...and this stratsgy vault
    logic design in a way that it can perform good yields.
    - so their design is probably not modular but customized for their strategy , and I think it is a good approach because while building a startegy vault we always go for better yield and gas efficiency.

 - How Super Yield (Assignment) works:

 - In a nutshell , user can deposit asset in the vault, execution Engine takes the vault fund to invest it in appropriate protocols to create looping leverage psoition with flashloan.Where to invest? This answer must be provided by the backend. contract is only responsible for investing not for underlying logic behind investing as it would be become a complex contract .Less core , less bugs.
 _ we also have a preLiquidationManager that is responsible for pre-liquidation of the position to maintain optimal LTV.It uses the same logic as moprho blue pre-liquidation system.but it can support any protocol.

 - It consist of three main components Supervault: responsible for handling user deposit/withdraw,Execution Engine: responsible for performing leverage logic with flashLoan within integrated platforms and PreLiquidationManager: responsible for pre-liquidation of the position to maintain optimal LTV.

 - SuperVault: ERC4626 + Reserve(instant withdrawals) + Batch;
    - Deposit Flow (wstETH/Eth): 
        - User can approve and deposit wstETH directly to vault.
        - In case if user has Eth then EthWrapper can be used for deposit into the vault.
        - After the deposit vault funds stays in the vault unless execution engine calls vault for funds.
    - Withdraw Flow:
        - User can directly withdraw wstETH from vault, In case if he depsoited Eth then EthWrapper can be used for withdraw equivalent Eth deposited.
        - for instant withdrawals Super vault use its reserve.
        - If the reserve is burn out , user need to add a request for withdrawals in queue.
        - Admin need to process the queue and request funds from Execution Engine.
        - After that user can claim the withdrawals. 

 - Execution Engine is responsible for performing leverage logic with flashLoan within integrated platforms.It is built in such a way that it can 
 support multiple protocols and used Instadapp flashLoan aggregator for flashLoan.
 It has functions like open position , close position , rebalance (migrate position to different protocol), and rebalanceToTargetLTV.


 - one point of design may be to seprate the Looping logic with Position manager i.e. we can have two contract one for position manager and other for perform Looping. I didnot choose this design ...because there were some depenecy of Looping with the position that were created and it would have increase the gas price of the system. Currently Execution Engine is single contract.

- ULW : Universal Lending Wrapper: This is just a wrapper contract that can be used to build calldata for different lending protocols (low-level assembly for optimization).






























#### Pre-Liquidation System

- This pre-liquidation system is isnpired from morpho-blue pre-liquidation system, but its extended for multiple protocols with some extra features.
- Works with AAVE V3, Morpho, Spark and can be extended to other protocols. 
- Linear LIF/LCF Scaling: Smooth incentive and close factor transitions based on LTV
```bash
┌─────────────────────────────────────────┐
│          Strategy Manager               │
│     (Single Borrower, Multi-Position)   │
└────────────┬────────────────────────────┘
             │
┌────────────▼────────────────────────────┐
│  CrossProtocolPreLiquidationManager     │
│  - Orchestrates pre-liquidations        │
│  - Manages market configurations        │
│  - Validates parameters                 │
└────────────┬────────────────────────────┘
             │
    ┌────────┴────────┬─────────┬─────────┐
    │                 │         │         │
┌───▼───┐      ┌─────▼───┐ ┌──▼───┐ ┌────▼────┐
│ Aave  │      │Compound │ │Spark │ │  More   │
│Adapter│      │ Adapter │ │Adapt.│ │Adapters │
└───┬───┘      └─────┬───┘ └──┬───┘ └────┬────┘
    │                │         │          │
┌───▼────────────────▼─────────▼──────────▼───┐
│          Lending Protocols                   │
│  (Aave V3, Compound V3, Spark, etc.)        │
└──────────────────────────────────────────────┘

```




#### Integration of fixed term protocol
I haven't integrated the fixed term protocol as I believe it would be a bad idea to do so. Since this domain
is still not saturated building a system that kind of integrates fixed term with float will add complexity to the 
current system. 
But I think the better approach would to have invidual strategy vaults for each protocol that can extract the most out of 
the respective market. 

Although this was an approach in my mind to integrate fixed term.

Two-tier system: StrategyManager for liquid strategies, separate FixedYieldManager for term products
Reserve allocation: Only allocate true excess reserves (not needed for 30+ days) to fixed-term
Integration: StrategyManager can query fixed positions for total value but doesn't manage them

Term Finance: Submit bid → wait days → reveal → wait for auction → claim tokens → wait weeks/months for maturity
Pendle: Manage PT/YT splits, track multiple maturities, handle redemptions
Morpho Blue: Each market needs unique parameter tracking

working of these protocols are entirely differnet, I haven't researched a lot in this side but from my current understanding I think
complexity of its integration, yields that we would be getting and the gas price to build such extended transaction flow would not be good idea; 