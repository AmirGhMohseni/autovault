// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAutoVaultTypes.sol";

interface IFeeVault {
    function totalSupply() external view returns (uint256);
    function sharePrice18() external view returns (uint256); // NAV per share, 18 decimals
    function mintFeeShares(address to, uint256 shares) external;
}

/// @title FeeModule
/// @notice Streams management fees continuously and charges performance fees only above a per-vault
///         high-water mark. Fees are paid as newly minted (dilutive) shares — never a forced sale of
///         underlying holdings.
contract FeeModule is AccessControl, IFeeModule {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    uint256 public constant ABSOLUTE_MAX_MGMT_FEE_BPS = 150; // 1.5%/yr
    uint256 public constant ABSOLUTE_MAX_PERF_FEE_BPS = 2000; // 20%
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    struct FeeConfig {
        uint256 managementFeeBps;
        uint256 performanceFeeBps;
        address feeRecipient;
        uint256 lastAccrualTs;
        uint256 hwmPerShare18;
        bool initialized;
    }

    mapping(address => FeeConfig) public configs; // vault => config

    event FeeConfigSet(address indexed vault, uint256 managementFeeBps, uint256 performanceFeeBps, address feeRecipient);
    event FeesAccrued(address indexed vault, uint256 mgmtShares, uint256 perfShares, uint256 newHwm);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function setFeeConfig(
        address vault,
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        address feeRecipient
    ) external onlyRole(GOVERNOR_ROLE) {
        require(managementFeeBps <= ABSOLUTE_MAX_MGMT_FEE_BPS, "mgmt fee bound exceeded");
        require(performanceFeeBps <= ABSOLUTE_MAX_PERF_FEE_BPS, "perf fee bound exceeded");
        require(feeRecipient != address(0), "zero recipient");

        FeeConfig storage c = configs[vault];
        c.managementFeeBps = managementFeeBps;
        c.performanceFeeBps = performanceFeeBps;
        c.feeRecipient = feeRecipient;
        if (!c.initialized) {
            c.lastAccrualTs = block.timestamp;
            c.hwmPerShare18 = 1e18; // starts at 1:1
            c.initialized = true;
        }
        emit FeeConfigSet(vault, managementFeeBps, performanceFeeBps, feeRecipient);
    }

    /// @notice Permissionless — any keeper can trigger accrual to keep the system live without a central operator.
    function accrue(address vault) external override returns (uint256 mgmtShares, uint256 perfShares) {
        FeeConfig storage c = configs[vault];
        require(c.initialized, "not configured");

        IFeeVault v = IFeeVault(vault);
        uint256 supply = v.totalSupply();
        uint256 elapsed = block.timestamp - c.lastAccrualTs;
        c.lastAccrualTs = block.timestamp;

        if (supply == 0) return (0, 0);

        // Management fee: dilutes proportional to time elapsed.
        if (c.managementFeeBps > 0 && elapsed > 0) {
            mgmtShares = (supply * c.managementFeeBps * elapsed) / (10_000 * SECONDS_PER_YEAR);
            if (mgmtShares > 0) v.mintFeeShares(c.feeRecipient, mgmtShares);
        }

        // Performance fee: only on price appreciation above HWM, computed after mgmt fee dilution.
        uint256 price = v.sharePrice18();
        if (c.performanceFeeBps > 0 && price > c.hwmPerShare18) {
            uint256 profitPerShare = price - c.hwmPerShare18;
            uint256 supplyAfterMgmt = v.totalSupply();
            uint256 profitValueUsd = (profitPerShare * supplyAfterMgmt) / 1e18;
            uint256 feeValueUsd = (profitValueUsd * c.performanceFeeBps) / 10_000;
            perfShares = (feeValueUsd * 1e18) / price;
            if (perfShares > 0) v.mintFeeShares(c.feeRecipient, perfShares);
            c.hwmPerShare18 = v.sharePrice18(); // recompute post-mint so fee isn't double-charged
        } else if (price > c.hwmPerShare18) {
            c.hwmPerShare18 = price;
        }

        emit FeesAccrued(vault, mgmtShares, perfShares, c.hwmPerShare18);
    }
}
