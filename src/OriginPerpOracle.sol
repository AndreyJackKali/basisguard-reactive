// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title OriginPerpOracle
/// @notice Origin-chain telemetry oracle deployed on a fast L2 (e.g., Base Sepolia ~200ms blocks)
///         that records perpetuals mark/index prices, basis spreads, funding rates, and vault health
///         factors, emitting canonical indexed events subscribed to by BasisGuardReactive on Reactive Omni.
contract OriginPerpOracle {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized(address caller);
    error InvalidPrice();
    error InvalidAddress();
    error InvalidMarket();

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct MarketSnapshot {
        uint256 markPriceE8;
        uint256 indexPriceE8;
        int256 fundingRateBps;
        int256 basisSpreadBps;
        uint64 sequenceId;
        uint64 updatedAt;
    }

    struct VaultHealthSnapshot {
        uint256 healthFactorBps;
        uint256 collateralUsdE8;
        uint256 debtUsdE8;
        uint64 sequenceId;
        uint64 updatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a perpetual market experiences a funding-rate spike affecting a vault.
    event FundingRateSpiked(
        bytes32 indexed marketId,
        address indexed vault,
        int256 fundingRateBps,
        uint256 markPriceE8,
        uint256 indexPriceE8,
        uint64 sequenceId,
        uint64 timestamp
    );

    /// @notice Emitted when a vault's margin health factor updates into a monitored danger zone.
    event HealthFactorCritical(
        bytes32 indexed marketId,
        address indexed vault,
        uint256 healthFactorBps,
        uint256 collateralUsdE8,
        uint256 debtUsdE8,
        uint64 sequenceId,
        uint64 timestamp
    );

    /// @notice Emitted when spot-vs-perp basis spread diverges on a monitored market/vault pair.
    event SpreadDiverged(
        bytes32 indexed marketId,
        address indexed vault,
        int256 basisSpreadBps,
        uint256 markPriceE8,
        uint256 indexPriceE8,
        uint64 sequenceId,
        uint64 timestamp
    );

    event ReporterUpdated(address indexed reporter, bool authorized);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    mapping(address => bool) public authorizedReporters;

    /// @notice Latest market snapshot per marketId (e.g., keccak256("ETH-PERP")).
    mapping(bytes32 => MarketSnapshot) public marketSnapshots;

    /// @notice Latest health snapshot per (marketId, vault).
    mapping(bytes32 => mapping(address => VaultHealthSnapshot)) public vaultHealthSnapshots;

    /// @notice Global monotonic sequence counter per (marketId, vault) for replay/order guarantees.
    mapping(bytes32 => mapping(address => uint64)) public vaultSequences;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyReporter() {
        if (msg.sender != owner && !authorizedReporters[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address initialOwner_) {
        if (initialOwner_ == address(0)) revert InvalidAddress();
        owner = initialOwner_;
        authorizedReporters[initialOwner_] = true;
        emit OwnershipTransferred(address(0), initialOwner_);
        emit ReporterUpdated(initialOwner_, true);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function setReporter(address reporter_, bool authorized_) external onlyOwner {
        if (reporter_ == address(0)) revert InvalidAddress();
        authorizedReporters[reporter_] = authorized_;
        emit ReporterUpdated(reporter_, authorized_);
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert InvalidAddress();
        address prev = owner;
        owner = newOwner_;
        emit OwnershipTransferred(prev, newOwner_);
    }

    /*//////////////////////////////////////////////////////////////
                           PURE MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes signed spot-vs-perp basis spread in basis points:
    ///         ((markPriceE8 - indexPriceE8) * 10_000) / indexPriceE8.
    function computeBasisSpreadBps(uint256 markPriceE8_, uint256 indexPriceE8_)
        public
        pure
        returns (int256 spreadBps_)
    {
        if (markPriceE8_ == 0 || indexPriceE8_ == 0) revert InvalidPrice();
        int256 diff = int256(markPriceE8_) - int256(indexPriceE8_);
        spreadBps_ = (diff * 10_000) / int256(indexPriceE8_);
    }

    /*//////////////////////////////////////////////////////////////
                          TELEMETRY PUBLISHERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reports a funding-rate spike event for a market and target vault.
    function reportFundingSpike(
        bytes32 marketId_,
        address vault_,
        int256 fundingRateBps_,
        uint256 markPriceE8_,
        uint256 indexPriceE8_
    ) external onlyReporter returns (uint64 sequenceId_) {
        _validateParams(marketId_, vault_);
        int256 spreadBps = computeBasisSpreadBps(markPriceE8_, indexPriceE8_);

        sequenceId_ = ++vaultSequences[marketId_][vault_];
        uint64 ts = uint64(block.timestamp);

        marketSnapshots[marketId_] = MarketSnapshot({
            markPriceE8: markPriceE8_,
            indexPriceE8: indexPriceE8_,
            fundingRateBps: fundingRateBps_,
            basisSpreadBps: spreadBps,
            sequenceId: sequenceId_,
            updatedAt: ts
        });

        emit FundingRateSpiked(
            marketId_,
            vault_,
            fundingRateBps_,
            markPriceE8_,
            indexPriceE8_,
            sequenceId_,
            ts
        );
    }

    /// @notice Reports a basis-spread divergence computed on-chain from mark and index prices.
    function reportSpreadDivergence(
        bytes32 marketId_,
        address vault_,
        uint256 markPriceE8_,
        uint256 indexPriceE8_,
        int256 fundingRateBps_
    ) external onlyReporter returns (int256 basisSpreadBps_, uint64 sequenceId_) {
        _validateParams(marketId_, vault_);
        basisSpreadBps_ = computeBasisSpreadBps(markPriceE8_, indexPriceE8_);

        sequenceId_ = ++vaultSequences[marketId_][vault_];
        uint64 ts = uint64(block.timestamp);

        marketSnapshots[marketId_] = MarketSnapshot({
            markPriceE8: markPriceE8_,
            indexPriceE8: indexPriceE8_,
            fundingRateBps: fundingRateBps_,
            basisSpreadBps: basisSpreadBps_,
            sequenceId: sequenceId_,
            updatedAt: ts
        });

        emit SpreadDiverged(
            marketId_,
            vault_,
            basisSpreadBps_,
            markPriceE8_,
            indexPriceE8_,
            sequenceId_,
            ts
        );
    }

    /// @notice Reports a vault margin health factor update for real-time liquidation defense.
    function reportHealthFactor(
        bytes32 marketId_,
        address vault_,
        uint256 healthFactorBps_,
        uint256 collateralUsdE8_,
        uint256 debtUsdE8_
    ) external onlyReporter returns (uint64 sequenceId_) {
        _validateParams(marketId_, vault_);

        sequenceId_ = ++vaultSequences[marketId_][vault_];
        uint64 ts = uint64(block.timestamp);

        vaultHealthSnapshots[marketId_][vault_] = VaultHealthSnapshot({
            healthFactorBps: healthFactorBps_,
            collateralUsdE8: collateralUsdE8_,
            debtUsdE8: debtUsdE8_,
            sequenceId: sequenceId_,
            updatedAt: ts
        });

        emit HealthFactorCritical(
            marketId_,
            vault_,
            healthFactorBps_,
            collateralUsdE8_,
            debtUsdE8_,
            sequenceId_,
            ts
        );
    }

    function _validateParams(bytes32 marketId_, address vault_) internal pure {
        if (marketId_ == bytes32(0)) revert InvalidMarket();
        if (vault_ == address(0)) revert InvalidAddress();
    }
}
