// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../contracts/TokenizedStockRegistry.sol";
import "../contracts/RiskManager.sol";
import "../contracts/FeeModule.sol";
import "../contracts/PriceOracleAdapter.sol";
import "../contracts/SwapRouterAdapter.sol";
import "../contracts/AgentExecutor.sol";
import "../contracts/AIFundVault.sol";

/// @notice Deploys the full MVP stack for a single curated vault ("AI Tech Leaders") on
///         Base. Run with `forge script script/Deploy.s.sol --rpc-url base_sepolia
///         --broadcast --verify`. `admin` should be a Safe multisig / TimelockController
///         address in any real deployment — never an EOA — per docs/SPEC.md §8/§9.
contract Deploy is Script {
    // Circle's official USDC token. Base mainnet by default; override with USDC_ADDRESS for
    // testnet deploys (e.g. Base Sepolia test USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e —
    // verify current value at developers.circle.com/stablecoins/usdc-contract-addresses).
    address constant USDC_MAINNET_DEFAULT = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address admin = vm.envAddress("GOVERNANCE_ADDRESS"); // Safe / TimelockController
        address swapAggregatorTarget = vm.envAddress("SWAP_AGGREGATOR_ADDRESS"); // e.g. 0x Exchange Proxy on Base
        address usdc = vm.envOr("USDC_ADDRESS", USDC_MAINNET_DEFAULT);

        vm.startBroadcast();

        TokenizedStockRegistry registry = new TokenizedStockRegistry(admin);
        RiskManager riskManager = new RiskManager(admin);
        FeeModule feeModule = new FeeModule(admin);
        PriceOracleAdapter oracle = new PriceOracleAdapter(admin);
        SwapRouterAdapter router = new SwapRouterAdapter(admin);

        AgentExecutor executor = new AgentExecutor(
            admin,
            IRiskManager(address(riskManager)),
            IExecSwapRouter(address(router)),
            swapAggregatorTarget
        );

        AIFundVault vault = new AIFundVault(
            IERC20(usdc),
            "AutoVault AI Tech Leaders",
            "avTECH",
            admin,
            IRiskManager(address(riskManager)),
            IFeeModule(address(feeModule)),
            ITokenizedStockRegistry(address(registry)),
            IPriceOracle(address(oracle)),
            10_000_000e6, // depositCap: 10M USDC (6 decimals)
            1_000_000e6   // perBlockDepositCap: 1M USDC
        );

        // Wire roles: AgentExecutor is the only address ever granted EXECUTOR_ROLE on the
        // vault and CALLER_ROLE on the router — the AI agent's off-chain key holds neither.
        vault.grantRole(vault.EXECUTOR_ROLE(), address(executor));
        router.grantRole(router.CALLER_ROLE(), address(executor));
        riskManager.grantRole(riskManager.EXECUTOR_ROLE(), address(executor));

        vm.stopBroadcast();

        console2.log("TokenizedStockRegistry:", address(registry));
        console2.log("RiskManager:           ", address(riskManager));
        console2.log("FeeModule:             ", address(feeModule));
        console2.log("PriceOracleAdapter:    ", address(oracle));
        console2.log("SwapRouterAdapter:     ", address(router));
        console2.log("AgentExecutor:         ", address(executor));
        console2.log("AIFundVault (avTECH):  ", address(vault));
    }
}