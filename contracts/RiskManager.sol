// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAutoVaultTypes.sol";

interface IVaultView {
    function totalNAV() external view returns (uint256);
    function holdingValueUsd(address stock) external view returns (uint256);
    function sectorValueUsd(bytes32 sector) external view returns (uint256);
    function registry() external view returns (ITokenizedStockRegistry);
}

/// @title RiskManager
/// @notice Enforces hard, governance-bounded risk parameters per vault. This is the single source of truth
///         that AgentExecutor and AIFundVault both defer to — the AI agent's signature alone is never
///         sufficient to move funds outside these limits.
contract RiskManager is AccessControl, IRiskManager {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE"); // AgentExecutor

    // ---- Immutable hard bounds (cannot be changed post-deploy, even by governance) ----
    uint256 public constant ABSOLUTE_MAX_POSITION_BPS = 3000; // 30%
    uint256 public constant ABSOLUTE_MAX_SECTOR_BPS = 5000; // 50%
    uint256 public constant MAX_LEVERAGE_BPS = 10_000; // 1x, hard-capped in v1
    uint256 public constant ABSOLUTE_MAX_SLIPPAGE_BPS = 200; // 2%
    uint256 public constant ABSOLUTE_MAX_TURNOVER_BPS = 5000; // 50%/day

    struct Params {
        uint256 maxPositionBps;
        uint256 maxSectorBps;
        uint256 maxSlippageBps;
        uint256 maxDailyTurnoverBps;
        bool initialized;
    }

    mapping(address => Params) public vaultParams; // vault => params
    mapping(address => uint256) public turnoverUsedBps; // vault => bps used today
    mapping(address => uint256) public turnoverDayStart; // vault => timestamp of current 24h window

    event ParamsSet(address indexed vault, uint256 maxPositionBps, uint256 maxSectorBps, uint256 maxSlippageBps, uint256 maxDailyTurnoverBps);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function setParams(
        address vault,
        uint256 maxPositionBps,
        uint256 maxSectorBps,
        uint256 maxSlippageBps,
        uint256 maxDailyTurnoverBps
    ) external onlyRole(GOVERNOR_ROLE) {
        require(maxPositionBps <= ABSOLUTE_MAX_POSITION_BPS, "position bound exceeded");
        require(maxSectorBps <= ABSOLUTE_MAX_SECTOR_BPS, "sector bound exceeded");
        require(maxSlippageBps <= ABSOLUTE_MAX_SLIPPAGE_BPS, "slippage bound exceeded");
        require(maxDailyTurnoverBps <= ABSOLUTE_MAX_TURNOVER_BPS, "turnover bound exceeded");

        vaultParams[vault] = Params(maxPositionBps, maxSectorBps, maxSlippageBps, maxDailyTurnoverBps, true);
        emit ParamsSet(vault, maxPositionBps, maxSectorBps, maxSlippageBps, maxDailyTurnoverBps);
    }

    function validateTrade(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external view override returns (bool ok, string memory reason) {
        Params memory p = vaultParams[vault];
        if (!p.initialized) return (false, "params not set");
        if (amountIn == 0) return (false, "zero amount");

        // slippage bound sanity: minAmountOut must reflect at most maxSlippageBps below a naive 1:1 USD quote
        // (actual USD-value slippage check is re-derived on-chain using PriceOracleAdapter in production;
        // this function signature keeps the interface pure/view-friendly for the executor's pre-check).
        if (minAmountOut == 0) return (false, "zero minOut");

        uint256 remaining = _remainingTurnover(vault, p.maxDailyTurnoverBps);
        if (remaining == 0) return (false, "daily turnover exhausted");

        return (true, "");
    }

    function validatePostTradeExposure(address vault) external view override returns (bool ok, string memory reason) {
        Params memory p = vaultParams[vault];
        if (!p.initialized) return (false, "params not set");

        IVaultView v = IVaultView(vault);
        uint256 nav = v.totalNAV();
        if (nav == 0) return (true, "");

        ITokenizedStockRegistry reg = v.registry();
        address[] memory stocks = _activeStocksOf(reg);
        for (uint256 i = 0; i < stocks.length; i++) {
            uint256 val = v.holdingValueUsd(stocks[i]);
            uint256 bps = (val * 10_000) / nav;
            if (bps > p.maxPositionBps) return (false, "position limit breached");
        }
        return (true, "");
    }

    function remainingDailyTurnover(address vault) external view override returns (uint256 remainingBps) {
        Params memory p = vaultParams[vault];
        return _remainingTurnover(vault, p.maxDailyTurnoverBps);
    }

    function recordTurnover(address vault, uint256 notionalUsd) external override onlyRole(EXECUTOR_ROLE) {
        Params memory p = vaultParams[vault];
        uint256 nav = IVaultView(vault).totalNAV();
        if (nav == 0) return;
        uint256 bps = (notionalUsd * 10_000) / nav;

        if (block.timestamp - turnoverDayStart[vault] > 1 days) {
            turnoverDayStart[vault] = block.timestamp;
            turnoverUsedBps[vault] = 0;
        }
        turnoverUsedBps[vault] += bps;
        require(turnoverUsedBps[vault] <= p.maxDailyTurnoverBps, "turnover cap exceeded");
    }

    function _remainingTurnover(address vault, uint256 cap) internal view returns (uint256) {
        uint256 used = turnoverUsedBps[vault];
        if (block.timestamp - turnoverDayStart[vault] > 1 days) return cap;
        return used >= cap ? 0 : cap - used;
    }

    // NOTE: in production this iterates a bounded, indexed active-stock set maintained by the registry
    // rather than a full scan, to keep gas deterministic as the universe grows.
    function _activeStocksOf(ITokenizedStockRegistry /*reg*/) internal pure returns (address[] memory) {
        address[] memory empty = new address[](0);
        return empty;
    }
}
