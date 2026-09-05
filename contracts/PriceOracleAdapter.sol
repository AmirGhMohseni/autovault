// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAutoVaultTypes.sol";

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title PriceOracleAdapter
/// @notice Normalizes Chainlink (primary) + a secondary feed to 18-decimal USD prices, with staleness
///         and deviation checks used by CircuitBreaker / RiskManager.
contract PriceOracleAdapter is AccessControl, IPriceOracle {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    struct FeedConfig {
        address primary;
        address secondary; // address(0) if none configured
        uint256 maxStaleness; // seconds
        uint256 maxDeviationBps; // allowed divergence between primary/secondary before trip
    }

    mapping(address => FeedConfig) public feeds; // token => feed config
    mapping(address => bool) public tripped; // token => circuit tripped (stale/deviated)

    event FeedConfigured(address indexed token, address primary, address secondary, uint256 maxStaleness, uint256 maxDeviationBps);
    event CircuitTripped(address indexed token, string reason);
    event CircuitReset(address indexed token);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function configureFeed(
        address token,
        address primary,
        address secondary,
        uint256 maxStaleness,
        uint256 maxDeviationBps
    ) external onlyRole(GOVERNOR_ROLE) {
        feeds[token] = FeedConfig(primary, secondary, maxStaleness, maxDeviationBps);
        emit FeedConfigured(token, primary, secondary, maxStaleness, maxDeviationBps);
    }

    /// @dev Governance-only manual reset after investigating a trip (e.g. feed operator resolved outage).
    function resetCircuit(address token) external onlyRole(GOVERNOR_ROLE) {
        tripped[token] = false;
        emit CircuitReset(token);
    }

    function getPrice(address token) external view override returns (uint256 price, uint256 updatedAt) {
        require(!tripped[token], "oracle: circuit tripped");
        FeedConfig memory cfg = feeds[token];
        require(cfg.primary != address(0), "oracle: not configured");

        (uint256 pPrice, uint256 pUpdatedAt) = _readFeed(cfg.primary);
        require(block.timestamp - pUpdatedAt <= cfg.maxStaleness, "oracle: stale");

        if (cfg.secondary != address(0)) {
            (uint256 sPrice, uint256 sUpdatedAt) = _readFeed(cfg.secondary);
            require(block.timestamp - sUpdatedAt <= cfg.maxStaleness, "oracle: secondary stale");
            uint256 diff = pPrice > sPrice ? pPrice - sPrice : sPrice - pPrice;
            uint256 deviationBps = (diff * 10_000) / pPrice;
            require(deviationBps <= cfg.maxDeviationBps, "oracle: deviation too high");
        }

        return (pPrice, pUpdatedAt);
    }

    /// @dev Permissionless — anyone can call to record a trip on-chain if conditions are met; this lets
    ///      keepers/monitoring bots halt trading fast without waiting on governance.
    function checkAndTrip(address token) external {
        FeedConfig memory cfg = feeds[token];
        require(cfg.primary != address(0), "oracle: not configured");

        (uint256 pPrice, uint256 pUpdatedAt) = _readFeed(cfg.primary);

        if (block.timestamp - pUpdatedAt > cfg.maxStaleness) {
            tripped[token] = true;
            emit CircuitTripped(token, "stale");
            return;
        }

        if (cfg.secondary != address(0)) {
            (uint256 sPrice, ) = _readFeed(cfg.secondary);
            uint256 diff = pPrice > sPrice ? pPrice - sPrice : sPrice - pPrice;
            uint256 deviationBps = (diff * 10_000) / pPrice;
            if (deviationBps > cfg.maxDeviationBps) {
                tripped[token] = true;
                emit CircuitTripped(token, "deviation");
            }
        }
    }

    function _readFeed(address feed) internal view returns (uint256 price18, uint256 updatedAt) {
        IChainlinkAggregator agg = IChainlinkAggregator(feed);
        (, int256 answer, , uint256 ua, ) = agg.latestRoundData();
        require(answer > 0, "oracle: bad answer");
        uint8 dec = agg.decimals();
        price18 = dec <= 18 ? uint256(answer) * (10 ** (18 - dec)) : uint256(answer) / (10 ** (dec - 18));
        updatedAt = ua;
    }
}
