// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { BasisGuardTypes } from "./BasisGuardTypes.sol";

/// @title BasisGuardReactive
/// @notice Autonomous cross-chain risk sentinel deployed on Reactive Omni (Lasna Testnet / Mainnet).
///         Subscribes to OriginPerpOracle telemetry events, evaluates deterministic on-chain risk
///         thresholds, enforces per-vault cooldowns (with emergency liquidation bypass), monotonic
///         sequence replay protection, and a rolling-window circuit breaker, then dispatches
///         authenticated cross-chain callbacks via SYSTEM.requestCallbackV_1_0().
contract BasisGuardReactive is AbstractReactive {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized(address caller);
    error InvalidAddress();
    error InvalidChainId();
    error InvalidRiskConfig();
    error AlreadyPaused();
    error NotPaused();
    error WithdrawFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DestinationVaultUpdated(uint256 indexed destinationChainId, address indexed destinationVault);
    event RiskConfigUpdated(
        uint256 minHealthFactorBps,
        uint256 targetHealthFactorBps,
        uint256 emergencyHealthFactorBps,
        uint256 maxBasisSpreadBps,
        uint256 maxFundingRateBps
    );
    event SentinelPaused(address indexed caller);
    event SentinelUnpaused(address indexed caller);

    event ProtectionDispatched(
        bytes32 indexed actionId,
        bytes32 indexed marketId,
        address indexed vault,
        BasisGuardTypes.ActionType actionType,
        uint256 magnitudeBps,
        int256 metricValue,
        uint64 originSequence,
        uint256 destinationChainId,
        address destinationVault
    );

    event ReactionSuppressed(
        bytes32 indexed marketId,
        address indexed vault,
        BasisGuardTypes.ActionType actionType,
        BasisGuardTypes.SuppressionReason reason,
        uint64 originSequence
    );

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable OWNER;
    uint256 public immutable ORIGIN_CHAIN_ID;
    address public immutable ORIGIN_ORACLE;

    uint256 public destinationChainId;
    address public destinationVault;
    bool public paused;

    BasisGuardTypes.RiskConfig public riskConfig;

    /// @notice Last processed origin sequence per (marketId, vault, actionType).
    mapping(bytes32 => mapping(address => mapping(uint8 => uint64))) public lastProcessedSequence;

    /// @notice Last callback dispatch timestamp per (vault, actionType) for cooldown gating.
    mapping(address => mapping(uint8 => uint64)) public lastActionTimestamp;

    /// @notice Rolling circuit-breaker window state.
    uint64 public windowStartTimestamp;
    uint32 public windowCallbackCount;

    /// @notice On-chain observability telemetry counters.
    uint256 public totalEventsReceived;
    uint256 public totalCallbacksDispatched;
    uint256 public totalSuppressedThreshold;
    uint256 public totalSuppressedCooldown;
    uint256 public totalSuppressedReplay;
    uint256 public totalSuppressedCircuitBreaker;
    bytes32 public lastDispatchedActionId;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert Unauthorized(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param originChainId_ Origin chain ID where OriginPerpOracle lives (e.g., 84532 Base Sepolia).
    /// @param originOracle_ Address of OriginPerpOracle on the origin chain.
    /// @param destinationChainId_ Destination chain ID where DestinationHedgeVault lives.
    /// @param destinationVault_ Optional initial destination vault (can be address(0) and set after deploy).
    /// @param config_ Initial deterministic risk thresholds and rate limits.
    constructor(
        uint256 originChainId_,
        address originOracle_,
        uint256 destinationChainId_,
        address destinationVault_,
        BasisGuardTypes.RiskConfig memory config_
    ) payable {
        if (originChainId_ == 0 || destinationChainId_ == 0) revert InvalidChainId();
        if (originOracle_ == address(0)) revert InvalidAddress();
        _validateRiskConfig(config_);

        OWNER = msg.sender;
        ORIGIN_CHAIN_ID = originChainId_;
        ORIGIN_ORACLE = originOracle_;
        destinationChainId = destinationChainId_;
        destinationVault = destinationVault_;
        riskConfig = config_;
        windowStartTimestamp = uint64(block.timestamp);

        _subscribeAll();
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN & ECONOMY
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets destination chain and DestinationHedgeVault address (step 3 of Reactive Omni deploy flow).
    function setDestinationVault(uint256 destinationChainId_, address destinationVault_) external onlyOwner {
        if (destinationChainId_ == 0) revert InvalidChainId();
        if (destinationVault_ == address(0)) revert InvalidAddress();
        destinationChainId = destinationChainId_;
        destinationVault = destinationVault_;
        emit DestinationVaultUpdated(destinationChainId_, destinationVault_);
    }

    /// @notice Updates risk engine thresholds and rate-limit parameters.
    function setRiskConfig(BasisGuardTypes.RiskConfig calldata config_) external onlyOwner {
        _validateRiskConfig(config_);
        riskConfig = config_;
        emit RiskConfigUpdated(
            config_.minHealthFactorBps,
            config_.targetHealthFactorBps,
            config_.emergencyHealthFactorBps,
            config_.maxBasisSpreadBps,
            config_.maxFundingRateBps
        );
    }

    /// @notice Pauses the sentinel and unsubscribes from origin chain logs to save REACT gas.
    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        _unsubscribeAll();
        emit SentinelPaused(msg.sender);
    }

    /// @notice Resumes the sentinel, settles any outstanding system debt, and re-subscribes to origin logs.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        _coverDebt();
        _subscribeAll();
        emit SentinelUnpaused(msg.sender);
    }

    /// @notice Publicly callable wrapper to settle outstanding debt to SYSTEM from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Allows the owner to withdraw excess REACT balance after settling any outstanding debt.
    function withdrawSurplus(address payable to_, uint256 amount_) external onlyOwner {
        if (to_ == address(0)) revert InvalidAddress();
        _coverDebt();
        (bool ok,) = to_.call{ value: amount_ }("");
        if (!ok) revert WithdrawFailed();
    }

    /*//////////////////////////////////////////////////////////////
                         REACTIVE ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IReactive
    /// @dev Guarded by `onlySystem` so only Reactive Omni SYSTEM (0x8888...8888) can deliver logs.
    ///      Suppressions return cleanly rather than reverting so the sentinel never wastes gas on
    ///      failed reactive transactions (`ReactiveContractReverted`).
    function react(LogRecord calldata log_) external override onlySystem {
        totalEventsReceived++;

        bytes32 marketId = bytes32(log_.topic1);
        address vault = address(uint160(log_.topic2));

        if (paused) {
            emit ReactionSuppressed(
                marketId, vault, BasisGuardTypes.ActionType.NONE, BasisGuardTypes.SuppressionReason.PAUSED, 0
            );
            return;
        }

        if (destinationVault == address(0)) {
            emit ReactionSuppressed(
                marketId, vault, BasisGuardTypes.ActionType.NONE, BasisGuardTypes.SuppressionReason.NO_DESTINATION, 0
            );
            return;
        }

        if (log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != ORIGIN_ORACLE) {
            emit ReactionSuppressed(
                marketId, vault, BasisGuardTypes.ActionType.NONE, BasisGuardTypes.SuppressionReason.WRONG_ORIGIN, 0
            );
            return;
        }

        if (log_.topic0 == BasisGuardTypes.HEALTH_CRITICAL_TOPIC_0) {
            _handleHealthCritical(log_, marketId, vault);
        } else if (log_.topic0 == BasisGuardTypes.SPREAD_DIVERGED_TOPIC_0) {
            _handleSpreadDiverged(log_, marketId, vault);
        } else if (log_.topic0 == BasisGuardTypes.FUNDING_SPIKED_TOPIC_0) {
            _handleFundingSpiked(log_, marketId, vault);
        } else {
            emit ReactionSuppressed(
                marketId, vault, BasisGuardTypes.ActionType.NONE, BasisGuardTypes.SuppressionReason.UNKNOWN_TOPIC, 0
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DETERMINISTIC RISK MATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes deleverage magnitude in bps proportional to health-factor shortfall below target.
    function computeDeleverageBps(uint256 healthFactorBps_) public view returns (uint256 magnitudeBps_) {
        BasisGuardTypes.RiskConfig memory cfg = riskConfig;
        if (healthFactorBps_ >= cfg.minHealthFactorBps) return 0;

        uint256 shortfall = cfg.targetHealthFactorBps > healthFactorBps_
            ? cfg.targetHealthFactorBps - healthFactorBps_
            : 0;
        uint256 rawBps = (shortfall * BasisGuardTypes.BPS_DENOMINATOR) / cfg.targetHealthFactorBps;
        magnitudeBps_ = _clamp(rawBps, cfg.minActionBps, cfg.maxActionBps);
    }

    /// @notice Computes hedge-rebalance magnitude in bps proportional to excess basis spread divergence.
    function computeRebalanceBps(int256 basisSpreadBps_) public view returns (uint256 magnitudeBps_) {
        BasisGuardTypes.RiskConfig memory cfg = riskConfig;
        uint256 absSpread = _abs(basisSpreadBps_);
        if (absSpread < cfg.maxBasisSpreadBps) return 0;

        // Scale from minActionBps at threshold up to maxActionBps at 4x threshold.
        uint256 rawBps = (absSpread * BasisGuardTypes.BPS_DENOMINATOR) / (cfg.maxBasisSpreadBps * 4);
        magnitudeBps_ = _clamp(rawBps, cfg.minActionBps, cfg.maxActionBps);
    }

    /// @notice Computes reserve collateral top-up magnitude in bps proportional to funding-rate severity.
    function computeTopUpBps(int256 fundingRateBps_) public view returns (uint256 magnitudeBps_) {
        BasisGuardTypes.RiskConfig memory cfg = riskConfig;
        uint256 absFunding = _abs(fundingRateBps_);
        if (absFunding < cfg.maxFundingRateBps) return 0;

        // Scale from minActionBps at threshold up to maxActionBps at 4x threshold.
        uint256 rawBps = (absFunding * BasisGuardTypes.BPS_DENOMINATOR) / (cfg.maxFundingRateBps * 4);
        magnitudeBps_ = _clamp(rawBps, cfg.minActionBps, cfg.maxActionBps);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HANDLERS
    //////////////////////////////////////////////////////////////*/

    function _handleHealthCritical(LogRecord calldata log_, bytes32 marketId_, address vault_) internal {
        (uint256 healthFactorBps,,, uint64 sequenceId,) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint64, uint64));

        uint256 magnitudeBps = computeDeleverageBps(healthFactorBps);
        if (magnitudeBps == 0) {
            totalSuppressedThreshold++;
            emit ReactionSuppressed(
                marketId_,
                vault_,
                BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE,
                BasisGuardTypes.SuppressionReason.BELOW_THRESHOLD,
                sequenceId
            );
            return;
        }

        bool bypassCooldown = healthFactorBps < riskConfig.emergencyHealthFactorBps;

        _evaluateGuardsAndDispatch(
            log_,
            marketId_,
            vault_,
            BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE,
            magnitudeBps,
            int256(healthFactorBps),
            sequenceId,
            bypassCooldown
        );
    }

    function _handleSpreadDiverged(LogRecord calldata log_, bytes32 marketId_, address vault_) internal {
        (int256 basisSpreadBps,,, uint64 sequenceId,) = abi.decode(log_.data, (int256, uint256, uint256, uint64, uint64));

        uint256 magnitudeBps = computeRebalanceBps(basisSpreadBps);
        if (magnitudeBps == 0) {
            totalSuppressedThreshold++;
            emit ReactionSuppressed(
                marketId_,
                vault_,
                BasisGuardTypes.ActionType.REBALANCE_HEDGE,
                BasisGuardTypes.SuppressionReason.BELOW_THRESHOLD,
                sequenceId
            );
            return;
        }

        _evaluateGuardsAndDispatch(
            log_,
            marketId_,
            vault_,
            BasisGuardTypes.ActionType.REBALANCE_HEDGE,
            magnitudeBps,
            basisSpreadBps,
            sequenceId,
            false
        );
    }

    function _handleFundingSpiked(LogRecord calldata log_, bytes32 marketId_, address vault_) internal {
        (int256 fundingRateBps,,, uint64 sequenceId,) = abi.decode(log_.data, (int256, uint256, uint256, uint64, uint64));

        uint256 magnitudeBps = computeTopUpBps(fundingRateBps);
        if (magnitudeBps == 0) {
            totalSuppressedThreshold++;
            emit ReactionSuppressed(
                marketId_,
                vault_,
                BasisGuardTypes.ActionType.TOP_UP_COLLATERAL,
                BasisGuardTypes.SuppressionReason.BELOW_THRESHOLD,
                sequenceId
            );
            return;
        }

        _evaluateGuardsAndDispatch(
            log_,
            marketId_,
            vault_,
            BasisGuardTypes.ActionType.TOP_UP_COLLATERAL,
            magnitudeBps,
            fundingRateBps,
            sequenceId,
            false
        );
    }

    function _evaluateGuardsAndDispatch(
        LogRecord calldata log_,
        bytes32 marketId_,
        address vault_,
        BasisGuardTypes.ActionType actionType_,
        uint256 magnitudeBps_,
        int256 metricValue_,
        uint64 sequenceId_,
        bool bypassCooldown_
    ) internal {
        uint8 actionKey = uint8(actionType_);

        // 1. Strict monotonic sequence replay defense
        if (sequenceId_ <= lastProcessedSequence[marketId_][vault_][actionKey]) {
            totalSuppressedReplay++;
            emit ReactionSuppressed(
                marketId_, vault_, actionType_, BasisGuardTypes.SuppressionReason.STALE_OR_REPLAY_SEQUENCE, sequenceId_
            );
            return;
        }

        // 2. Per-vault cooldown (bypassable ONLY for extreme critical health factor)
        uint64 lastTs = lastActionTimestamp[vault_][actionKey];
        if (!bypassCooldown_ && lastTs != 0 && block.timestamp < uint256(lastTs) + uint256(riskConfig.cooldownSeconds))
        {
            totalSuppressedCooldown++;
            emit ReactionSuppressed(
                marketId_, vault_, actionType_, BasisGuardTypes.SuppressionReason.COOLDOWN_ACTIVE, sequenceId_
            );
            return;
        }

        // 3. Rolling-window circuit breaker
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs >= windowStartTimestamp + riskConfig.windowDurationSeconds) {
            windowStartTimestamp = nowTs;
            windowCallbackCount = 0;
        }
        if (windowCallbackCount >= riskConfig.maxCallbacksPerWindow) {
            totalSuppressedCircuitBreaker++;
            emit ReactionSuppressed(
                marketId_, vault_, actionType_, BasisGuardTypes.SuppressionReason.CIRCUIT_BREAKER_TRIPPED, sequenceId_
            );
            return;
        }

        // Commit state before external call to SYSTEM
        lastProcessedSequence[marketId_][vault_][actionKey] = sequenceId_;
        lastActionTimestamp[vault_][actionKey] = nowTs;
        windowCallbackCount += 1;
        totalCallbacksDispatched += 1;

        bytes32 actionId = keccak256(
            abi.encode(
                log_.chainId,
                log_.contractAddress,
                log_.txHash,
                log_.logIndex,
                marketId_,
                vault_,
                actionKey,
                sequenceId_
            )
        );
        lastDispatchedActionId = actionId;

        // First parameter MUST be `address(0)` placeholder: Reactive Omni Callback Proxy overwrites
        // the first 160 bits of payload args with `address(this)` for destination authentication.
        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,bytes32,bytes32,address,uint8,uint256,int256,uint64)",
            address(0),
            actionId,
            marketId_,
            vault_,
            actionKey,
            magnitudeBps_,
            metricValue_,
            sequenceId_
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: destinationVault,
                gasLimit: riskConfig.callbackGasLimit,
                payload: payload
            })
        );

        emit ProtectionDispatched(
            actionId,
            marketId_,
            vault_,
            actionType_,
            magnitudeBps_,
            metricValue_,
            sequenceId_,
            destinationChainId,
            destinationVault
        );
    }

    /*//////////////////////////////////////////////////////////////
                        SUBSCRIPTION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function _subscribeAll() internal {
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID,
            ORIGIN_ORACLE,
            BasisGuardTypes.HEALTH_CRITICAL_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID,
            ORIGIN_ORACLE,
            BasisGuardTypes.SPREAD_DIVERGED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID,
            ORIGIN_ORACLE,
            BasisGuardTypes.FUNDING_SPIKED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _unsubscribeAll() internal {
        SYSTEM.unsubscribe(
            ORIGIN_CHAIN_ID,
            ORIGIN_ORACLE,
            BasisGuardTypes.HEALTH_CRITICAL_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            ORIGIN_CHAIN_ID,
            ORIGIN_ORACLE,
            BasisGuardTypes.SPREAD_DIVERGED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            ORIGIN_CHAIN_ID,
            ORIGIN_ORACLE,
            BasisGuardTypes.FUNDING_SPIKED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _validateRiskConfig(BasisGuardTypes.RiskConfig memory cfg_) internal pure {
        if (
            cfg_.minHealthFactorBps == 0 || cfg_.targetHealthFactorBps <= cfg_.minHealthFactorBps
                || cfg_.emergencyHealthFactorBps >= cfg_.minHealthFactorBps || cfg_.maxBasisSpreadBps == 0
                || cfg_.maxFundingRateBps == 0 || cfg_.minActionBps == 0 || cfg_.minActionBps > cfg_.maxActionBps
                || cfg_.maxActionBps > BasisGuardTypes.BPS_DENOMINATOR || cfg_.windowDurationSeconds == 0
                || cfg_.maxCallbacksPerWindow == 0 || cfg_.callbackGasLimit < BasisGuardTypes.MIN_CALLBACK_GAS_LIMIT
        ) {
            revert InvalidRiskConfig();
        }
    }

    function _clamp(uint256 val_, uint256 minVal_, uint256 maxVal_) internal pure returns (uint256) {
        if (val_ < minVal_) return minVal_;
        if (val_ > maxVal_) return maxVal_;
        return val_;
    }

    function _abs(int256 val_) internal pure returns (uint256) {
        if (val_ >= 0) return uint256(val_);
        if (val_ == type(int256).min) return uint256(type(int256).max) + 1;
        return uint256(-val_);
    }
}
