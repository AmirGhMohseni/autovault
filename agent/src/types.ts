import type { Address, Hex } from "viem";

/** Mirrors AutoVaultTypes.TradeInstruction in IAutoVaultTypes.sol */
export interface TradeInstruction {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  minAmountOut: bigint;
  routerCalldata: Hex; // pre-quoted calldata for SwapRouterAdapter's allowlisted target
}

/** Mirrors AutoVaultTypes.AgentIntent in IAutoVaultTypes.sol */
export interface AgentIntent {
  vault: Address;
  trades: TradeInstruction[];
  maxSlippageBps: bigint;
  ipfsHash: Hex; // hash of the rationale + inputs snapshot, pinned off-chain
  nonce: bigint;
  expiry: bigint;
}

/** A compiled, machine-readable strategy — either a curated preset or the output of the
 *  natural-language compiler (see llm/compileStrategy.ts). The quant optimizer only ever
 *  consumes this typed shape; it never sees raw user text. */
export interface StrategySpec {
  vault: Address;
  type: "curated" | "personalized";
  universe: Address[]; // must be a subset of the on-chain TokenizedStockRegistry allowlist
  excludeFlags?: string[]; // e.g. "china_domiciled" — checked against registry metadata off-chain
  method: "risk_parity" | "mean_variance" | "black_litterman" | "equal_weight";
  constraints: {
    maxPositionBps: number;
    maxSectorBps: number;
    targetAnnualizedVolMax?: number;
    rebalanceThresholdBps: number;
    maxSlippageBps: number;
  };
}

export interface MarketSnapshot {
  timestamp: number;
  prices: Record<Address, number>; // USD, off-chain reference (cross-checked vs on-chain oracle before signing)
  returns: Record<Address, number[]>; // recent daily returns per token, for the optimizer
  sector: Record<Address, string>;
}

export interface TargetWeights {
  weightsBps: Record<Address, number>; // sums to <= 10_000; remainder is idle USDC
  rationale: string; // human-readable, shown in the dashboard, hash-anchored via ipfsHash
}
