#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  set -a; source .env; set +a
fi

# ── Config ────────────────────────────────────────────────────────────
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
DEPLOYER_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
DEPLOYER_ADDR=$(cast wallet address "$DEPLOYER_KEY")
AGENT_ADDR="${AGENT_ADDRESS:-$DEPLOYER_ADDR}"
FACTORY_ADDR="${FACTORY_ADDRESS:-}"
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
FUND_USDC_HEX=0x000000000000000000000000000000000000000000000000000000003b9aca00  # 1000 * 1e6

echo "=== Setup ==="
echo "Deployer: $DEPLOYER_ADDR"
echo "Agent:    $AGENT_ADDR"
if [ -n "$FACTORY_ADDR" ]; then
  echo "Factory:  $FACTORY_ADDR"
fi

json_rpc() {
  local method="$1"
  local params="$2"
  curl -sS -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
}

# ── Step 1: Fund agent with 10 ETH ────────────────────────────────────
echo ""
echo "1. Funding agent with 10 ETH..."
json_rpc "anvil_setBalance" "[\"$AGENT_ADDR\",\"0x8AC7230489E80000\"]" > /dev/null
echo "   Done."

# ── Step 2: Deploy factory + vault via forge script ───────────────────
echo ""
echo "2. Deploying factory + vault..."
OUTPUT=$(PRIVATE_KEY="$DEPLOYER_KEY" AGENT_ADDRESS="$AGENT_ADDR" FACTORY_ADDRESS="$FACTORY_ADDR" \
  forge script script/DeployVault.s.sol:DeployVault \
    --rpc-url "$RPC_URL" \
    --broadcast 2>&1)

echo "$OUTPUT" | grep -E "(Factory|Using factory|Vault|Owner|Agent|ETH balance)" || true

# Extract factory and vault address from output
FACTORY_FROM_OUTPUT=$(echo "$OUTPUT" | grep -E "Factory:" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
VAULT_ADDR=$(echo "$OUTPUT" | grep "Vault:" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)

if [ -z "$VAULT_ADDR" ]; then
  echo "ERROR: Could not extract vault address from output"
  echo "$OUTPUT"
  exit 1
fi

echo ""
if [ -n "$FACTORY_FROM_OUTPUT" ]; then
  echo "Factory: $FACTORY_FROM_OUTPUT"
fi
echo "   Vault: $VAULT_ADDR"

# ── Step 3: Fund vault with 1000 USDC ─────────────────────────────────
echo ""
echo "3. Funding vault with 1000 USDC..."
# USDC balances mapping at slot 9: keccak256(abi.encode(vaultAddr, 9))
VAULT_USDC_SLOT=$(cast index address "$VAULT_ADDR" 9)
json_rpc "anvil_setStorageAt" "[\"$USDC\",\"$VAULT_USDC_SLOT\",\"$FUND_USDC_HEX\"]" > /dev/null

# Verify
USDC_BAL=$(cast call "$USDC" "balanceOf(address)(uint256)" "$VAULT_ADDR" --rpc-url "$RPC_URL")
echo "   Vault USDC balance: $USDC_BAL"

# ── Summary ───────────────────────────────────────────────────────────
VAULT_ETH=$(cast balance "$VAULT_ADDR" --rpc-url "$RPC_URL")
AGENT_ETH=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC_URL")

echo ""
echo "=== Deployment Complete ==="
if [ -n "$FACTORY_FROM_OUTPUT" ]; then
  echo "Factory:     $FACTORY_FROM_OUTPUT"
fi
echo "Vault:       $VAULT_ADDR"
echo "Vault ETH:   $VAULT_ETH"
echo "Vault USDC:  $USDC_BAL"
echo "Agent:       $AGENT_ADDR"
echo "Agent ETH:   $AGENT_ETH"
