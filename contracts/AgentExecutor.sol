// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IAutoVaultTypes.sol";

interface IExecVault {
    function asset() external view returns (address);
    function executeRebalance(AutoVaultTypes.TradeInstruction[] calldata trades, bytes32 ipfsHash) external;
}

interface IExecSwapRouter {
    function swap(
        address target,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapCalldata
    ) external returns (uint256 amountOut);
}

/// @title AgentExecutor
/// @notice The single on-chain entry point for the off-chain AI agent. Verifies the agent's EIP-712
///         signature over an `AgentIntent`, re-validates every trade against `RiskManager`, pulls the
///         vault's tokens through the allowlisted `SwapRouterAdapter`, and only then calls
///         `AIFundVault.executeRebalance` to update accounting. This is the *only* contract in the
///         protocol that holds `EXECUTOR_ROLE` on both the vault and the router — the agent itself
///         never holds a role or custody of any kind, it only produces signatures.
contract AgentExecutor is AccessControl, EIP712 {
    using ECDSA for bytes32;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    // keccak256("TradeInstruction(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,bytes routerCalldata)")
    bytes32 private constant TRADE_TYPEHASH =
        keccak256(
            "TradeInstruction(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,bytes routerCalldata)"
        );

    // keccak256("AgentIntent(address vault,TradeInstruction[] trades,uint256 maxSlippageBps,bytes32 ipfsHash,uint256 nonce,uint256 expiry)TradeInstruction(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,bytes routerCalldata)")
    bytes32 private constant INTENT_TYPEHASH =
        keccak256(
            "AgentIntent(address vault,TradeInstruction[] trades,uint256 maxSlippageBps,bytes32 ipfsHash,uint256 nonce,uint256 expiry)TradeInstruction(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,bytes routerCalldata)"
        );

    IRiskManager public immutable riskManager;
    IExecSwapRouter public immutable swapRouter;
    address public immutable swapTarget; // the specific aggregator router address quotes are built for

    mapping(address => bool) public isAgent; // authorized signer(s); rotatable by governance
    mapping(address => mapping(uint256 => bool)) public usedNonce; // vault => nonce => used

    event AgentAuthorized(address indexed agent, bool authorized);
    event IntentExecuted(address indexed vault, bytes32 ipfsHash, uint256 nonce, uint256 tradesCount);

    constructor(
        address admin,
        IRiskManager riskManager_,
        IExecSwapRouter swapRouter_,
        address swapTarget_
    ) EIP712("AutoVaultAgentExecutor", "1") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        riskManager = riskManager_;
        swapRouter = swapRouter_;
        swapTarget = swapTarget_;
    }

    /// @notice Rotates which off-chain signer(s) are trusted. Timelocked in production (GOVERNOR_ROLE
    ///         held by the governance TimelockController), so a compromised agent hot key can be
    ///         revoked quickly by governance while a *new* key can only be added after the delay.
    function setAgent(address agent, bool authorized) external onlyRole(GOVERNOR_ROLE) {
        isAgent[agent] = authorized;
        emit AgentAuthorized(agent, authorized);
    }

    /// @notice Verifies the agent's signature, re-checks every trade against RiskManager, executes each
    ///         swap through the allowlisted router, and finally reports the results into the vault for
    ///         NAV accounting. Callable by anyone holding a validly-signed intent (permissionless
    ///         relaying) — the security boundary is the signature + on-chain checks, not caller identity.
    function submitIntent(
        AutoVaultTypes.AgentIntent calldata intent,
        bytes calldata agentSig
    ) external {
        require(block.timestamp <= intent.expiry, "intent expired");
        require(!usedNonce[intent.vault][intent.nonce], "nonce used");

        address signer = _recoverSigner(intent, agentSig);
        require(isAgent[signer], "not an authorized agent");

        usedNonce[intent.vault][intent.nonce] = true;

        for (uint256 i = 0; i < intent.trades.length; i++) {
            AutoVaultTypes.TradeInstruction calldata t = intent.trades[i];

            (bool ok, string memory reason) = riskManager.validateTrade(
                intent.vault,
                t.tokenIn,
                t.tokenOut,
                t.amountIn,
                t.minAmountOut
            );
            require(ok, reason);

            // Pull tokenIn from the vault, execute through the allowlisted router, deliver tokenOut
            // back to the vault. The vault must have pre-approved this contract (or the router pulls
            // directly with vault-granted allowance) — production wiring grants AgentExecutor a
            // spend allowance scoped per-rebalance via `permit`/`approve` in the same tx bundle.
            swapRouter.swap(swapTarget, t.tokenIn, t.tokenOut, t.amountIn, t.minAmountOut, t.routerCalldata);

            uint256 notionalUsd = t.amountIn; // simplified; production converts via PriceOracleAdapter
            riskManager.recordTurnover(intent.vault, notionalUsd);
        }

        IExecVault(intent.vault).executeRebalance(intent.trades, intent.ipfsHash);

        emit IntentExecuted(intent.vault, intent.ipfsHash, intent.nonce, intent.trades.length);
    }

    function _recoverSigner(AutoVaultTypes.AgentIntent calldata intent, bytes calldata sig)
        internal
        view
        returns (address)
    {
        bytes32[] memory tradeHashes = new bytes32[](intent.trades.length);
        for (uint256 i = 0; i < intent.trades.length; i++) {
            AutoVaultTypes.TradeInstruction calldata t = intent.trades[i];
            tradeHashes[i] = keccak256(
                abi.encode(
                    TRADE_TYPEHASH,
                    t.tokenIn,
                    t.tokenOut,
                    t.amountIn,
                    t.minAmountOut,
                    keccak256(t.routerCalldata)
                )
            );
        }

        bytes32 structHash = keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.vault,
                keccak256(abi.encodePacked(tradeHashes)),
                intent.maxSlippageBps,
                intent.ipfsHash,
                intent.nonce,
                intent.expiry
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        return digest.recover(sig);
    }
}
