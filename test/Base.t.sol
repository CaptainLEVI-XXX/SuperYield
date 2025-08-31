// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AddressInfo} from "./helper/Address.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {ERC1967Factory} from "@solady/utils/ERC1967Factory.sol";
import {SuperVault} from "../src/SuperVault.sol";
import {EthVaultWrapper} from "../src/EthWrapper.sol";
import {UniversalLendingWrapper} from "../src/UniversalLendingWrapper.sol";
import {AssetVaultWrapper} from "../src/AssetWrapper.sol";
import {StrategyManager} from "../src/engine/ExecutionEngine.sol";
import {PreLiquidationManager} from "../src/liquidation/PreLiquidation.sol";
import {IUniswapV3Router} from "../src/interfaces/IUniswapV3Router.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {AaveV3Adapter} from "../src/adapter/AaveV3.sol";
import {OracleAggregator} from "../src/OracleAgg.sol";
import {PreLiquidationCore} from "../src/abstract/PreLiquidationCore.sol";

abstract contract BaseTest is Test, AddressInfo {
    using SafeTransferLib for address;

    // Core contracts
    SuperVault public superVault;
    StrategyManager public strategyManager;
    ERC1967Factory public factory;
    AssetVaultWrapper public assetWrapper;
    EthVaultWrapper public ethWrapper;
    UniversalLendingWrapper public ulw;
    PreLiquidationManager public preLiquidationManager;
    AaveV3Adapter public aaveAdapter;
    OracleAggregator public oracleAggregator;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), MAINNET_FORK_BLOCK);

        // Deploy contracts
        factory = new ERC1967Factory();

        // Deploy and initialize ExecutionEngine
        StrategyManager impl = new StrategyManager();
        address proxy = factory.deploy(address(impl), admin);
        strategyManager = StrategyManager(proxy);

        // Deploy core contracts
        superVault = new SuperVault(admin, address(strategyManager), USDC, "sUSDC", "sUSDC");
        assetWrapper = new AssetVaultWrapper(address(superVault), admin, WETH);
        ethWrapper = new EthVaultWrapper(address(superVault), admin);
        ulw = new UniversalLendingWrapper();

        // Deploy PreLiquidation
        PreLiquidationManager preLiqImpl = new PreLiquidationManager();
        proxy = factory.deploy(address(preLiqImpl), admin);
        preLiquidationManager = PreLiquidationManager(proxy);

        // Deploy Oracle and Adapter
        oracleAggregator = new OracleAggregator(admin);
        aaveAdapter = new AaveV3Adapter(AAVE_DATA_PROVIDER, address(oracleAggregator), admin);

        // Initialize contracts
        _initializeProtocol();

        // Setup test users
        _setupUsers();
    }

    function _initializeProtocol() internal {
        strategyManager.initialize(INSTADAPP_FLASHLOAN, address(ulw), address(preLiquidationManager), admin);

        vm.startPrank(admin);

        // Register vault and routes
        strategyManager.registerVault(address(superVault));
        strategyManager.whitelistRoute("UniswapV3", UniswapV3);

        // Register venues
        strategyManager.registerVenue(AAVE_V3_POOL, 0, address(aaveAdapter));
        strategyManager.registerVenue(COMPOUND_V3_USDC, 2, address(0));
        strategyManager.registerVenue(MORPHO_AAVE, 4, address(0));

        // Setup wrappers
        assetWrapper.whitelistRoute("UniswapV3", UniswapV3);
        ethWrapper.whitelistRoute("UniswapV3", UniswapV3);

        // Initialize PreLiquidation
        preLiquidationManager.initialize(address(strategyManager), INSTADAPP_FLASHLOAN, admin);
        preLiquidationManager.whitelistRoute("UniswapV3", UniswapV3);

        // Setup oracles
        _setupOracles();

        // Register market
        marketId = aaveAdapter.registerMarket(USDC, WETH);

        vm.stopPrank();
    }

    function _setupOracles() internal {
        oracleAggregator.whitelistOracle(ETH_USD, true);
        oracleAggregator.whitelistOracle(USDC_USD, true);
        oracleAggregator.whitelistOracle(WETH_USDC_V3_POOL, true);

        // ETH/USD feed
        OracleAggregator.OracleConfig memory primary = OracleAggregator.OracleConfig({
            oracleType: OracleAggregator.OracleType.Chainlink,
            source: ETH_USD,
            maxDeviation: 1e18,
            maxStaleness: 86400,
            isActive: true
        });
        OracleAggregator.OracleConfig memory falback;
        oracleAggregator.configurePriceFeed(WETH, oracleAggregator.USD(), primary, falback);

        // USDC/USD feed
        primary.source = USDC_USD;
        oracleAggregator.configurePriceFeed(USDC, oracleAggregator.USD(), primary, falback);

        // WETH/USDC TWAP
        primary = OracleAggregator.OracleConfig({
            oracleType: OracleAggregator.OracleType.UniV3TWAP,
            source: WETH_USDC_V3_POOL,
            maxDeviation: 1e18,
            maxStaleness: 86400,
            isActive: true
        });
        oracleAggregator.configurePriceFeed(WETH, USDC, primary, falback);
    }

    function _setupUsers() internal {
        // Fund users
        deal(USDC, alice, LARGE_AMOUNT_USDC + SMALL_AMOUNT_USDC);
        deal(WETH, alice, LARGE_AMOUNT_WETH + SMALL_AMOUNT_WETH);
        deal(USDC, bob, LARGE_AMOUNT_USDC + SMALL_AMOUNT_USDC);
        deal(WETH, bob, LARGE_AMOUNT_WETH + SMALL_AMOUNT_WETH);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // Setup approvals for Alice
        vm.startPrank(alice);
        WETH.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(assetWrapper), type(uint256).max);
        WETH.safeApprove(address(assetWrapper), type(uint256).max);
        vm.stopPrank();

        // Setup approvals for Bob
        vm.startPrank(bob);
        WETH.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(assetWrapper), type(uint256).max);
        WETH.safeApprove(address(assetWrapper), type(uint256).max);
        vm.stopPrank();
    }

    function buildSwapParams(address tokenIn, address tokenOut, uint256 amountIn, address receiver)
        internal
        view
        returns (DexHelper.DexSwapCalldata memory)
    {
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 3000,
            recipient: receiver,
            deadline: block.timestamp + 1,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory swapData = abi.encodeWithSelector(IUniswapV3Router.exactInputSingle.selector, params);

        return DexHelper.DexSwapCalldata({
            swapCalldata: swapData,
            identifier: keccak256(abi.encodePacked("UniswapV3", UniswapV3))
        });
    }

    function configurePreLiquidationMarket(bool flashLoanEnabled) internal {
        PreLiquidationCore.PreLiquidationParams memory params = PreLiquidationCore.PreLiquidationParams({
            preLltv: 0.75e18,
            preLCF1: 0.05e18,
            preLCF2: 0.5e18,
            preLIF1: 1.02e18,
            preLIF2: 1.1e18,
            dustThreshold: 100e6
        });

        vm.prank(admin);
        preLiquidationManager.configureMarket(
            marketId, 1, address(aaveAdapter), params, 0.7e18, 0.5e18, 300, flashLoanEnabled
        );
    }
}
