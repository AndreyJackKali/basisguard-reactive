// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { BasisGuardTypes } from "../src/BasisGuardTypes.sol";
import { OriginPerpOracle } from "../src/OriginPerpOracle.sol";
import { BasisGuardReactive } from "../src/BasisGuardReactive.sol";
import { DestinationHedgeVault } from "../src/DestinationHedgeVault.sol";

/// @notice Step 1: Deploy OriginPerpOracle on Origin Chain (Base Sepolia 84532 or Sepolia 11155111).
contract DeployOrigin is Script {
    function run() external returns (OriginPerpOracle oracle) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        oracle = new OriginPerpOracle(deployer);
        vm.stopBroadcast();

        console2.log("ORIGIN_ORACLE_ADDR=", address(oracle));
    }
}

/// @notice Step 2: Deploy BasisGuardReactive on Reactive Lasna Testnet (Chain ID 5318007).
///         Funds with 0.5 lREACT at deployment and auto-subscribes to all 3 OriginPerpOracle events.
contract DeployReactive is Script {
    function run() external returns (BasisGuardReactive sentinel) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address originOracle = vm.envAddress("ORIGIN_ORACLE_ADDR");
        uint256 destChainId = vm.envUint("DESTINATION_CHAIN_ID");
        uint256 fundWei = vm.envOr("REACTIVE_FUND_WEI", uint256(0.5 ether));

        BasisGuardTypes.RiskConfig memory cfg = BasisGuardTypes.RiskConfig({
            minHealthFactorBps: 11_500,
            targetHealthFactorBps: 15_000,
            emergencyHealthFactorBps: 10_500,
            maxBasisSpreadBps: 150,
            maxFundingRateBps: 250,
            minActionBps: 1_000,
            maxActionBps: 6_000,
            cooldownSeconds: 15,
            windowDurationSeconds: 60,
            maxCallbacksPerWindow: 5,
            callbackGasLimit: 1_000_000
        });

        vm.startBroadcast(pk);
        sentinel = new BasisGuardReactive{ value: fundWei }(
            originChainId,
            originOracle,
            destChainId,
            address(0), // Set in Step 4 after DestinationHedgeVault deployment
            cfg
        );
        vm.stopBroadcast();

        console2.log("REACTIVE_SENTINEL_ADDR=", address(sentinel));
    }
}

/// @notice Step 3: Deploy DestinationHedgeVault on Destination Chain (Base Sepolia 84532 / Unichain Sepolia 1301).
///         Funds with native testnet ETH to cover callback gas fees and registers a demo ETH-PERP vault.
contract DeployDestination is Script {
    function run() external returns (DestinationHedgeVault vault) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address callbackProxy = vm.envAddress("DESTINATION_CALLBACK_PROXY");
        address reactiveSentinel = vm.envAddress("REACTIVE_SENTINEL_ADDR");
        uint256 fundWei = vm.envOr("DESTINATION_FUND_WEI", uint256(0.05 ether));

        vm.startBroadcast(pk);
        vault = new DestinationHedgeVault{ value: fundWei }(
            IPayable(payable(callbackProxy)),
            reactiveSentinel,
            deployer
        );

        // Register a realistic $100k basis position on ETH-PERP for immediate live demo testing
        vault.registerPosition(
            keccak256("ETH-PERP"),
            deployer,
            11_000e8, // $11,000 collateral (1.10x HF)
            5_000e8, // $5,000 reserve buffer
            100_000e8, // $100,000 long spot
            100_000e8, // $100,000 short perp
            100, // 1.00% max slippage
            6_000 // 60% max single action
        );
        vm.stopBroadcast();

        console2.log("DESTINATION_VAULT_ADDR=", address(vault));
    }
}

/// @notice Step 4: Wire DestinationHedgeVault into BasisGuardReactive on Reactive Lasna.
contract WireDestination is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address reactiveSentinel = vm.envAddress("REACTIVE_SENTINEL_ADDR");
        uint256 destChainId = vm.envUint("DESTINATION_CHAIN_ID");
        address destVault = vm.envAddress("DESTINATION_VAULT_ADDR");

        vm.startBroadcast(pk);
        BasisGuardReactive(payable(reactiveSentinel)).setDestinationVault(destChainId, destVault);
        vm.stopBroadcast();

        console2.log("Wired destinationVault:", destVault, "on chainId:", destChainId);
    }
}

/// @notice Step 5: Emit a live HealthFactorCritical event on Origin Chain to trigger the autonomous loop.
contract TriggerLiveLoop is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address originOracle = vm.envAddress("ORIGIN_ORACLE_ADDR");

        vm.startBroadcast(pk);
        uint64 seq = OriginPerpOracle(originOracle).reportHealthFactor(
            keccak256("ETH-PERP"),
            deployer,
            10_800, // 1.08x critical health factor -> triggers autonomous deleverage!
            10_800e8,
            100_000e8
        );
        vm.stopBroadcast();

        console2.log("Triggered HealthFactorCritical sequenceId=", seq);
    }
}
