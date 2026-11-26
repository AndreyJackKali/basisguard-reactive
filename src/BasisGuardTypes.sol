// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title BasisGuardTypes
/// @notice Shared action enums, risk configuration structs, and canonical event topic0 constants
///         for BasisGuard Reactive across Origin, Reactive Omni (Lasna), and Destination chains.
library BasisGuardTypes {
    /// @notice Protective action types dispatched from BasisGuardReactive to DestinationHedgeVault.
    enum ActionType {
        NONE,
        EMERGENCY_DELEVERAGE,
        REBALANCE_HEDGE,
        TOP_UP_COLLATERAL
    }

    /// @notice Reason codes emitted when BasisGuardReactive evaluates an origin event and suppresses a callback.
    enum SuppressionReason {
        NONE,
        PAUSED,
        NO_DESTINATION,
        WRONG_ORIGIN,
        UNKNOWN_TOPIC,
        BELOW_THRESHOLD,
        STALE_OR_REPLAY_SEQUENCE,
        COOLDOWN_ACTIVE,
        CIRCUIT_BREAKER_TRIPPED
    }

    /// @notice Risk engine thresholds and rate-limit configuration stored on Reactive Omni.
    struct RiskConfig {
        /// @notice Minimum healthy factor in bps (e.g., 11500 = 1.15x). Below this triggers EMERGENCY_DELEVERAGE.
        uint256 minHealthFactorBps;
        /// @notice Target health factor in bps after protective deleveraging (e.g., 15000 = 1.50x).
        uint256 targetHealthFactorBps;
        /// @notice Extreme critical threshold in bps (e.g., 10500 = 1.05x) that bypasses normal cooldown.
        uint256 emergencyHealthFactorBps;
        /// @notice Absolute basis spread threshold in bps (e.g., 150 = 1.50%) triggering REBALANCE_HEDGE.
        uint256 maxBasisSpreadBps;
        /// @notice Absolute funding rate threshold in bps (e.g., 250 = 2.50%) triggering TOP_UP_COLLATERAL.
        uint256 maxFundingRateBps;
        /// @notice Minimum deleverage/action magnitude in bps (e.g., 1000 = 10%).
        uint256 minActionBps;
        /// @notice Maximum deleverage/action magnitude in bps (e.g., 6000 = 60%).
        uint256 maxActionBps;
        /// @notice Per-vault, per-action cooldown duration in seconds.
        uint64 cooldownSeconds;
        /// @notice Rolling circuit-breaker window duration in seconds.
        uint64 windowDurationSeconds;
        /// @notice Maximum callbacks allowed per rolling window before circuit breaker trips.
        uint32 maxCallbacksPerWindow;
        /// @notice Gas limit allocated to destination callbacks (must be >= 100_000 per Reactive Omni spec).
        uint64 callbackGasLimit;
    }

    /// @notice Canonical basis points denominator (100% = 10_000 bps).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum callback gas limit enforced by Reactive Omni.
    uint64 internal constant MIN_CALLBACK_GAS_LIMIT = 100_000;

    /// @notice Topic0 for OriginPerpOracle.FundingRateSpiked
    uint256 internal constant FUNDING_SPIKED_TOPIC_0 = uint256(
        keccak256("FundingRateSpiked(bytes32,address,int256,uint256,uint256,uint64,uint64)")
    );

    /// @notice Topic0 for OriginPerpOracle.HealthFactorCritical
    uint256 internal constant HEALTH_CRITICAL_TOPIC_0 = uint256(
        keccak256("HealthFactorCritical(bytes32,address,uint256,uint256,uint256,uint64,uint64)")
    );

    /// @notice Topic0 for OriginPerpOracle.SpreadDiverged
    uint256 internal constant SPREAD_DIVERGED_TOPIC_0 = uint256(
        keccak256("SpreadDiverged(bytes32,address,int256,uint256,uint256,uint64,uint64)")
    );
}
