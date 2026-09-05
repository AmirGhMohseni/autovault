import { z } from "zod";
import type { Address } from "viem";
import type { StrategySpec } from "../types.js";

/**
 * Compiles a user's free-text preference into a StrategySpec via constrained
 * function-calling. The model is NEVER allowed to emit portfolio weights directly — only
 * this typed schema, which the quant optimizer (optimizer.ts) then consumes. This keeps
 * the actual allocation decision deterministic and auditable; the LLM's role is strictly
 * translation + a human-readable rationale, matching docs/SPEC.md §11.
 *
 * This file is a skeleton: swap `callLLM` for your actual provider call (Anthropic/OpenAI
 * function-calling), keeping the same strict output schema.
 */

const StrategySpecSchema = z.object({
  includeSectors: z.array(z.string()),
  excludeFlags: z.array(z.string()),
  method: z.enum(["risk_parity", "mean_variance", "black_litterman", "equal_weight"]),
  targetAnnualizedVolMax: z.number().min(0).max(2).optional(),
  maxPositionBps: z.number().int().min(100).max(2500), // hard-clamped to on-chain HARD_MAX below anyway
  maxSectorBps: z.number().int().min(500).max(5000),
  rebalanceThresholdBps: z.number().int().min(50).max(2000),
  maxSlippageBps: z.number().int().min(10).max(300),
});

export type LLMStrategyOutput = z.infer<typeof StrategySpecSchema>;

// Mirrors RiskManager on-chain absolute bounds — the compiler clamps to these even if the
// governance-set per-vault params happen to be looser, and the contract re-checks anyway.
const HARD_MAX_POSITION_BPS = 2500;
const HARD_MAX_SECTOR_BPS = 5000;
const HARD_MAX_SLIPPAGE_BPS = 300;

export interface UniverseIndex {
  bySector: Record<string, Address[]>;
  chinaDomiciled: Set<Address>;
  all: Address[];
}

export async function compileStrategy(
  vault: Address,
  userText: string,
  universe: UniverseIndex,
  callLLM: (prompt: string) => Promise<unknown>
): Promise<{ spec: StrategySpec; clarifyingQuestion?: string }> {
  const raw = await callLLM(buildPrompt(userText));
  const parsed = StrategySpecSchema.safeParse(raw);

  if (!parsed.success) {
    return {
      spec: fallbackSpec(vault, universe),
      clarifyingQuestion:
        "I couldn't map that to a valid strategy — could you clarify which sectors or exclusions you want?",
    };
  }

  const out = parsed.data;

  // Resolve sector names -> on-chain-listed token addresses. Nothing outside the registry
  // allowlist can ever enter `universe`, regardless of what the model returned.
  let tokens = out.includeSectors.flatMap((s) => universe.bySector[s] ?? []);
  if (tokens.length === 0) tokens = universe.all; // no sector filter matched -> full allowlist

  if (out.excludeFlags.includes("china_domiciled") || out.excludeFlags.includes("china_linked")) {
    tokens = tokens.filter((t) => !universe.chinaDomiciled.has(t));
  }

  const spec: StrategySpec = {
    vault,
    type: "personalized",
    universe: [...new Set(tokens)],
    excludeFlags: out.excludeFlags,
    method: out.method,
    constraints: {
      maxPositionBps: Math.min(out.maxPositionBps, HARD_MAX_POSITION_BPS),
      maxSectorBps: Math.min(out.maxSectorBps, HARD_MAX_SECTOR_BPS),
      targetAnnualizedVolMax: out.targetAnnualizedVolMax,
      rebalanceThresholdBps: out.rebalanceThresholdBps,
      maxSlippageBps: Math.min(out.maxSlippageBps, HARD_MAX_SLIPPAGE_BPS),
    },
  };

  if (spec.universe.length === 0) {
    return {
      spec: fallbackSpec(vault, universe),
      clarifyingQuestion:
        "None of the currently listed tokenized stocks match your criteria — want to broaden the sectors or exclusions?",
    };
  }

  return { spec };
}

function fallbackSpec(vault: Address, universe: UniverseIndex): StrategySpec {
  return {
    vault,
    type: "personalized",
    universe: universe.all,
    method: "equal_weight",
    constraints: {
      maxPositionBps: 1000,
      maxSectorBps: 3500,
      rebalanceThresholdBps: 300,
      maxSlippageBps: 75,
    },
  };
}

function buildPrompt(userText: string): string {
  return [
    "You are a strategy compiler for a tokenized-equity index vault.",
    "Translate the user's request into ONLY the JSON fields of the provided schema.",
    "Never output portfolio weights or specific dollar amounts — only sector filters,",
    "exclusion flags, an optimization method, and risk-constraint numbers.",
    "If the request implies a value outside allowed bounds, clamp it and note that in",
    "your reasoning (reasoning is discarded; only the JSON schema fields are used).",
    "",
    `User request: """${userText}"""`,
  ].join("\n");
}
