// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAutoVaultTypes.sol";

/// @title TokenizedStockRegistry
/// @notice Protocol-wide allowlist of Coinbase-issued tokenized stocks approved for use in AutoVault vaults.
///         Additions/removals are only callable by GOVERNOR_ROLE, which in production is the
///         GovernanceTimelock contract (48h delay) — never an EOA.
contract TokenizedStockRegistry is AccessControl, ITokenizedStockRegistry {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    mapping(address => StockInfo) private _info;
    address[] private _allStocks;

    event StockAdded(address indexed stock, bytes32 sector, bool chinaLinked, uint8 decimals);
    event StockStatusUpdated(address indexed stock, bool active);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function addStock(
        address stock,
        bytes32 sector,
        bool chinaLinked,
        uint8 decimals
    ) external onlyRole(GOVERNOR_ROLE) {
        require(stock != address(0), "zero address");
        require(!_info[stock].active, "already registered");

        _info[stock] = StockInfo({active: true, sector: sector, chinaLinked: chinaLinked, decimals: decimals});
        _allStocks.push(stock);

        emit StockAdded(stock, sector, chinaLinked, decimals);
    }

    function setActive(address stock, bool active) external onlyRole(GOVERNOR_ROLE) {
        require(_info[stock].decimals != 0 || _info[stock].active, "not registered");
        _info[stock].active = active;
        emit StockStatusUpdated(stock, active);
    }

    function isActive(address stock) external view override returns (bool) {
        return _info[stock].active;
    }

    function getInfo(address stock) external view override returns (StockInfo memory) {
        return _info[stock];
    }

    function allStocks() external view returns (address[] memory) {
        return _allStocks;
    }
}
