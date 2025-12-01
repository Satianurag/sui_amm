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
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Add Liquidity Workflow (Section 3.2.2)${NC}"
echo ""

if [ -z "$POOL_ID" ]; then
    echo "Error: POOL_ID not found in .env. Run 03_create_pool.sh first."
    exit 1
fi

echo -e "Pool ID: ${GREEN}$POOL_ID${NC}"
echo ""

# Get pool reserves to calculate correct ratio
echo -e "${BLUE}[1/4]${NC} Getting pool state..."
POOL_STATE=$(sui client object $POOL_ID --json)
RESERVE_A=$(echo "$POOL_STATE" | jq -r '.content.fields.reserve_a // .data.content.fields.reserve_a')
RESERVE_B=$(echo "$POOL_STATE" | jq -r '.content.fields.reserve_b // .data.content.fields.reserve_b')

echo -e "Current reserves: ${GREEN}$RESERVE_A SUI / $RESERVE_B USDC${NC}"

# Calculate amounts to add (maintaining ratio)
# We'll add 0.1 SUI worth of liquidity
SUI_AMOUNT=100000000  # 0.1 SUI
# USDC_AMOUNT = SUI_AMOUNT * RESERVE_B / RESERVE_A
USDC_AMOUNT=$(echo "scale=0; $SUI_AMOUNT * $RESERVE_B / $RESERVE_A" | bc)

echo -e "Adding: ${GREEN}$SUI_AMOUNT MIST / $USDC_AMOUNT USDC${NC} (maintaining pool ratio)"
echo ""

# Get coins
echo -e "${BLUE}[2/4]${NC} Preparing Coins..."
GAS_COINS=$(sui client gas --json)
SUI_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 1000000000) | .gasCoinId' | head -n 1)
# Get USDC coin with sufficient balance
USDC_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"Coin<\")) | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdc::USDC\")) | select((.data.content.fields.balance | tonumber) > $USDC_AMOUNT) | .data.objectId" | head -n 1)

if [ -z "$SUI_COIN" ]; then
    echo "Error: No SUI coin with at least 1 SUI found."
    echo "Run: sui client faucet"
    exit 1
fi

if [ -z "$USDC_COIN" ]; then
    echo "Error: No USDC coin with sufficient balance found."
    echo "Need at least $USDC_AMOUNT USDC. Run 02_create_test_coins.sh first."
    exit 1
fi

echo -e "SUI Coin: ${GREEN}$SUI_COIN${NC}"
echo -e "USDC Coin: ${GREEN}$USDC_COIN${NC}"
echo ""

echo "Splitting coins for liquidity addition..."
SPLIT_SUI_OUTPUT=$(sui client split-coin --coin-id $SUI_COIN --amounts $SUI_AMOUNT --gas-budget 50000000 --json 2>&1)
SPLIT_SUI=$(echo "$SPLIT_SUI_OUTPUT" | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

if [ -z "$SPLIT_SUI" ]; then
    echo "Error: Failed to split SUI"
    echo "$SPLIT_SUI_OUTPUT"
    exit 1
fi

SPLIT_USDC_OUTPUT=$(sui client split-coin --coin-id $USDC_COIN --amounts $USDC_AMOUNT --gas-budget 50000000 --json 2>&1)
SPLIT_USDC=$(echo "$SPLIT_USDC_OUTPUT" | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

if [ -z "$SPLIT_USDC" ]; then
    echo "Error: Failed to split USDC"
    echo "$SPLIT_USDC_OUTPUT"
    exit 1
fi

echo -e "Split SUI: ${GREEN}$SPLIT_SUI${NC}"
echo -e "Split USDC: ${GREEN}$SPLIT_USDC${NC}"
echo ""

CLOCK="0x6"
DEADLINE="18446744073709551615" 
MY_ADDRESS=$(sui client active-address)

echo -e "${BLUE}[3/4]${NC} Executing add_liquidity..."

# Use PTB to handle the returned tuple (position, refund_a, refund_b)
ADD_LIQ_OUTPUT=$(sui client ptb \
  --move-call "${PACKAGE_ID}::pool::add_liquidity<0x2::sui::SUI,${COIN_PACKAGE_ID}::usdc::USDC>" \
    @$POOL_ID \
    @$SPLIT_SUI \
    @$SPLIT_USDC \
    1u64 \
    @$CLOCK \
    ${DEADLINE}u64 \
  --assign result \
  --transfer-objects "[result.0, result.1, result.2]" @$MY_ADDRESS \
  --gas-budget 200000000 \
  --json 2>&1)

# Check for errors
if echo "$ADD_LIQ_OUTPUT" | jq -e '.effects.status.status == "failure"' > /dev/null 2>&1; then
    echo -e "${YELLOW}Error adding liquidity:${NC}"
    echo "$ADD_LIQ_OUTPUT" | jq -r '.effects.status.error // "Unknown error"'
    exit 1
fi

NEW_NFT_ID=$(echo "$ADD_LIQ_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null) | select(.objectType | contains("LPPosition")) | .objectId' | head -n 1)

echo -e "${BLUE}[4/4]${NC} Liquidity Added!"
echo ""
echo -e "Transaction Digest: $(echo "$ADD_LIQ_OUTPUT" | jq -r '.digest')"
echo -e "LP NFT ID: ${GREEN}$NEW_NFT_ID${NC}"
echo ""

# Update NFT_ID in .env if new one was created
if [ -n "$NEW_NFT_ID" ] && [ "$NEW_NFT_ID" != "null" ]; then
    # Remove old NFT_ID and add new one
    grep -v "^NFT_ID=" .env > .env.tmp 2>/dev/null || true
    mv .env.tmp .env
    echo "NFT_ID=$NEW_NFT_ID" >> .env
fi

echo -e "${GREEN}✓ Liquidity Added Successfully!${NC}"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ Add liquidity to existing pool"
echo "  ✓ New LP Position NFT minted"
echo "  ✓ Proportional liquidity calculation"
echo "  ✓ Ratio tolerance enforcement"
echo ""
echo -e "${YELLOW}Next: Run ./05_swap.sh${NC}"
