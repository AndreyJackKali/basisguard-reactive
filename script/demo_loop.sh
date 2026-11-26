#!/usr/bin/env bash
set -euo pipefail

# BasisGuard Reactive — End-to-End Reactive Omni Testnet Deployment & Trigger Script
# Prereqs:
#   1. Copy .env.example to .env and populate PRIVATE_KEY
#   2. Fund deployer wallet on Base Sepolia (~0.2 ETH) and swap 0.1 ETH -> 10 lREACT via:
#      cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
#        --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" \
#        "request(address)" "$(cast wallet address --private-key "$PRIVATE_KEY")" --value 0.1ether

source .env

FORGE="${FORGE:-forge}"
CAST="${CAST:-cast}"

echo "=== Step 1: Deploy OriginPerpOracle on Origin Chain (Chain ID: $ORIGIN_CHAIN_ID) ==="
$FORGE script script/Deploy.s.sol:DeployOrigin --rpc-url "$BASE_SEPOLIA_RPC" --broadcast -vv

echo "Export ORIGIN_ORACLE_ADDR from output above, then press Enter (or re-run Steps 2-5 with env populated)."
echo "=== Step 2: Deploy BasisGuardReactive on Reactive Lasna (Chain ID: 5318007) ==="
echo "$FORGE script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --broadcast -vv"

echo "=== Step 3: Deploy DestinationHedgeVault on Destination Chain (Chain ID: $DESTINATION_CHAIN_ID) ==="
echo "DESTINATION_CALLBACK_PROXY=$BASE_SEPOLIA_CALLBACK_PROXY $FORGE script script/Deploy.s.sol:DeployDestination --rpc-url $BASE_SEPOLIA_RPC --broadcast -vv"

echo "=== Step 4: Wire DestinationHedgeVault on BasisGuardReactive (Lasna) ==="
echo "$FORGE script script/Deploy.s.sol:WireDestination --rpc-url $LASNA_RPC --broadcast -vv"

echo "=== Step 5: Trigger Live HealthFactorCritical Event on Origin Chain ==="
echo "$FORGE script script/Deploy.s.sol:TriggerLiveLoop --rpc-url $BASE_SEPOLIA_RPC --broadcast -vv"

echo "=== Step 6: Inspect Delivered Callbacks via Reactive SYSTEM Contract ==="
echo "$CAST call $LASNA_SYSTEM_CONTRACT \"getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])\" \$REACTIVE_TX_HASH --rpc-url $LASNA_RPC"
