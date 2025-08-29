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

    address constant AAVE_DATA_PROVIDER = 0x41393e5e337606dc3821075Af65AeE84D7688CBD; // v3 ProtocolDataProvider

    address constant INSTADAPP_FLASHLOAN = 0x619Ad2D02dBeE6ebA3CDbDA3F98430410e892882;

    address alice = address(0x23323);
    address bob = address(0x89334);

    address admin = address(0x23e3e233);

    uint256 LARGE_AMOUNT_WETH = 1000_000e18;
    uint256 LARGE_AMOUNT_USDC = 1000_000e6;

    uint256 SMALL_AMOUNT_WETH = 10e18;
    uint256 SMALL_AMOUNT_USDC = 10e6;

    uint256 FOUR_THOUSAND_DOLLAR = 4_000e6;
    uint256 FIVE_THOUSAND_DOLLAR = 5_000e6;

    // Chainlink feeds (mainnet)
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD
    address constant WBTC_USD = 0xFD858C8Bc5AC5E10C7d4AD0A7Eb7b8d6FC6c4B79; // WBTC/USD

    // Uniswap V3 WBTC/WETH 0.3% pool
    address constant WBTC_WETH_V3_POOL = 0xcbF7a1D81726D5cdFdB2B79a7a1Be3a5f7c84e29;

    // Tokens
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Chainlink feeds
    address constant USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Uniswap V3 pool WETH/USDC 0.05%
    address constant WETH_USDC_V3_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
}
