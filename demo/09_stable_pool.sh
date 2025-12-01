#!/bin/bash
# ============================================
# STEP 9: StableSwap Pool Demo
# ============================================
# PRD: StableSwap Pool (2.1.4)
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          StableSwap Pool Demo                              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: StableSwap Pool (Section 2.1.4)${NC}"
echo ""

echo -e "${BLUE}[1/3]${NC} Creating Stable Pool (USDC-USDT)..."

# Get coins
GAS_COINS=$(sui client gas --json)
CREATION_FEE_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 5000000000) | .gasCoinId' | head -n 1)
USDC_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdc::USDC\")) | .data.objectId" | head -n 1)
USDT_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdt::USDT\")) | .data.objectId" | head -n 1)

if [ -z "$USDC_COIN" ] || [ -z "$USDT_COIN" ]; then
    echo "Error: Missing coins."
    exit 1
fi

# Split coins for liquidity
SPLIT_USDC=$(sui client split-coin --coin-id $USDC_COIN --amounts 1000000000 --gas-budget 50000000 --json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)
SPLIT_USDT=$(sui client split-coin --coin-id $USDT_COIN --amounts 1000000000 --gas-budget 50000000 --json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

CLOCK="0x6"

# create_stable_pool<A, B>(registry, stats, fee, creator_fee, amp, coin_a, coin_b, fee_coin, clock)
# amp = 100 (amplification coefficient)

CREATE_STABLE_OUTPUT=$(sui client call \
  --package $PACKAGE_ID \
  --module factory \
  --function create_stable_pool \
  --type-args "$COIN_PACKAGE_ID::usdc::USDC" "$COIN_PACKAGE_ID::usdt::USDT" \
  --args \
    $POOL_REGISTRY \
    $STATS_REGISTRY \
    5 \
    0 \
    100 \
    $SPLIT_USDC \
    $SPLIT_USDT \
    $CREATION_FEE_COIN \
    $CLOCK \
  --gas-budget 100000000 \
  --json)

STABLE_POOL_ID=$(echo "$CREATE_STABLE_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null) | select(.objectType | contains("LiquidityPool")) | .objectId' | head -n 1)

echo -e "Stable Pool ID: ${GREEN}$STABLE_POOL_ID${NC}"
echo ""

echo -e "${BLUE}[2/3]${NC} Swapping in Stable Pool..."

# Swap 10 USDC for USDT
SPLIT_SWAP_USDC=$(sui client call --package 0x2 --module coin --function split --type-args "$COIN_PACKAGE_ID::usdc::USDC" --args $USDC_COIN "10000000" --gas-budget 50000000 --json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

DEADLINE="18446744073709551615"

SWAP_OUTPUT=$(sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function swap_a_to_b \
  --type-args "$COIN_PACKAGE_ID::usdc::USDC" "$COIN_PACKAGE_ID::usdt::USDT" \
  --args \
    $STABLE_POOL_ID \
    $SPLIT_SWAP_USDC \
    0 \
    "[]" \
    $CLOCK \
    $DEADLINE \
  --gas-budget 100000000 \
  --json)

echo "$SWAP_OUTPUT" > stable_swap.json

echo -e "${BLUE}[3/3]${NC} Stable Swap Complete!"
echo ""
echo -e "Transaction Digest: $(echo "$SWAP_OUTPUT" | jq -r '.digest')"

echo -e "${GREEN}✓ Stable Pool Demo Complete!${NC}"
echo ""
echo -e "${YELLOW}Demo Walkthrough Finished!${NC}"
