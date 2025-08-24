// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

abstract contract AddressInfo {
    uint256 constant MAINNET_FORK_BLOCK = 23213330;

    // Protocol addresses on mainnet
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3; // cUSDCv3
    address constant MORPHO_AAVE = 0x777777c9898D384F785Ee44Acfe945efDFf5f3E0;

    // Test tokens
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address constant INCH_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant PARASWAP_V6 = 0x6A000F20005980200259B80c5102003040001068;
    address constant ZEROX_V4 = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address constant KYBER_AGGREGATOR = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant UniswapV3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address user = address(0x23323);
}
