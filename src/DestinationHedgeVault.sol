// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { BasisGuardTypes } from "./BasisGuardTypes.sol";

/// @title DestinationHedgeVault
/// @notice Destination-chain autonomous execution vault (Base Sepolia / Unichain Sepolia / Sepolia)
///         inheriting Reactive Omni's AbstractCallback. Authenticates every incoming cross-chain
///         callback via BOTH `onlyServiceProvider` (Callback Proxy) and `onlyCallbackSender`
///         (authorized BasisGuardReactive contract), enforces replay + slippage bounds, executes
///         protective deleveraging / hedge rebalancing / collateral top-ups, and stores immutable
///         audit receipts.
contract DestinationHedgeVault is AbstractCallback {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized(address caller);
    error InvalidAddress();
    error InvalidBounds();
    error PositionNotActive(bytes32 marketId, address vault);
    error InvalidActionType(uint8 actionType);
    error ActionAlreadyExecuted(bytes32 actionId);
    error StaleSequence(uint64 received, uint64 lastExecuted);
    error MagnitudeExceedsCap(uint256 requestedBps, uint256 maxAllowedBps);
    error SlippageExceeded(uint256 estimatedSlippageBps, uint256 maxSlippageBps);
    error InsufficientReserveBuffer(uint256 available);
    error WithdrawFailed();

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VaultPosition {
        uint256 collateralUsdE8;
        uint256 reserveBufferUsdE8;
        uint256 longSpotUsdE8;
        uint256 shortPerpUsdE8;
        uint256 healthFactorBps;
        uint256 maxSlippageBps;
        uint256 maxActionMagnitudeBps;
        uint64 lastUpdatedAt;
        bool active;
    }

    struct ExecutionReceipt {
        bytes32 actionId;
        bytes32 marketId;
        address vault;
        address reactiveSender;
        BasisGuardTypes.ActionType actionType;
        uint256 magnitudeBps;
        int256 metricValue;
        uint64 originSequence;
        uint256 healthBeforeBps;
        uint256 healthAfterBps;
        uint256 notionalDeltaUsdE8;
        uint256 slippageCostUsdE8;
        uint64 executedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionRegistered(
        bytes32 indexed marketId,
        address indexed vault,
        uint256 collateralUsdE8,
        uint256 reserveBufferUsdE8,
        uint256 longSpotUsdE8,
        uint256 shortPerpUsdE8,
        uint256 healthFactorBps
    );

    event ReserveDeposited(bytes32 indexed marketId, address indexed vault, uint256 amountUsdE8, uint256 newReserve);

    event ProtectionExecuted(
        bytes32 indexed actionId,
        bytes32 indexed marketId,
        address indexed vault,
        BasisGuardTypes.ActionType actionType,
        uint256 magnitudeBps,
        uint256 healthBeforeBps,
        uint256 healthAfterBps,
        uint256 notionalDeltaUsdE8,
        uint256 slippageCostUsdE8,
        uint64 originSequence
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maintenance margin requirement for perp short leg (10% = 1_000 bps -> up to 10x leverage).
    uint256 public constant MAINTENANCE_MARGIN_BPS = 1_000;

    /// @notice Linear execution price-impact model: 5 bps slippage per 1_000 bps (10%) unwound.
    uint256 public constant SLIPPAGE_PER_1000_BPS = 5;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable OWNER;

    /// @notice Active vault positions keyed by (marketId, vault).
    mapping(bytes32 => mapping(address => VaultPosition)) public positions;

    /// @notice Replay protection: tracks every executed cross-chain actionId.
    mapping(bytes32 => bool) public executedActions;

    /// @notice Monotonic sequence protection per (marketId, vault, actionType).
    mapping(bytes32 => mapping(address => mapping(uint8 => uint64))) public lastExecutedSequence;

    /// @notice Immutable audit receipts keyed by actionId.
    mapping(bytes32 => ExecutionReceipt) public receipts;

    /// @notice Indexed list of actionIds executed for each vault.
    mapping(address => bytes32[]) public vaultReceiptIds;

    /// @notice Global execution count.
    uint256 public totalProtectionsExecuted;

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

    /// @param callbackProxy_ Official Reactive Omni Callback Proxy on this destination chain.
    /// @param reactiveSentinel_ Deployed BasisGuardReactive contract address on Reactive Lasna/Mainnet.
    /// @param owner_ Vault administrator address.
    constructor(IPayable callbackProxy_, address reactiveSentinel_, address owner_)
        payable
        AbstractCallback(callbackProxy_, reactiveSentinel_)
    {
        if (address(callbackProxy_) == address(0) || reactiveSentinel_ == address(0) || owner_ == address(0)) {
            revert InvalidAddress();
        }
        OWNER = owner_;
    }

    /*//////////////////////////////////////////////////////////////
                           POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers or updates a hedged basis-trade vault position.
    function registerPosition(
        bytes32 marketId_,
        address vault_,
        uint256 collateralUsdE8_,
        uint256 reserveBufferUsdE8_,
        uint256 longSpotUsdE8_,
        uint256 shortPerpUsdE8_,
        uint256 maxSlippageBps_,
        uint256 maxActionMagnitudeBps_
    ) external onlyOwner {
        if (vault_ == address(0)) revert InvalidAddress();
        if (
            maxSlippageBps_ == 0 || maxSlippageBps_ > 500 || maxActionMagnitudeBps_ == 0
                || maxActionMagnitudeBps_ > BasisGuardTypes.BPS_DENOMINATOR
        ) {
            revert InvalidBounds();
        }

        uint256 hf = computeHealthFactorBps(collateralUsdE8_, shortPerpUsdE8_);
        positions[marketId_][vault_] = VaultPosition({
            collateralUsdE8: collateralUsdE8_,
            reserveBufferUsdE8: reserveBufferUsdE8_,
            longSpotUsdE8: longSpotUsdE8_,
            shortPerpUsdE8: shortPerpUsdE8_,
            healthFactorBps: hf,
            maxSlippageBps: maxSlippageBps_,
            maxActionMagnitudeBps: maxActionMagnitudeBps_,
            lastUpdatedAt: uint64(block.timestamp),
            active: true
        });

        emit PositionRegistered(
            marketId_, vault_, collateralUsdE8_, reserveBufferUsdE8_, longSpotUsdE8_, shortPerpUsdE8_, hf
        );
    }

    /// @notice Adds reserve liquidity used for autonomous funding-spike collateral top-ups.
    function depositReserve(bytes32 marketId_, address vault_, uint256 amountUsdE8_) external onlyOwner {
        VaultPosition storage pos = positions[marketId_][vault_];
        if (!pos.active) revert PositionNotActive(marketId_, vault_);
        pos.reserveBufferUsdE8 += amountUsdE8_;
        pos.lastUpdatedAt = uint64(block.timestamp);
        emit ReserveDeposited(marketId_, vault_, amountUsdE8_, pos.reserveBufferUsdE8);
    }

    /// @notice Updates slippage and action-size guardrails on an active position.
    function setPositionBounds(
        bytes32 marketId_,
        address vault_,
        uint256 maxSlippageBps_,
        uint256 maxActionMagnitudeBps_
    ) external onlyOwner {
        VaultPosition storage pos = positions[marketId_][vault_];
        if (!pos.active) revert PositionNotActive(marketId_, vault_);
        if (
            maxSlippageBps_ == 0 || maxSlippageBps_ > 500 || maxActionMagnitudeBps_ == 0
                || maxActionMagnitudeBps_ > BasisGuardTypes.BPS_DENOMINATOR
        ) {
            revert InvalidBounds();
        }
        pos.maxSlippageBps = maxSlippageBps_;
        pos.maxActionMagnitudeBps = maxActionMagnitudeBps_;
        pos.lastUpdatedAt = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                      REACTIVE CALLBACK ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes an authenticated cross-chain protective action triggered by BasisGuardReactive.
    /// @dev Guarded by BOTH `onlyServiceProvider` (verifies msg.sender is destination Callback Proxy)
    ///      and `onlyCallbackSender(reactiveSender_)` (verifies 160-bit injected sender matches
    ///      immutable `_CALLBACK_SENDER` == BasisGuardReactive).
    function executeProtection(
        address reactiveSender_,
        bytes32 actionId_,
        bytes32 marketId_,
        address vault_,
        uint8 actionTypeRaw_,
        uint256 magnitudeBps_,
        int256 metricValue_,
        uint64 originSequence_
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender_) {
        if (
            actionTypeRaw_ == uint8(BasisGuardTypes.ActionType.NONE)
                || actionTypeRaw_ > uint8(BasisGuardTypes.ActionType.TOP_UP_COLLATERAL)
        ) {
            revert InvalidActionType(actionTypeRaw_);
        }

        if (executedActions[actionId_]) revert ActionAlreadyExecuted(actionId_);

        uint64 prevSeq = lastExecutedSequence[marketId_][vault_][actionTypeRaw_];
        if (originSequence_ <= prevSeq) revert StaleSequence(originSequence_, prevSeq);

        VaultPosition storage pos = positions[marketId_][vault_];
        if (!pos.active) revert PositionNotActive(marketId_, vault_);

        if (magnitudeBps_ == 0 || magnitudeBps_ > pos.maxActionMagnitudeBps) {
            revert MagnitudeExceedsCap(magnitudeBps_, pos.maxActionMagnitudeBps);
        }

        BasisGuardTypes.ActionType actionType = BasisGuardTypes.ActionType(actionTypeRaw_);
        uint256 healthBefore = pos.healthFactorBps;
        (uint256 notionalDelta, uint256 slippageCost) = _dispatchAction(pos, actionType, magnitudeBps_, metricValue_);

        uint256 healthAfter = computeHealthFactorBps(pos.collateralUsdE8, pos.shortPerpUsdE8);
        pos.healthFactorBps = healthAfter;
        pos.lastUpdatedAt = uint64(block.timestamp);

        executedActions[actionId_] = true;
        lastExecutedSequence[marketId_][vault_][actionTypeRaw_] = originSequence_;
        totalProtectionsExecuted += 1;

        _storeReceipt(
            ExecutionReceipt({
                actionId: actionId_,
                marketId: marketId_,
                vault: vault_,
                reactiveSender: reactiveSender_,
                actionType: actionType,
                magnitudeBps: magnitudeBps_,
                metricValue: metricValue_,
                originSequence: originSequence_,
                healthBeforeBps: healthBefore,
                healthAfterBps: healthAfter,
                notionalDeltaUsdE8: notionalDelta,
                slippageCostUsdE8: slippageCost,
                executedAt: uint64(block.timestamp)
            })
        );
    }

    function _dispatchAction(
        VaultPosition storage pos_,
        BasisGuardTypes.ActionType actionType_,
        uint256 magnitudeBps_,
        int256 metricValue_
    ) internal returns (uint256 notionalDelta_, uint256 slippageCost_) {
        if (actionType_ == BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE) {
            return _executeDeleverage(pos_, magnitudeBps_);
        }
        if (actionType_ == BasisGuardTypes.ActionType.REBALANCE_HEDGE) {
            return _executeRebalance(pos_, magnitudeBps_, metricValue_);
        }
        return _executeTopUp(pos_, magnitudeBps_);
    }

    function _storeReceipt(ExecutionReceipt memory receipt_) internal {
        receipts[receipt_.actionId] = receipt_;
        vaultReceiptIds[receipt_.vault].push(receipt_.actionId);

        emit ProtectionExecuted(
            receipt_.actionId,
            receipt_.marketId,
            receipt_.vault,
            receipt_.actionType,
            receipt_.magnitudeBps,
            receipt_.healthBeforeBps,
            receipt_.healthAfterBps,
            receipt_.notionalDeltaUsdE8,
            receipt_.slippageCostUsdE8,
            receipt_.originSequence
        );
    }

    /*//////////////////////////////////////////////////////////////
                          ECONOMY & READ VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Publicly callable wrapper to settle outstanding callback proxy debt from contract balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Withdraws surplus destination gas ETH after settling any callback proxy debt.
    function withdrawSurplus(address payable to_, uint256 amount_) external onlyOwner {
        if (to_ == address(0)) revert InvalidAddress();
        _coverDebt();
        (bool ok,) = to_.call{ value: amount_ }("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Deterministic vault health factor in bps (10_000 = 1.00x liquidation threshold).
    function computeHealthFactorBps(uint256 collateralUsdE8_, uint256 shortPerpUsdE8_)
        public
        pure
        returns (uint256 healthFactorBps_)
    {
        if (shortPerpUsdE8_ == 0) return type(uint256).max;
        uint256 maintenanceMargin = (shortPerpUsdE8_ * MAINTENANCE_MARGIN_BPS) / BasisGuardTypes.BPS_DENOMINATOR;
        if (maintenanceMargin == 0) return type(uint256).max;
        healthFactorBps_ = (collateralUsdE8_ * BasisGuardTypes.BPS_DENOMINATOR) / maintenanceMargin;
    }

    /// @notice Deterministic slippage estimate in bps for a given execution magnitude.
    function estimateSlippageBps(uint256 magnitudeBps_) public pure returns (uint256) {
        return (magnitudeBps_ * SLIPPAGE_PER_1000_BPS + 999) / 1_000;
    }

    function getVaultReceiptCount(address vault_) external view returns (uint256) {
        return vaultReceiptIds[vault_].length;
    }

    function getReceipt(bytes32 actionId_) external view returns (ExecutionReceipt memory) {
        return receipts[actionId_];
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL EXECUTION OPS
    //////////////////////////////////////////////////////////////*/

    function _executeDeleverage(VaultPosition storage pos_, uint256 magnitudeBps_)
        internal
        returns (uint256 unwoundNotional_, uint256 slippageCost_)
    {
        uint256 estSlippage = estimateSlippageBps(magnitudeBps_);
        if (estSlippage > pos_.maxSlippageBps) {
            revert SlippageExceeded(estSlippage, pos_.maxSlippageBps);
        }

        uint256 perpReduction = (pos_.shortPerpUsdE8 * magnitudeBps_) / BasisGuardTypes.BPS_DENOMINATOR;
        uint256 spotReduction = (pos_.longSpotUsdE8 * magnitudeBps_) / BasisGuardTypes.BPS_DENOMINATOR;

        slippageCost_ = (perpReduction * estSlippage) / BasisGuardTypes.BPS_DENOMINATOR;
        // Never allow slippage deduction to underflow collateral
        if (slippageCost_ > pos_.collateralUsdE8) {
            slippageCost_ = pos_.collateralUsdE8;
        }

        pos_.shortPerpUsdE8 -= perpReduction;
        pos_.longSpotUsdE8 -= spotReduction;
        pos_.collateralUsdE8 -= slippageCost_;

        unwoundNotional_ = perpReduction;
    }

    function _executeRebalance(VaultPosition storage pos_, uint256 magnitudeBps_, int256 basisSpreadBps_)
        internal
        returns (uint256 rebalancedNotional_, uint256 slippageCost_)
    {
        uint256 estSlippage = estimateSlippageBps(magnitudeBps_);
        if (estSlippage > pos_.maxSlippageBps) {
            revert SlippageExceeded(estSlippage, pos_.maxSlippageBps);
        }

        if (basisSpreadBps_ < 0) {
            // Negative basis (backwardation): trim both legs proportionally to cut negative carry
            uint256 perpTrim = (pos_.shortPerpUsdE8 * magnitudeBps_) / (BasisGuardTypes.BPS_DENOMINATOR * 2);
            uint256 spotTrim = (pos_.longSpotUsdE8 * magnitudeBps_) / (BasisGuardTypes.BPS_DENOMINATOR * 2);
            slippageCost_ = (perpTrim * estSlippage) / BasisGuardTypes.BPS_DENOMINATOR;
            if (slippageCost_ > pos_.collateralUsdE8) slippageCost_ = pos_.collateralUsdE8;

            pos_.shortPerpUsdE8 -= perpTrim;
            pos_.longSpotUsdE8 -= spotTrim;
            pos_.collateralUsdE8 -= slippageCost_;
            rebalancedNotional_ = perpTrim;
        } else {
            // Positive basis divergence: re-center delta imbalance toward delta-neutral (longSpot == shortPerp)
            if (pos_.longSpotUsdE8 > pos_.shortPerpUsdE8) {
                uint256 imbalance = pos_.longSpotUsdE8 - pos_.shortPerpUsdE8;
                uint256 deltaShift = (imbalance * magnitudeBps_) / BasisGuardTypes.BPS_DENOMINATOR;
                if (deltaShift == 0) deltaShift = imbalance;
                slippageCost_ = (deltaShift * estSlippage) / BasisGuardTypes.BPS_DENOMINATOR;
                if (slippageCost_ > pos_.collateralUsdE8) slippageCost_ = pos_.collateralUsdE8;

                pos_.longSpotUsdE8 -= deltaShift;
                pos_.collateralUsdE8 -= slippageCost_;
                rebalancedNotional_ = deltaShift;
            } else if (pos_.shortPerpUsdE8 > pos_.longSpotUsdE8) {
                uint256 imbalance = pos_.shortPerpUsdE8 - pos_.longSpotUsdE8;
                uint256 deltaShift = (imbalance * magnitudeBps_) / BasisGuardTypes.BPS_DENOMINATOR;
                if (deltaShift == 0) deltaShift = imbalance;
                slippageCost_ = (deltaShift * estSlippage) / BasisGuardTypes.BPS_DENOMINATOR;
                if (slippageCost_ > pos_.collateralUsdE8) slippageCost_ = pos_.collateralUsdE8;

                pos_.shortPerpUsdE8 -= deltaShift;
                pos_.collateralUsdE8 -= slippageCost_;
                rebalancedNotional_ = deltaShift;
            } else {
                // Already delta-neutral: lock in basis spread by trimming a small slice conservatively
                uint256 lockSlice = (pos_.shortPerpUsdE8 * magnitudeBps_) / (BasisGuardTypes.BPS_DENOMINATOR * 4);
                slippageCost_ = (lockSlice * estSlippage) / BasisGuardTypes.BPS_DENOMINATOR;
                if (slippageCost_ > pos_.collateralUsdE8) slippageCost_ = pos_.collateralUsdE8;

                pos_.shortPerpUsdE8 -= lockSlice;
                pos_.longSpotUsdE8 -= lockSlice;
                pos_.collateralUsdE8 -= slippageCost_;
                rebalancedNotional_ = lockSlice;
            }
        }
    }

    function _executeTopUp(VaultPosition storage pos_, uint256 magnitudeBps_)
        internal
        returns (uint256 topUpAmount_, uint256 slippageCost_)
    {
        if (pos_.reserveBufferUsdE8 == 0) revert InsufficientReserveBuffer(0);

        topUpAmount_ = (pos_.reserveBufferUsdE8 * magnitudeBps_) / BasisGuardTypes.BPS_DENOMINATOR;
        if (topUpAmount_ == 0) topUpAmount_ = pos_.reserveBufferUsdE8;

        pos_.reserveBufferUsdE8 -= topUpAmount_;
        pos_.collateralUsdE8 += topUpAmount_;
        slippageCost_ = 0; // Internal reserve transfer incurs zero market slippage
    }
}
