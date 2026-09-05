// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAutoVaultTypes.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title AIFundVault
/// @notice ERC-4626 vault representing one AI-managed, isolated fund. Holds idle USDC + a basket of
///         Coinbase-issued tokenized stocks. Deposits/withdrawals are trustless ERC-4626 mechanics;
///         portfolio composition is only ever changed via `executeRebalance`, callable exclusively by the
///         governance-appointed `AgentExecutor`, and every trade is re-validated by `RiskManager`.
contract AIFundVault is ERC4626, ERC20Permit, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AutoVaultTypes for AutoVaultTypes.TradeInstruction;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE"); // AgentExecutor contract
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE"); // timelock

    IRiskManager public immutable riskManager;
    IFeeModule public immutable feeModule;
    ITokenizedStockRegistry public immutable stockRegistry;
    IPriceOracle public immutable priceOracle;

    mapping(address => uint256) public holdings; // stock => amount held
    address[] public holdingsList;
    mapping(address => bool) private _isHolding;

    uint256 public depositCap;
    uint256 public perBlockDepositCap;
    mapping(uint256 => uint256) private _depositedThisBlock; // block.number => amount

    uint256 public constant MIN_IDLE_BPS = 200; // 2% NAV minimum idle cash buffer target (soft, agent-respected)

    event RebalanceExecuted(bytes32 indexed ipfsHash, uint256 tradesCount, uint256 navBefore, uint256 navAfter);
    event NAVUpdated(uint256 nav, uint256 sharePrice18);
    event WithdrawalQueued(address indexed user, uint256 shares);
    event CapsUpdated(uint256 depositCap, uint256 perBlockDepositCap);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin,
        IRiskManager riskManager_,
        IFeeModule feeModule_,
        ITokenizedStockRegistry registry_,
        IPriceOracle oracle_,
        uint256 depositCap_,
        uint256 perBlockDepositCap_
    ) ERC4626(asset_) ERC20(name_, symbol_) ERC20Permit(name_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);

        riskManager = riskManager_;
        feeModule = feeModule_;
        stockRegistry = registry_;
        priceOracle = oracle_;
        depositCap = depositCap_;
        perBlockDepositCap = perBlockDepositCap_;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 overrides: NAV must include tokenized stock holdings, not just idle asset balance.
    // ---------------------------------------------------------------------

    function totalAssets() public view override returns (uint256) {
        return totalNAV();
    }

    /// @notice Sum of idle USDC + USD value of all tokenized stock holdings, expressed in `asset` decimals.
    function totalNAV() public view returns (uint256 nav) {
        nav = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < holdingsList.length; i++) {
            nav += holdingValueUsd(holdingsList[i]);
        }
    }

    function holdingValueUsd(address stock) public view returns (uint256) {
        uint256 amount = holdings[stock];
        if (amount == 0) return 0;
        (uint256 price18, ) = priceOracle.getPrice(stock);
        return (amount * price18) / 1e18;
    }

    function sectorValueUsd(bytes32 sector) external view returns (uint256 total) {
        for (uint256 i = 0; i < holdingsList.length; i++) {
            address s = holdingsList[i];
            if (stockRegistry.getInfo(s).sector == sector) {
                total += holdingValueUsd(s);
            }
        }
    }

    function registry() external view returns (ITokenizedStockRegistry) {
        return stockRegistry;
    }

    function sharePrice18() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        uint8 assetDecimals = IERC20Metadata(asset()).decimals();
        uint8 shareDecimals = decimals();
        return (totalNAV() * (10 ** shareDecimals) * 1e18) / (supply * (10 ** assetDecimals));
    }

    // OZ ERC-4626 decimals offset mitigates first-depositor / donation share-price manipulation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    // ---------------------------------------------------------------------
    // Deposit / withdraw guards
    // ---------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        require(totalNAV() + assets <= depositCap, "deposit cap exceeded");
        _depositedThisBlock[block.number] += assets;
        require(_depositedThisBlock[block.number] <= perBlockDepositCap, "per-block cap exceeded");
        return super.deposit(assets, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) {
            emit WithdrawalQueued(owner_, previewWithdraw(assets));
            revert("insufficient idle cash: use requestProRataLiquidation via keeper");
        }
        return super.withdraw(assets, receiver, owner_);
    }

    /// @notice Permissionless pro-rata liquidation: sells an equal percentage slice of every holding to
    ///         raise cash for pending redemptions. Never selective, so the agent/executor cannot be gamed
    ///         into favoring or disadvantaging any particular exit.
    function proRataLiquidate(
        uint256 bpsOfEachHolding,
        address swapRouter,
        bytes[] calldata swapCalldatas
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        require(bpsOfEachHolding <= 10_000, "bad bps");
        require(swapCalldatas.length == holdingsList.length, "length mismatch");
        // Execution detail (router calls, min-out enforcement) mirrors executeRebalance below; omitted
        // here for brevity — implemented via the same SwapRouterAdapter.swap() path per holding.
        swapRouter; // silence unused-var warning in this illustrative excerpt
    }

    // ---------------------------------------------------------------------
    // Agent-driven rebalancing
    // ---------------------------------------------------------------------

    /// @notice Called only by AgentExecutor after it has verified the agent's EIP-712 signature and run
    ///         RiskManager.validateTrade on every individual trade. This function performs the actual
    ///         token accounting and a final aggregate post-trade exposure check as defense in depth.
    function executeRebalance(
        AutoVaultTypes.TradeInstruction[] calldata trades,
        bytes32 ipfsHash
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        uint256 navBefore = totalNAV();

        for (uint256 i = 0; i < trades.length; i++) {
            AutoVaultTypes.TradeInstruction calldata t = trades[i];

            (bool ok, string memory reason) = riskManager.validateTrade(
                address(this),
                t.tokenIn,
                t.tokenOut,
                t.amountIn,
                t.minAmountOut
            );
            require(ok, reason);

            require(t.tokenIn == asset() || stockRegistry.isActive(t.tokenIn), "tokenIn not allowed");
            require(t.tokenOut == asset() || stockRegistry.isActive(t.tokenOut), "tokenOut not allowed");

            // Actual transfer/swap execution happens through SwapRouterAdapter, called by AgentExecutor,
            // which then reports back updated balances here. In this simplified interface, AgentExecutor
            // is trusted to have already moved tokens in/out of this vault atomically before calling
            // executeRebalance to update accounting — production implementation combines both into a
            // single external call from AgentExecutor for atomicity.
            _updateHolding(t.tokenOut);
            _updateHolding(t.tokenIn);
        }

        (bool exposureOk, string memory exposureReason) = riskManager.validatePostTradeExposure(address(this));
        require(exposureOk, exposureReason);

        uint256 navAfter = totalNAV();
        emit RebalanceExecuted(ipfsHash, trades.length, navBefore, navAfter);
        emit NAVUpdated(navAfter, this.sharePrice18());
    }

    function _updateHolding(address token) internal {
        if (token == asset()) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        holdings[token] = bal;
        if (bal > 0 && !_isHolding[token]) {
            _isHolding[token] = true;
            holdingsList.push(token);
        } else if (bal == 0 && _isHolding[token]) {
            _isHolding[token] = false;
            _removeFromHoldingsList(token);
        }
    }

    function _removeFromHoldingsList(address token) internal {
        uint256 len = holdingsList.length;
        for (uint256 i = 0; i < len; i++) {
            if (holdingsList[i] == token) {
                holdingsList[i] = holdingsList[len - 1];
                holdingsList.pop();
                break;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Fees
    // ---------------------------------------------------------------------

    function mintFeeShares(address to, uint256 shares) external {
        require(msg.sender == address(feeModule), "only fee module");
        _mint(to, shares);
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function setCaps(uint256 depositCap_, uint256 perBlockDepositCap_) external onlyRole(GOVERNOR_ROLE) {
        depositCap = depositCap_;
        perBlockDepositCap = perBlockDepositCap_;
        emit CapsUpdated(depositCap_, perBlockDepositCap_);
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }
}
