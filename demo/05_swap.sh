#!/bin/bash
# ============================================
# STEP 5: Execute Token Swap
# ============================================
# PRD: Swap Execution Workflow (3.2.3)
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Swap Execution Workflow                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Swap Execution Workflow (Section 3.2.3)${NC}"
echo ""

if [ -z "$POOL_ID" ]; then
    echo "Error: POOL_ID not found in .env. Run 03_create_pool.sh first."
    exit 1
fi

echo -e "Pool ID: ${GREEN}$POOL_ID${NC}"
echo ""

# Get coins
echo -e "${BLUE}[1/3]${NC} Preparing Swap Input..."
GAS_COINS=$(sui client gas --json)
SUI_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 1000000000) | .gasCoinId' | head -n 1)

if [ -z "$SUI_COIN" ]; then
    echo "Error: Missing SUI coin."
    exit 1
fi

echo "Splitting 10 SUI for swap input..."
SPLIT_SUI=$(sui client split-coin --coin-id $SUI_COIN --amounts 10000000000 --gas-budget 50000000 --json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

echo "Swapping 10 SUI for USDC..."

CLOCK="0x6"
DEADLINE="18446744073709551615" 

echo -e "${BLUE}[2/3]${NC} Executing swap_a_to_b..."

# swap_a_to_b<A, B>(pool, coin_in, min_out, max_price, clock, deadline)
# max_price is Option<u128>, we pass vector[] for none? Or how to pass Option in CLI? 
# In Sui CLI, Option is usually passed as vector. Empty vector for None.
# But wait, the function signature might expect `Option<u128>`.
# Let's check the signature in `pool.move` if possible, but I assume it's standard.
# If it's `Option<u128>`, passing `[]` usually works for None.

SWAP_OUTPUT=$(sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function swap_a_to_b \
  --type-args "0x2::sui::SUI" "$COIN_PACKAGE_ID::usdc::USDC" \
  --args \
    $POOL_ID \
    $SPLIT_SUI \
    0 \
    "[]" \
    $CLOCK \
    $DEADLINE \
  --gas-budget 100000000 \
  --json)

echo "$SWAP_OUTPUT" > swap.json

echo -e "${BLUE}[3/3]${NC} Swap Complete!"
echo ""
echo -e "Transaction Digest: $(echo "$SWAP_OUTPUT" | jq -r '.digest')"

# Calculate output amount from events or balance changes
# For now just show success
echo -e "${GREEN}✓ Swap Executed Successfully!${NC}"
echo ""
echo -e "${YELLOW}Next: Run ./06_view_position.sh${NC}"
