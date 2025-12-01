#!/bin/bash
# ============================================
# STEP 4: Add Liquidity & Mint NFT Position
# ============================================
# PRD: Add Liquidity Workflow (3.2.2)
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Add Liquidity Workflow                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Add Liquidity Workflow (Section 3.2.2)${NC}"
echo ""

if [ -z "$POOL_ID" ]; then
    echo "Error: POOL_ID not found in .env. Run 03_create_pool.sh first."
    exit 1
fi

echo -e "Pool ID: ${GREEN}$POOL_ID${NC}"
echo ""

# Get coins
echo -e "${BLUE}[1/3]${NC} Preparing Coins..."
GAS_COINS=$(sui client gas --json)
SUI_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 1000000000) | .gasCoinId' | head -n 1)
USDC_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdc::USDC\")) | .data.objectId" | head -n 1)

if [ -z "$SUI_COIN" ] || [ -z "$USDC_COIN" ]; then
    echo "Error: Missing coins."
    exit 1
fi

echo "Splitting coins for liquidity addition..."
# Split 50 SUI
SPLIT_SUI=$(sui client split-coin --coin-id $SUI_COIN --amounts 50000000000 --gas-budget 50000000 --json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)
# Split 50 USDC
SPLIT_USDC=$(sui client split-coin --coin-id $USDC_COIN --amounts 50000000 --gas-budget 50000000 --json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

echo "Adding 50 SUI and 50 USDC..."

CLOCK="0x6"
# Deadline: current time + 20 mins (in ms). 
# Since we can't easily get on-chain time, we'll use a large number or just current timestamp + offset
# For localnet, we can just use a large number.
DEADLINE="18446744073709551615" 

echo -e "${BLUE}[2/3]${NC} Executing add_liquidity..."

ADD_LIQ_OUTPUT=$(sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function add_liquidity \
  --type-args "0x2::sui::SUI" "$COIN_PACKAGE_ID::usdc::USDC" \
  --args \
    $POOL_ID \
    $SPLIT_SUI \
    $SPLIT_USDC \
    1 \
    $CLOCK \
    $DEADLINE \
  --gas-budget 100000000 \
  --json)

echo "$ADD_LIQ_OUTPUT" > add_liquidity.json

# Extract new NFT ID if created (it might be created or updated, but here we likely get a new one or same one?)
# Wait, add_liquidity mints a NEW NFT position every time? 
# PRD says "Mint LP tokens and create/update NFT position". 
# The contract likely mints a new NFT for each position or adds to existing?
# Usually Uniswap V3 style is NFT per position.
# Let's check the output for created objects.
NEW_NFT_ID=$(echo "$ADD_LIQ_OUTPUT" | jq -r '.objectChanges[] | select(.objectType | contains("LPPosition")) | .objectId' | head -n 1)

echo -e "${BLUE}[3/3]${NC} Liquidity Added!"
echo ""
echo -e "Transaction Digest: $(echo "$ADD_LIQ_OUTPUT" | jq -r '.digest')"
echo -e "LP NFT ID: ${GREEN}$NEW_NFT_ID${NC}"
echo ""

echo -e "${GREEN}✓ Liquidity Added Successfully!${NC}"
echo ""
echo -e "${YELLOW}Next: Run ./05_swap.sh${NC}"
