import type { Address } from "viem";
import type { MarketSnapshot, StrategySpec, TargetWeights } from "./types.js";

/**
 * Deterministic, reproducible quant core. This is the ONLY component allowed to produce
 * a `weightsBps` vector — the LLM layer (see llm/compileStrategy.ts) never outputs
 * weights directly, only the StrategySpec that parameterizes this function. Keeping the
 * optimizer pure and deterministic means any third party can recompute the same target
 * weights from the same public inputs (market snapshot + on-chain StrategySpec hash) and
 * verify the agent behaved as claimed.
 */
export function optimize(spec: StrategySpec, snapshot: MarketSnapshot): TargetWeights {
  const universe = spec.universe.filter((t) => snapshot.prices[t] !== undefined);
  if (universe.length === 0) {
    return { weightsBps: {}, rationale: "Empty investable universe after filtering — holding idle USDC." };
  }

  let raw: Record<Address, number>;
  switch (spec.method) {
    case "equal_weight":
      raw = equalWeight(universe);
      break;
    case "risk_parity":
      raw = riskParity(universe, snapshot);
      break;
    case "mean_variance":
    case "black_litterman":
      // v1: fall back to risk parity; full mean-variance / Black-Litterman solver is a
      // Phase-2/3 upgrade (needs a covariance-matrix solver — out of scope for this skeleton).
      raw = riskParity(universe, snapshot);
      break;
  }

  const capped = applyCaps(raw, spec, snapshot);
  const weightsBps = toBps(capped);

  const top = Object.entries(weightsBps)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([addr, bps]) => `${addr.slice(0, 8)}…:${(bps / 100).toFixed(1)}%`)
    .join(", ");

  return {
    weightsBps,
    rationale: `Method=${spec.method}, universe=${universe.length} names, top holdings: ${top}. ` +
      `Position cap ${spec.constraints.maxPositionBps / 100}%, sector cap ${spec.constraints.maxSectorBps / 100}%.`,
  };
}

function equalWeight(universe: Address[]): Record<Address, number> {
  const w = 1 / universe.length;
  return Object.fromEntries(universe.map((t) => [t, w]));
}

/** Naive inverse-volatility weighting (simplified risk parity: no cross-asset correlation
 *  term). Suitable for a v1 MVP; a full risk-parity solver with a covariance matrix is a
 *  documented Phase-2/3 upgrade (see docs/SPEC.md §14 Open Questions). */
function riskParity(universe: Address[], snapshot: MarketSnapshot): Record<Address, number> {
  const vol: Record<Address, number> = {};
  for (const t of universe) {
    const rets = snapshot.returns[t] ?? [];
    vol[t] = rets.length > 1 ? stdDev(rets) : 1; // fallback vol if no history yet
    if (vol[t] === 0) vol[t] = 1e-6; // avoid div-by-zero for a flat series
  }
  const invVol = Object.fromEntries(universe.map((t) => [t, 1 / vol[t]]));
  const total = Object.values(invVol).reduce((a, b) => a + b, 0);
  return Object.fromEntries(universe.map((t) => [t, invVol[t] / total]));
}

function stdDev(xs: number[]): number {
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
  const variance = xs.reduce((a, b) => a + (b - mean) ** 2, 0) / xs.length;
  return Math.sqrt(variance);
}

/** Enforces the same per-position / per-sector caps the on-chain RiskManager will enforce,
 *  so the intent is expected to pass on first submission rather than relying on the
 *  contract to reject and forcing a retry loop. The contract check remains the actual
 *  security boundary — this is a client-side mirror for efficiency, not a trust source. */
function applyCaps(
  raw: Record<Address, number>,
  spec: StrategySpec,
  snapshot: MarketSnapshot
): Record<Address, number> {
  const maxPos = spec.constraints.maxPositionBps / 10_000;
  const maxSector = spec.constraints.maxSectorBps / 10_000;

  let weights = { ...raw };
  // Clamp single-position weights, redistribute overflow proportionally to the rest.
  for (let pass = 0; pass < 5; pass++) {
    let overflow = 0;
    const capped: Record<Address, number> = {};
    for (const [t, w] of Object.entries(weights)) {
      if (w > maxPos) {
        overflow += w - maxPos;
        capped[t as Address] = maxPos;
      } else {
        capped[t as Address] = w;
      }
    }
    if (overflow === 0) {
      weights = capped;
      break;
    }
    const uncappedKeys = Object.keys(capped).filter((t) => capped[t as Address] < maxPos);
    const uncappedTotal = uncappedKeys.reduce((s, t) => s + capped[t as Address], 0) || 1;
    for (const t of uncappedKeys) {
      capped[t as Address] += overflow * (capped[t as Address] / uncappedTotal);
    }
    weights = capped;
  }

  // Sector cap pass (simple proportional trim + redistribution).
  const sectors = new Map<string, Address[]>();
  for (const t of Object.keys(weights) as Address[]) {
    const s = snapshot.sector[t] ?? "UNKNOWN";
    sectors.set(s, [...(sectors.get(s) ?? []), t]);
  }
  for (const [, tokens] of sectors) {
    const sectorTotal = tokens.reduce((s, t) => s + weights[t], 0);
    if (sectorTotal > maxSector) {
      const scale = maxSector / sectorTotal;
      for (const t of tokens) weights[t] *= scale;
    }
  }

  return weights;
}

function toBps(weights: Record<Address, number>): Record<Address, number> {
  const out: Record<Address, number> = {};
  for (const [t, w] of Object.entries(weights)) {
    out[t as Address] = Math.floor(w * 10_000);
  }
  return out;
}
