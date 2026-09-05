import type { Address } from "viem";
import { optimize } from "./optimizer.js";
import { signIntent } from "./signer.js";
import type { AgentIntent, MarketSnapshot, StrategySpec, TradeInstruction } from "./types.js";

/**
 * Main decision loop, run on a schedule (e.g. every REBALANCE_TICK) and on-demand for
 * TRIGGER_EVENTs (volatility spike, oracle recovery, etc). See docs/SPEC.md §4.1 for the
 * full pseudocode this file implements. Deliberately dependency-light / provider-agnostic:
 * plug in real implementations for `fetchMarketSnapshot`, `readCurrentWeights`,
 * `buildRouterCalldata`, and `submitToKeeper` for your environment (Base RPC, a DEX
 * aggregator API, and Chainlink Automation / Gelato respectively).
 */

export interface OrchestratorDeps {
  activeVaults: Array<{ address: Address; strategy: StrategySpec }>;
  fetchMarketSnapshot: (universe: Address[]) => Promise<MarketSnapshot>;
  readCurrentWeights: (vault: Address) => Promise<Record<Address, number>>;
  buildRouterCalldata: (
    vault: Address,
    diffs: Record<Address, number> // signed bps delta per token, +buy / -sell
  ) => Promise<TradeInstruction[]>;
  signAndSubmit: (vault: Address, intent: AgentIntent) => Promise<void>;
  nextNonce: (vault: Address) => Promise<bigint>;
}

const USDC = "0x0000000000000000000000000000000000000000" as Address; // placeholder — set to Base USDC

export async function runTick(deps: OrchestratorDeps): Promise<void> {
  for (const { address: vault, strategy } of deps.activeVaults) {
    const snapshot = await deps.fetchMarketSnapshot(strategy.universe);
    const target = optimize(strategy, snapshot);
    const current = await deps.readCurrentWeights(vault);

    const drift = weightDistanceBps(target.weightsBps, current);
    if (drift < strategy.constraints.rebalanceThresholdBps) {
      continue; // not enough drift to justify a rebalance — avoids churn/gas/fees
    }

    const diffs = computeDiffs(target.weightsBps, current);
    const trades = await deps.buildRouterCalldata(vault, diffs);
    if (trades.length === 0) continue;

    const intent: AgentIntent = {
      vault,
      trades,
      maxSlippageBps: BigInt(strategy.constraints.maxSlippageBps),
      ipfsHash: await pinRationale(vault, target.rationale, snapshot),
      nonce: await deps.nextNonce(vault),
      expiry: BigInt(Math.floor(Date.now() / 1000) + 15 * 60), // 15 min validity window
    };

    await deps.signAndSubmit(vault, intent);
  }
}

function weightDistanceBps(
  target: Record<Address, number>,
  current: Record<Address, number>
): number {
  const keys = new Set([...Object.keys(target), ...Object.keys(current)]);
  let sum = 0;
  for (const k of keys) {
    const a = target[k as Address] ?? 0;
    const b = current[k as Address] ?? 0;
    sum += Math.abs(a - b);
  }
  return sum / 2; // L1 distance / 2 = total turnover-equivalent drift in bps
}

function computeDiffs(
  target: Record<Address, number>,
  current: Record<Address, number>
): Record<Address, number> {
  const keys = new Set([...Object.keys(target), ...Object.keys(current)]);
  const diffs: Record<Address, number> = {};
  for (const k of keys) {
    const a = target[k as Address] ?? 0;
    const b = current[k as Address] ?? 0;
    if (a !== b) diffs[k as Address] = a - b;
  }
  return diffs;
}

/** Pins the human-readable rationale + the raw market snapshot used to derive it to
 *  IPFS/Arweave and returns the content hash, which is what actually goes on-chain
 *  (bytes32 `ipfsHash` in AgentIntent) — cheap, and lets anyone independently verify the
 *  agent's reasoning and inputs after the fact. */
async function pinRationale(
  vault: Address,
  rationale: string,
  snapshot: MarketSnapshot
): Promise<`0x${string}`> {
  // Swap for a real IPFS/Arweave client. Returning a deterministic placeholder here keeps
  // this skeleton runnable without external network access.
  const payload = JSON.stringify({ vault, rationale, timestamp: snapshot.timestamp });
  const { keccak256, toBytes } = await import("viem");
  return keccak256(toBytes(payload));
}

export { USDC };
