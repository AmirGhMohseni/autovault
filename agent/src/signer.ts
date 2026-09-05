import { type Address, type Hex, type WalletClient } from "viem";
import type { AgentIntent } from "./types.js";

/**
 * Signs an AgentIntent per the AgentExecutor.sol EIP-712 domain/types. In production the
 * `walletClient`'s account is backed by an MPC/HSM signer (e.g. Turnkey, Fireblocks) —
 * this file only needs the standard viem WalletClient interface, so swapping the key
 * management backend does not require touching this code. See docs/SPEC.md §4.3 for the
 * hot-key/cold-key containment model.
 */

const TRADE_TYPE = [
  { name: "tokenIn", type: "address" },
  { name: "tokenOut", type: "address" },
  { name: "amountIn", type: "uint256" },
  { name: "minAmountOut", type: "uint256" },
  { name: "routerCalldata", type: "bytes" },
] as const;

const INTENT_TYPE = [
  { name: "vault", type: "address" },
  { name: "trades", type: "TradeInstruction[]" },
  { name: "maxSlippageBps", type: "uint256" },
  { name: "ipfsHash", type: "bytes32" },
  { name: "nonce", type: "uint256" },
  { name: "expiry", type: "uint256" },
] as const;

export async function signIntent(
  walletClient: WalletClient,
  agentExecutorAddress: Address,
  chainId: number,
  intent: AgentIntent
): Promise<Hex> {
  const account = walletClient.account;
  if (!account) throw new Error("wallet client has no account configured");

  return walletClient.signTypedData({
    account,
    domain: {
      name: "AutoVaultAgentExecutor",
      version: "1",
      chainId,
      verifyingContract: agentExecutorAddress,
    },
    types: {
      TradeInstruction: TRADE_TYPE,
      AgentIntent: INTENT_TYPE,
    },
    primaryType: "AgentIntent",
    message: {
      vault: intent.vault,
      trades: intent.trades,
      maxSlippageBps: intent.maxSlippageBps,
      ipfsHash: intent.ipfsHash,
      nonce: intent.nonce,
      expiry: intent.expiry,
    },
  });
}
