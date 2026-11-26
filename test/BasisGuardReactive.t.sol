// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import { BasisGuardTypes } from "../src/BasisGuardTypes.sol";
import { OriginPerpOracle } from "../src/OriginPerpOracle.sol";
import { BasisGuardReactive } from "../src/BasisGuardReactive.sol";
import { DestinationHedgeVault } from "../src/DestinationHedgeVault.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";

contract BasisGuardReactiveTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    bytes32 internal constant ETH_PERP = keccak256("ETH-PERP");
    address internal constant VAULT_A = address(0xA11CE);
    address internal constant ATTACKER = address(0xBAD0);

    MockSystemContract internal system;
    MockCallbackProxy internal callbackProxy;
    OriginPerpOracle internal oracle;
    BasisGuardReactive internal sentinel;
    DestinationHedgeVault internal destVault;

    function setUp() public {
        vm.warp(1_764_000_000);

        // Etch faithful Reactive Omni SYSTEM contract at 0x8888...8888
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        system = MockSystemContract(payable(SYSTEM_ADDR));

        callbackProxy = new MockCallbackProxy();
        oracle = new OriginPerpOracle(address(this));

        // Step 1: Deploy BasisGuardReactive on Reactive Lasna (subscribes to all 3 OriginPerpOracle topics)
        BasisGuardTypes.RiskConfig memory cfg = _defaultRiskConfig();
        sentinel = new BasisGuardReactive{ value: 1 ether }(
            BASE_SEPOLIA_CHAIN_ID,
            address(oracle),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(0),
            cfg
        );

        // Step 2: Deploy DestinationHedgeVault with Callback Proxy + immutable Reactive Sentinel address
        destVault = new DestinationHedgeVault{ value: 0.5 ether }(
            IPayable(payable(address(callbackProxy))),
            address(sentinel),
            address(this)
        );

        // Step 3: Wire DestinationHedgeVault on BasisGuardReactive
        sentinel.setDestinationVault(UNICHAIN_SEPOLIA_CHAIN_ID, address(destVault));

        // Register an active $100k hedged basis-trade position with $11k collateral (HF = 1.10x) & $5k reserve
        destVault.registerPosition(
            ETH_PERP,
            VAULT_A,
            11_000e8, // collateral ($11,000)
            5_000e8, // reserve buffer ($5,000)
            100_000e8, // long spot ($100,000)
            100_000e8, // short perp ($100,000) -> 10% maint = $10k -> HF = 11,000 bps (1.10x)
            100, // max slippage 1.00%
            6_000 // max single action magnitude 60%
        );
    }

    /*//////////////////////////////////////////////////////////////
                       1. END-TO-END HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSubscribesAllThreeTopics() public view {
        assertEq(system.activeSubscriptionCount(address(sentinel)), 3);
        assertEq(address(sentinel._SERVICE_PROVIDER()), SYSTEM_ADDR);
        assertEq(destVault._CALLBACK_SENDER(), address(sentinel));
        assertEq(address(destVault._SERVICE_PROVIDER()), address(callbackProxy));
    }

    function test_E2E_HealthCritical_TriggersEmergencyDeleverageAndImprovesHF() public {
        (uint256 colBefore,,, uint256 perpBefore, uint256 hfBefore,,,,) = destVault.positions(ETH_PERP, VAULT_A);
        assertEq(hfBefore, 11_000); // 1.10x

        // 1. Origin chain emits HealthFactorCritical (HF = 1.10x < 1.15x min threshold)
        vm.recordLogs();
        uint64 seq = oracle.reportHealthFactor(ETH_PERP, VAULT_A, 11_000, colBefore, perpBefore);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 2. Reactive Omni ingests log and triggers BasisGuardReactive.react()
        uint256 queuedBefore = system.getQueuedCallbackCount();
        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x1111, 0);
        assertEq(system.getQueuedCallbackCount(), queuedBefore + 1);
        assertEq(sentinel.totalCallbacksDispatched(), 1);

        // 3. Reactive Signer relays queued callback through Destination Callback Proxy (overwriting arg0!)
        MockSystemContract.QueuedCallback memory cb = system.getQueuedCallback(queuedBefore);
        assertEq(cb.chainId, UNICHAIN_SEPOLIA_CHAIN_ID);
        assertEq(cb.recipient, address(destVault));
        assertEq(cb.sender, address(sentinel));

        callbackProxy.deliverCallback(cb.sender, cb.recipient, cb.payload);

        // 4. Verify DestinationHedgeVault state improved & audit receipt persisted
        (uint256 colAfter,, uint256 spotAfter, uint256 perpAfter, uint256 hfAfter,,,,) =
            destVault.positions(ETH_PERP, VAULT_A);
        assertLt(perpAfter, perpBefore, "perp exposure should decrease");
        assertLt(spotAfter, 100_000e8, "spot leg should unwind proportionally");
        assertGt(hfAfter, hfBefore, "health factor must strictly improve");
        assertLt(colAfter, colBefore, "slippage cost deducted transparently");

        bytes32 actionId = sentinel.lastDispatchedActionId();
        assertTrue(destVault.executedActions(actionId));
        assertEq(destVault.getVaultReceiptCount(VAULT_A), 1);

        DestinationHedgeVault.ExecutionReceipt memory r = destVault.getReceipt(actionId);
        assertEq(r.reactiveSender, address(sentinel));
        assertEq(uint8(r.actionType), uint8(BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE));
        assertEq(r.originSequence, seq);
        assertEq(r.healthBeforeBps, hfBefore);
        assertEq(r.healthAfterBps, hfAfter);
    }

    function test_E2E_SpreadDiverged_TriggersHedgeRebalance() public {
        // Give Vault A a delta imbalance (110k spot vs 100k short perp)
        destVault.registerPosition(ETH_PERP, VAULT_A, 15_000e8, 5_000e8, 110_000e8, 100_000e8, 100, 6_000);

        // Mark $3,090 vs Index $3,000 -> +300 bps (+3.0%) positive basis divergence >= 150 bps threshold
        vm.recordLogs();
        (int256 spreadBps,) = oracle.reportSpreadDivergence(ETH_PERP, VAULT_A, 3_090e8, 3_000e8, 120);
        assertEq(spreadBps, 300);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x2222, 0);
        MockSystemContract.QueuedCallback memory cb = system.getQueuedCallback(0);
        callbackProxy.deliverCallback(cb.sender, cb.recipient, cb.payload);

        (,, uint256 spotAfter, uint256 perpAfter,,,,,) = destVault.positions(ETH_PERP, VAULT_A);
        assertLt(spotAfter, 110_000e8, "long spot excess trimmed toward delta neutral");
        assertEq(perpAfter, 100_000e8);
        assertEq(destVault.totalProtectionsExecuted(), 1);
    }

    function test_E2E_FundingRateSpiked_TriggersCollateralTopUp() public {
        (uint256 colBefore, uint256 resBefore,,, uint256 hfBefore,,,,) = destVault.positions(ETH_PERP, VAULT_A);

        // Funding spikes to -400 bps (|400| >= 250 bps threshold)
        vm.recordLogs();
        oracle.reportFundingSpike(ETH_PERP, VAULT_A, -400, 2_990e8, 3_000e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x3333, 0);
        MockSystemContract.QueuedCallback memory cb = system.getQueuedCallback(0);
        callbackProxy.deliverCallback(cb.sender, cb.recipient, cb.payload);

        (uint256 colAfter, uint256 resAfter,,, uint256 hfAfter,,,,) = destVault.positions(ETH_PERP, VAULT_A);
        assertGt(colAfter, colBefore, "collateral topped up from reserve");
        assertLt(resAfter, resBefore, "reserve buffer consumed");
        assertEq(colAfter + resAfter, colBefore + resBefore, "zero slippage internal reserve move");
        assertGt(hfAfter, hfBefore, "health factor improved via top-up");
    }

    /*//////////////////////////////////////////////////////////////
                2. THRESHOLD, COOLDOWN, REPLAY, BREAKER
    //////////////////////////////////////////////////////////////*/

    function test_BelowThresholdEventsAreSuppressedWithoutCallback() public {
        // Healthy HF (1.40x >= 1.15x), tight spread (+50 bps < 150 bps), calm funding (+80 bps < 250 bps)
        vm.recordLogs();
        oracle.reportHealthFactor(ETH_PERP, VAULT_A, 14_000, 14_000e8, 100_000e8);
        oracle.reportSpreadDivergence(ETH_PERP, VAULT_A, 3_015e8, 3_000e8, 80);
        oracle.reportFundingSpike(ETH_PERP, VAULT_A, 80, 3_000e8, 3_000e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x4441, 0);
        _relayLogToReactive(logs[1], BASE_SEPOLIA_CHAIN_ID, 0x4442, 1);
        _relayLogToReactive(logs[2], BASE_SEPOLIA_CHAIN_ID, 0x4443, 2);

        assertEq(system.getQueuedCallbackCount(), 0);
        assertEq(sentinel.totalSuppressedThreshold(), 3);
    }

    function test_CooldownEnforcedAndEmergencyHealthBypassWorks() public {
        // First warning HF (1.10x): dispatches callback
        vm.recordLogs();
        oracle.reportHealthFactor(ETH_PERP, VAULT_A, 11_000, 11_000e8, 100_000e8);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        _relayLogToReactive(logs1[0], BASE_SEPOLIA_CHAIN_ID, 0x5551, 0);
        assertEq(system.getQueuedCallbackCount(), 1);

        // 5 seconds later (< 15s cooldown), another non-emergency warning (1.09x >= 1.05x): SUPPRESSED
        vm.warp(block.timestamp + 5);
        vm.recordLogs();
        oracle.reportHealthFactor(ETH_PERP, VAULT_A, 10_900, 10_900e8, 100_000e8);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        _relayLogToReactive(logs2[0], BASE_SEPOLIA_CHAIN_ID, 0x5552, 0);
        assertEq(system.getQueuedCallbackCount(), 1);
        assertEq(sentinel.totalSuppressedCooldown(), 1);

        // 2 seconds later (still inside cooldown!), EXTREME liquidation danger (1.03x < 1.05x): BYPASSES COOLDOWN!
        vm.warp(block.timestamp + 2);
        vm.recordLogs();
        oracle.reportHealthFactor(ETH_PERP, VAULT_A, 10_300, 10_300e8, 100_000e8);
        Vm.Log[] memory logs3 = vm.getRecordedLogs();
        _relayLogToReactive(logs3[0], BASE_SEPOLIA_CHAIN_ID, 0x5553, 0);
        assertEq(system.getQueuedCallbackCount(), 2, "critical HF must bypass cooldown");
    }

    function test_ReplayAndStaleSequenceBlockedOnBothChains() public {
        vm.recordLogs();
        oracle.reportFundingSpike(ETH_PERP, VAULT_A, 400, 3_010e8, 3_000e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Deliver once -> succeeds
        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x6661, 0);
        assertEq(system.getQueuedCallbackCount(), 1);

        // Replay exact same log to Reactive sentinel -> suppressed
        vm.warp(block.timestamp + 60);
        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x6661, 0);
        assertEq(system.getQueuedCallbackCount(), 1);
        assertEq(sentinel.totalSuppressedReplay(), 1);

        // Deliver callback to Destination -> succeeds once
        MockSystemContract.QueuedCallback memory cb = system.getQueuedCallback(0);
        callbackProxy.deliverCallback(cb.sender, cb.recipient, cb.payload);

        // Replay exact same callback at Destination -> reverts ActionAlreadyExecuted
        vm.expectRevert(
            abi.encodeWithSelector(
                DestinationHedgeVault.ActionAlreadyExecuted.selector, sentinel.lastDispatchedActionId()
            )
        );
        callbackProxy.deliverCallback(cb.sender, cb.recipient, cb.payload);
    }

    function test_E2E_NegativeBasisSpread_TrimsBackwardationExposure() public {
        // Mark $2,925 vs Index $3,000 -> -250 bps (-2.5%) negative basis divergence
        vm.recordLogs();
        (int256 spreadBps,) = oracle.reportSpreadDivergence(ETH_PERP, VAULT_A, 2_925e8, 3_000e8, -180);
        assertEq(spreadBps, -250);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x2223, 0);
        MockSystemContract.QueuedCallback memory cb = system.getQueuedCallback(0);
        callbackProxy.deliverCallback(cb.sender, cb.recipient, cb.payload);

        (,, uint256 spotAfter, uint256 perpAfter, uint256 hfAfter,,,,) = destVault.positions(ETH_PERP, VAULT_A);
        assertLt(spotAfter, 100_000e8, "spot trimmed on negative basis");
        assertLt(perpAfter, 100_000e8, "perp trimmed on negative basis");
        assertGt(hfAfter, 11_000, "trimming negative carry improves margin safety");
    }

    function test_Security_UnauthorizedAdminCallsRevert() public {
        vm.startPrank(ATTACKER);

        vm.expectRevert(abi.encodeWithSelector(OriginPerpOracle.Unauthorized.selector, ATTACKER));
        oracle.reportHealthFactor(ETH_PERP, VAULT_A, 10_000, 10_000e8, 100_000e8);

        vm.expectRevert(abi.encodeWithSelector(BasisGuardReactive.Unauthorized.selector, ATTACKER));
        sentinel.pause();

        vm.expectRevert(abi.encodeWithSelector(BasisGuardReactive.Unauthorized.selector, ATTACKER));
        sentinel.setDestinationVault(BASE_SEPOLIA_CHAIN_ID, ATTACKER);

        vm.expectRevert(abi.encodeWithSelector(DestinationHedgeVault.Unauthorized.selector, ATTACKER));
        destVault.setPositionBounds(ETH_PERP, VAULT_A, 50, 5_000);

        vm.stopPrank();
    }

    function test_CircuitBreakerTripsWithinSingleWindowAndResets() public {
        address[4] memory vaults = [address(0x101), address(0x102), address(0x103), address(0x104)];

        // 3 callbacks in same second hit maxCallbacksPerWindow (3); 4th trips breaker!
        for (uint256 i = 0; i < 4; i++) {
            vm.recordLogs();
            oracle.reportFundingSpike(ETH_PERP, vaults[i], 350, 3_010e8, 3_000e8);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _relayLogToReactive(logs[0], BASE_SEPOLIA_CHAIN_ID, 0x8800 + i, 0);
        }

        assertEq(system.getQueuedCallbackCount(), 3);
        assertEq(sentinel.totalSuppressedCircuitBreaker(), 1);

        // Advance past windowDurationSeconds (60s) -> breaker resets cleanly!
        vm.warp(block.timestamp + 61);
        vm.recordLogs();
        oracle.reportFundingSpike(ETH_PERP, vaults[3], 350, 3_010e8, 3_000e8);
        Vm.Log[] memory logsAfter = vm.getRecordedLogs();
        _relayLogToReactive(logsAfter[0], BASE_SEPOLIA_CHAIN_ID, 0x8899, 0);
        assertEq(system.getQueuedCallbackCount(), 4);
    }

    function test_PauseUnsubscribesAndUnpauseResubscribes() public {
        assertEq(system.activeSubscriptionCount(address(sentinel)), 3);

        sentinel.pause();
        assertTrue(sentinel.paused());
        assertEq(system.activeSubscriptionCount(address(sentinel)), 0);

        sentinel.unpause();
        assertFalse(sentinel.paused());
        assertEq(system.activeSubscriptionCount(address(sentinel)), 3);
    }

    /*//////////////////////////////////////////////////////////////
                     3. SECURITY & ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_Security_RejectsDirectReactFromNonSystem() public {
        IReactive.LogRecord memory fakeLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(oracle),
            topic0: BasisGuardTypes.HEALTH_CRITICAL_TOPIC_0,
            topic1: uint256(ETH_PERP),
            topic2: uint256(uint160(VAULT_A)),
            topic3: 0,
            data: abi.encode(uint256(10_500), uint256(10_500e8), uint256(100_000e8), uint64(1), uint64(block.timestamp)),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 1,
            txHash: 1,
            logIndex: 0
        });

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, ATTACKER, SYSTEM_ADDR));
        sentinel.react(fakeLog);
    }

    function test_Security_RejectsDirectDestinationCallBypassingProxy() public {
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, ATTACKER, address(callbackProxy))
        );
        destVault.executeProtection(
            address(sentinel),
            keccak256("forged"),
            ETH_PERP,
            VAULT_A,
            uint8(BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE),
            2_000,
            10_500,
            1
        );
    }

    function test_Security_RejectsSpoofedReactiveSenderViaProxy() public {
        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,bytes32,bytes32,address,uint8,uint256,int256,uint64)",
            address(0),
            keccak256("spoofed"),
            ETH_PERP,
            VAULT_A,
            uint8(BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE),
            2_000,
            10_500,
            1
        );

        // Even when called through the real Callback Proxy, an unauthorized reactive contract MUST revert!
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, ATTACKER, address(sentinel))
        );
        callbackProxy.deliverCallback(ATTACKER, address(destVault), payload);
    }

    function test_Security_SlippageGuardRevertsExcessiveImpact() public {
        // Set tight 10 bps max slippage on Vault A; 50% (5000 bps) deleverage estimates 25 bps slippage -> reverts!
        destVault.setPositionBounds(ETH_PERP, VAULT_A, 10, 6_000);

        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,bytes32,bytes32,address,uint8,uint256,int256,uint64)",
            address(0),
            keccak256("high-slippage"),
            ETH_PERP,
            VAULT_A,
            uint8(BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE),
            5_000,
            10_200,
            1
        );

        vm.expectRevert(abi.encodeWithSelector(DestinationHedgeVault.SlippageExceeded.selector, 25, 10));
        callbackProxy.deliverCallback(address(sentinel), address(destVault), payload);
    }

    /*//////////////////////////////////////////////////////////////
                      4. REACTIVE OMNI ECONOMY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Economy_PayAndCoverDebtOnBothChains() public {
        // Simulate Reactive SYSTEM charging sentinel + settling outstanding debt
        system.setDebt(address(sentinel), 0.05 ether);
        uint256 sysBalBefore = address(system).balance;
        sentinel.coverDebt();
        assertEq(system.debt(address(sentinel)), 0);
        assertEq(address(system).balance, sysBalBefore + 0.05 ether);

        // Simulate Destination Callback Proxy charging destVault via pay() and coverDebt()
        callbackProxy.setDebt(address(destVault), 0.02 ether);
        uint256 proxyBalBefore = address(callbackProxy).balance;
        destVault.coverDebt();
        assertEq(callbackProxy.debt(address(destVault)), 0);
        assertEq(address(callbackProxy).balance, proxyBalBefore + 0.02 ether);

        // Direct pay() call from service provider
        callbackProxy.charge(address(destVault), 0.01 ether);
        assertEq(address(callbackProxy).balance, proxyBalBefore + 0.03 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           5. FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BasisSpreadMathSignAndConsistency(uint256 markPrice, uint256 indexPrice) public view {
        markPrice = bound(markPrice, 1e6, 1_000_000e8);
        indexPrice = bound(indexPrice, 1e6, 1_000_000e8);

        int256 spread = oracle.computeBasisSpreadBps(markPrice, indexPrice);
        if (markPrice > indexPrice) {
            assertGe(spread, 0);
        } else if (markPrice < indexPrice) {
            assertLe(spread, 0);
        } else {
            assertEq(spread, 0);
        }
    }

    function testFuzz_DeleverageAlwaysBoundedAndImprovesHealthyMargin(uint256 healthFactorBps) public {
        healthFactorBps = bound(healthFactorBps, 1_000, 11_499); // strictly below 11,500 min threshold

        uint256 mag = sentinel.computeDeleverageBps(healthFactorBps);
        assertGe(mag, 1_000);
        assertLe(mag, 6_000);

        // Construct a position whose collateral matches healthFactorBps for $100k short perp (maint = $10k)
        uint256 collateral = (10_000e8 * healthFactorBps) / 10_000;
        address fuzzVault = address(0xF022);
        destVault.registerPosition(ETH_PERP, fuzzVault, collateral, 5_000e8, 100_000e8, 100_000e8, 100, 6_000);

        (,,,, uint256 hfBefore,,,,) = destVault.positions(ETH_PERP, fuzzVault);

        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,bytes32,bytes32,address,uint8,uint256,int256,uint64)",
            address(0),
            keccak256(abi.encode("fuzz-delev", healthFactorBps)),
            ETH_PERP,
            fuzzVault,
            uint8(BasisGuardTypes.ActionType.EMERGENCY_DELEVERAGE),
            mag,
            int256(healthFactorBps),
            1
        );
        callbackProxy.deliverCallback(address(sentinel), address(destVault), payload);

        (,,,, uint256 hfAfter,,,,) = destVault.positions(ETH_PERP, fuzzVault);
        assertGt(hfAfter, hfBefore, "deleverage must always strictly improve HF");
    }

    function testFuzz_SpreadAndFundingMagnitudeBounds(int256 rawMetric) public view {
        rawMetric = bound(rawMetric, -50_000, 50_000);

        uint256 reb = sentinel.computeRebalanceBps(rawMetric);
        if (rawMetric > -150 && rawMetric < 150) {
            assertEq(reb, 0);
        } else {
            assertGe(reb, 1_000);
            assertLe(reb, 6_000);
        }

        uint256 top = sentinel.computeTopUpBps(rawMetric);
        if (rawMetric > -250 && rawMetric < 250) {
            assertEq(top, 0);
        } else {
            assertGe(top, 1_000);
            assertLe(top, 6_000);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultRiskConfig() internal pure returns (BasisGuardTypes.RiskConfig memory) {
        return BasisGuardTypes.RiskConfig({
            minHealthFactorBps: 11_500, // 1.15x
            targetHealthFactorBps: 15_000, // 1.50x
            emergencyHealthFactorBps: 10_500, // 1.05x (bypasses cooldown)
            maxBasisSpreadBps: 150, // 1.50%
            maxFundingRateBps: 250, // 2.50%
            minActionBps: 1_000, // 10%
            maxActionBps: 6_000, // 60%
            cooldownSeconds: 15, // 15s cooldown
            windowDurationSeconds: 60, // 60s rolling circuit-breaker window
            maxCallbacksPerWindow: 3, // max 3 callbacks per 60s window
            callbackGasLimit: 1_000_000 // matches Reactive Omni official demo gas limit (incl. proxy overhead)
        });
    }

    function _relayLogToReactive(Vm.Log memory emitted, uint256 chainId_, uint256 txHash_, uint256 logIndex_)
        internal
    {
        IReactive.LogRecord memory rec = IReactive.LogRecord({
            chainId: chainId_,
            contractAddress: emitted.emitter,
            topic0: uint256(emitted.topics[0]),
            topic1: emitted.topics.length > 1 ? uint256(emitted.topics[1]) : 0,
            topic2: emitted.topics.length > 2 ? uint256(emitted.topics[2]) : 0,
            topic3: emitted.topics.length > 3 ? uint256(emitted.topics[3]) : 0,
            data: emitted.data,
            blockNumber: block.number,
            opCode: emitted.topics.length,
            blockHash: uint256(blockhash(block.number > 0 ? block.number - 1 : 0)),
            txHash: txHash_,
            logIndex: logIndex_
        });

        system.trigger(address(sentinel), rec);
    }
}
