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