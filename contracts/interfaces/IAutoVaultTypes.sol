// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared structs/enums used across the AutoVault protocol.
library AutoVaultTypes {
    struct TradeInstruction {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes routerCalldata; // pre-quoted calldata for SwapRouterAdapter
    }

    struct AgentIntent {
        address vault;
        TradeInstruction[] trades;
        uint256 maxSlippageBps;
        bytes32 ipfsHash; // rationale + inputs snapshot
        uint256 nonce;
        uint256 expiry;
    }
}

interface IPriceOracle {
    /// @return price 18-decimal USD price of `token`
    /// @return updatedAt timestamp of last update
    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt);
}

interface IRiskManager {
    function validateTrade(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external view returns (bool ok, string memory reason);

    function validatePostTradeExposure(address vault) external view returns (bool ok, string memory reason);

    function remainingDailyTurnover(address vault) external view returns (uint256 remainingBps);

    function recordTurnover(address vault, uint256 notionalUsd) external;
}

interface IFeeModule {
    function accrue(address vault) external returns (uint256 mgmtShares, uint256 perfShares);
}

interface ITokenizedStockRegistry {
    struct StockInfo {
        bool active;
        bytes32 sector;
        bool chinaLinked;
        uint8 decimals;
    }

    function isActive(address stock) external view returns (bool);
    function getInfo(address stock) external view returns (StockInfo memory);
}
