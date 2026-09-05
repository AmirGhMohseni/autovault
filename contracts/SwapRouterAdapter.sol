// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapRouterAdapter
/// @notice Thin, allowlisted wrapper around external DEX aggregators (0x / 1inch / Base-native routers).
///         Never holds funds between calls; always pulls exact `amountIn` from the caller (AgentExecutor)
///         and enforces `minAmountOut` itself, independent of whatever the aggregator claims.
contract SwapRouterAdapter is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant CALLER_ROLE = keccak256("CALLER_ROLE"); // AgentExecutor

    mapping(address => bool) public allowlistedTarget; // approved aggregator router contracts

    event TargetAllowlisted(address indexed target, bool allowed);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function setAllowlistedTarget(address target, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        allowlistedTarget[target] = allowed;
        emit TargetAllowlisted(target, allowed);
    }

    /// @param target must be a governance-allowlisted aggregator router contract
    /// @param swapCalldata pre-quoted calldata built off-chain by the agent for `target`
    function swap(
        address target,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapCalldata
    ) external onlyRole(CALLER_ROLE) returns (uint256 amountOut) {
        require(allowlistedTarget[target], "target not allowlisted");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(target, amountIn);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        (bool ok, ) = target.call(swapCalldata);
        require(ok, "swap call failed");
        uint256 outAfter = IERC20(tokenOut).balanceOf(address(this));

        amountOut = outAfter - outBefore;
        require(amountOut >= minAmountOut, "slippage: minOut not met");

        IERC20(tokenIn).forceApprove(target, 0); // revoke residual approval
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }
}
