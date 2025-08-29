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
import {StrategyManager} from "../src/ExecutionEngine.sol";
import {PreLiquidationManager} from "../src/PreLiquidation.sol";
import {IUniswapV3Router} from "../src/interfaces/IUniswapV3Router.sol";
import {DexHelper} from "../src/abstract/DexHelper.sol";
import {AaveV3Adapter} from "../src/adapter/AaveV3.sol";
import {OracleAggregator} from "../src/OracleAgg.sol";

abstract contract BaseTest is Test, AddressInfo {
    using SafeTransferLib for address;

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
        // deploy 1967 factory
        factory = new ERC1967Factory();
        // deploy Respective contract
        _deployExecutionEngine();
        _deploySuperVault();
        _deployAssetWrapper();
        _deployEthWrapper();
        _deployUniversalLendingWrapper();
        _deployPreLiquidationManager();
        _deployOracleAggregator();
        // build the initialization data for the protocol
        _setUpInitializationData();

        _dealBobAndAlice();

        vm.startPrank(alice);
        WETH.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(assetWrapper), type(uint256).max);
        WETH.safeApprove(address(assetWrapper), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        WETH.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(superVault), type(uint256).max);
        USDC.safeApprove(address(assetWrapper), type(uint256).max);
        WETH.safeApprove(address(assetWrapper), type(uint256).max);
        vm.stopPrank();
    }

    function _deploySuperVault() internal {
        superVault = new SuperVault(admin, address(strategyManager), USDC, "sUSDC", "sUSDC");
    }

    function _deployExecutionEngine() internal {
        StrategyManager impl = new StrategyManager();
        address proxy = factory.deploy(address(impl), admin);
        strategyManager = StrategyManager(proxy);
    }

    function _deployAssetWrapper() internal {
        assetWrapper = new AssetVaultWrapper(address(superVault), admin, WETH);
    }

    function _deployEthWrapper() internal {
        ethWrapper = new EthVaultWrapper(address(superVault), admin);
    }

    function _deployUniversalLendingWrapper() internal {
        ulw = new UniversalLendingWrapper();
    }

    function _deployPreLiquidationManager() internal {
        PreLiquidationManager impl = new PreLiquidationManager();
        console.log("PreLiquidationManager deployed");
        address proxy = factory.deploy(address(impl), admin);
        console.log("PreLiquidationManager deployed");
        preLiquidationManager = PreLiquidationManager(proxy);
    }

    function _deployOracleAggregator() internal {
        oracleAggregator = new OracleAggregator(admin);
    }

    function deployAaveAdapter() internal {
        aaveAdapter = new AaveV3Adapter(AAVE_DATA_PROVIDER, address(oracleAggregator)); //replace it by oracle address);
    }

    function _setUpInitializationData() internal {
        // Execution Engine
        strategyManager.initialize(INSTADAPP_FLASHLOAN, address(ulw), address(preLiquidationManager), admin);
        vm.startPrank(admin);
        strategyManager.registerVault(address(superVault));

        strategyManager.whitelistRoute("UniswapV3", UniswapV3);

        strategyManager.registerVenue(AAVE_V3_POOL, 0);
        strategyManager.registerVenue(COMPOUND_V3_USDC, 2);
        strategyManager.registerVenue(MORPHO_AAVE, 4);

        //aseetWrapper
        assetWrapper.whitelistRoute("UniswapV3", UniswapV3);
        //eth wrapper
        ethWrapper.whitelistRoute("UniswapV3", UniswapV3);
        // PreLiquidationManager
        preLiquidationManager.initialize(address(strategyManager), INSTADAPP_FLASHLOAN, admin);
        console.log("PreLiquidationManager initialized");

        oracleAggregator.whitelistOracle(ETH_USD, true);
        oracleAggregator.whitelistOracle(USDC_USD, true);
        oracleAggregator.whitelistOracle(WETH_USDC_V3_POOL, true);

        OracleAggregator.OracleConfig memory primary = OracleAggregator.OracleConfig({
            oracleType: OracleAggregator.OracleType.Chainlink,
            source: ETH_USD,
            maxDeviation: 1e18,
            maxStaleness: 86400,
            isActive: true
        });
        OracleAggregator.OracleConfig memory fallbck;

        oracleAggregator.configurePriceFeed(WETH, oracleAggregator.USD(), primary, fallbck);

        primary = OracleAggregator.OracleConfig({
            oracleType: OracleAggregator.OracleType.Chainlink,
            source: USDC_USD,
            maxDeviation: 1e18,
            maxStaleness: 86400,
            isActive: true
        });

        oracleAggregator.configurePriceFeed(USDC, oracleAggregator.USD(), primary, fallbck);

        primary = OracleAggregator.OracleConfig({
            oracleType: OracleAggregator.OracleType.UniV3TWAP,
            source: WETH_USDC_V3_POOL,
            maxDeviation: 1e18,
            maxStaleness: 86400,
            isActive: true
        });

        oracleAggregator.configurePriceFeed(WETH, USDC, primary, fallbck);

        vm.stopPrank();
    }

    function _buildSwapParams(address tokenIn, address tokenOut, uint256 amountIn, address receiver)
        internal
        view
        returns (DexHelper.DexSwapCalldata memory)
    {
        // Build calldata for UniswapV3 exactInputSingle
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

    function _dealBobAndAlice() internal {
        deal(USDC, alice, LARGE_AMOUNT_USDC + SMALL_AMOUNT_USDC);
        deal(WETH, alice, LARGE_AMOUNT_WETH + SMALL_AMOUNT_WETH);
        deal(USDC, bob, LARGE_AMOUNT_USDC + SMALL_AMOUNT_USDC);
        deal(WETH, bob, LARGE_AMOUNT_WETH + SMALL_AMOUNT_WETH);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }
}
