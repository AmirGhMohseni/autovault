# AutoVault — Autonomous AI Investment Fund on Base

Non-custodial ERC-4626 vaults that let users deposit USDC and gain AI-managed exposure to
Coinbase-issued tokenized U.S. equities on Base. Full design rationale, risk model, fee
mechanics, and roadmap are in [`docs/SPEC.md`](docs/SPEC.md) — start there.

## What's in this repo

```
contracts/     Solidity 0.8.24 / Foundry — the on-chain protocol
  AIFundVault.sol            ERC-4626 vault: deposits, withdrawals, NAV, agent-gated rebalancing
  TokenizedStockRegistry.sol Governance allowlist of tokenized stocks (sector, China-linked flag)
  RiskManager.sol            Hard on-chain caps: position/sector/slippage/turnover, per vault
  FeeModule.sol               Streaming management fee + high-water-mark performance fee
  PriceOracleAdapter.sol      Chainlink primary + secondary feed, staleness/deviation circuit breaker
  SwapRouterAdapter.sol       Allowlisted DEX-aggregator wrapper, enforces minAmountOut itself
  AgentExecutor.sol           Verifies the AI agent's EIP-712 signed intent, drives the rebalance
  interfaces/IAutoVaultTypes.sol   Shared structs/interfaces used across every contract above

agent/         Off-chain AI agent service (TypeScript)
  src/optimizer.ts            Deterministic quant core (risk-parity / equal-weight) — the ONLY
                               component that outputs portfolio weights
  src/llm/compileStrategy.ts  Natural-language -> StrategySpec compiler (constrained function-
                               calling; never outputs weights, only the schema the optimizer consumes)
  src/signer.ts                EIP-712 intent signing (swap in an MPC/HSM-backed viem account)
  src/orchestrator.ts          The main decision loop (see docs/SPEC.md §4.1)

test/          Foundry unit tests for the core vault (deposit/withdraw/caps/pause/roles)
script/        Deploy.s.sol — deploys the full MVP stack to Base / Base Sepolia
docs/SPEC.md   The full 14-section specification: architecture, contract layouts, agent
               decision loop, risk parameters, fee module, threat model, roadmap, disclaimers
```

## The core safety property

**The AI agent never has custody and can never move funds outside pre-approved bounds.**
It only produces a signed *intent* (target portfolio weights). `AgentExecutor.sol`
verifies the signature, `RiskManager.sol` re-checks every trade against on-chain,
governance-timelocked position/sector/slippage/turnover caps, and only allowlisted tokens
(`TokenizedStockRegistry.sol`) and allowlisted routers (`SwapRouterAdapter.sol`) can ever
be touched. A compromised agent signing key can, at worst, submit an intent that still has
to pass every one of those checks — it cannot raise its own limits or withdraw a single
token.

## Getting started

```bash
# Contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts
forge build
forge test -vvv

# Deploy (Base Sepolia example)
export GOVERNANCE_ADDRESS=0x...      # Safe multisig / TimelockController, never an EOA
export SWAP_AGGREGATOR_ADDRESS=0x... # e.g. 0x Exchange Proxy on Base
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast

# Agent
cd agent && npm install
npm run dev
```

## What's genuinely production-ready here vs. what's a skeleton

- **Production-shaped and reasonably complete:** vault accounting (ERC-4626 + decimals
  offset against the classic donation/inflation attack), risk-cap enforcement, streaming
  + high-water-mark fee accrual, oracle staleness/deviation circuit breaking, EIP-712
  intent verification, role separation between agent/executor/router/vault.
- **Explicitly a skeleton, needs real integration before mainnet funds:**
  - `SwapRouterAdapter`'s `swapCalldata` must be built against a real Base aggregator
    (0x / 1inch) — the contract enforces `minAmountOut` but doesn't build quotes itself.
  - `agent/src/optimizer.ts` ships a simplified inverse-volatility risk-parity model, not
    a full mean-variance/Black-Litterman solver (flagged as a Phase-2/3 item in the spec).
  - `agent/src/llm/compileStrategy.ts` needs a real LLM provider call wired into
    `callLLM` behind the same strict schema.
  - IPFS/Arweave pinning in `orchestrator.ts` is stubbed (returns a content hash of the
    payload without actually publishing it anywhere yet).
  - No frontend is included in this pass — `docs/SPEC.md` §6 and §10 spec it out
    (Next.js + wagmi/viem + a subgraph for NAV/holdings history).
- **Before any real deposits:** at least one independent security audit of
  `AIFundVault.sol`, `RiskManager.sol`, `FeeModule.sol`, and `AgentExecutor.sol`, plus
  fuzz/invariant testing beyond the unit tests included here (see `docs/SPEC.md` §8).

## Disclaimers

This is engineering scaffolding, not financial, legal, or investment advice, and not an
offer to sell securities. See `docs/SPEC.md` §13 for the full disclaimer set, including
notes on Coinbase's own terms governing the underlying tokenized stocks.
