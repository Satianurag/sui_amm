#!/bin/bash
# ============================================
# STEP 3: Create Liquidity Pool
# ============================================
# PRD: Pool Creation Workflow (3.2.1)
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Pool Creation Workflow                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Pool Creation Workflow (Section 3.2.1)${NC}"
echo ""

# Get USDC and USDT coins for initial liquidity (exclude TreasuryCap, only get Coin objects with balance > 0)
echo -e "${BLUE}[1/4]${NC} Getting Token Coins..."
USDC_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"Coin<\")) | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdc::USDC\")) | select(.data.content.fields.balance != \"0\") | .data.objectId" | head -n 1)
USDT_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"Coin<\")) | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdt::USDT\")) | select(.data.content.fields.balance != \"0\") | .data.objectId" | head -n 1)

if [ -z "$USDC_COIN" ]; then
    echo "Error: Could not find USDC coin. Run 02_create_test_coins.sh first."
    exit 1
fi

if [ -z "$USDT_COIN" ]; then
    echo "Error: Could not find USDT coin. Run 02_create_test_coins.sh first."
    exit 1
fi

echo -e "USDC Coin: ${GREEN}$USDC_COIN${NC}"
echo -e "USDT Coin: ${GREEN}$USDT_COIN${NC}"
echo ""

echo -e "${BLUE}[2/4]${NC} Getting SUI coins for pool creation..."
# Get gas coins and find one with enough balance for creation fee (5 SUI)
GAS_COINS=$(sui client gas --json)
CREATION_FEE_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 6000000000) | .gasCoinId' | head -n 1)

if [ -z "$CREATION_FEE_COIN" ]; then
    echo "Error: No SUI coin with at least 6 SUI found for creation fee."
    echo "Run: sui client faucet"
    exit 1
fi
echo -e "Using creation fee coin: ${GREEN}$CREATION_FEE_COIN${NC}"

# Split 5 SUI for creation fee
echo "Splitting 5 SUI for creation fee..."
SPLIT_FEE_OUTPUT=$(sui client split-coin --coin-id $CREATION_FEE_COIN --amounts 5000000000 --gas-budget 50000000 --json 2>&1)
SPLIT_FEE_COIN=$(echo "$SPLIT_FEE_OUTPUT" | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

if [ -z "$SPLIT_FEE_COIN" ]; then
    echo "Error: Failed to split SUI for creation fee"
    echo "$SPLIT_FEE_OUTPUT"
    exit 1
fi
echo -e "Creation fee coin: ${GREEN}$SPLIT_FEE_COIN${NC}"
echo ""

echo -e "${BLUE}[3/4]${NC} Creating SUI-USDC pool via Move call..."

# Get a fresh SUI coin for liquidity (need to get gas coins again after split)
GAS_COINS=$(sui client gas --json)
SUI_LIQ_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 11000000000) | .gasCoinId' | head -n 1)

if [ -z "$SUI_LIQ_COIN" ]; then
    echo "Error: No SUI coin with at least 11 SUI found for liquidity."
    echo "Run: sui client faucet"
    exit 1
fi

# Split 10 SUI for liquidity (reduced for testing)
echo "Splitting 10 SUI for liquidity..."
SPLIT_SUI_OUTPUT=$(sui client split-coin --coin-id $SUI_LIQ_COIN --amounts 10000000000 --gas-budget 50000000 --json 2>&1)
SPLIT_SUI=$(echo "$SPLIT_SUI_OUTPUT" | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

if [ -z "$SPLIT_SUI" ]; then
    echo "Error: Failed to split SUI for liquidity"
    echo "$SPLIT_SUI_OUTPUT"
    exit 1
fi
echo -e "SUI liquidity coin: ${GREEN}$SPLIT_SUI${NC}"

# Split USDC for liquidity (10,000 USDC = 10000000000 with 6 decimals)
echo "Splitting 10,000 USDC for liquidity..."
SPLIT_USDC_OUTPUT=$(sui client split-coin --coin-id $USDC_COIN --amounts 10000000000 --gas-budget 50000000 --json 2>&1)
SPLIT_USDC=$(echo "$SPLIT_USDC_OUTPUT" | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

if [ -z "$SPLIT_USDC" ]; then
    echo "Error: Failed to split USDC for liquidity"
    echo "$SPLIT_USDC_OUTPUT"
    exit 1
fi
echo -e "USDC liquidity coin: ${GREEN}$SPLIT_USDC${NC}"

echo ""
echo "Initial Liquidity: 10 SUI + 10,000 USDC"
echo ""

CLOCK="0x6"
MY_ADDRESS=$(sui client active-address)

# Use PTB to handle the returned tuple (position, refund_a, refund_b)
CREATE_OUTPUT=$(sui client ptb \
  --move-call "${PACKAGE_ID}::factory::create_pool<0x2::sui::SUI,${COIN_PACKAGE_ID}::usdc::USDC>" \
    @$POOL_REGISTRY \
    @$STATS_REGISTRY \
    30u64 \
    0u64 \
    @$SPLIT_SUI \
    @$SPLIT_USDC \
    @$SPLIT_FEE_COIN \
    @$CLOCK \
  --assign result \
  --transfer-objects "[result.0, result.1, result.2]" @$MY_ADDRESS \
  --gas-budget 500000000 \
  --json 2>&1)

echo "$CREATE_OUTPUT" > create_pool.json

# Check for errors
if echo "$CREATE_OUTPUT" | jq -e '.effects.status.status == "failure"' > /dev/null 2>&1; then
    echo -e "${YELLOW}Error creating pool:${NC}"
    echo "$CREATE_OUTPUT" | jq -r '.effects.status.error // "Unknown error"'
    exit 1
fi

POOL_ID=$(echo "$CREATE_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null) | select(.objectType | contains("LiquidityPool")) | .objectId' | head -n 1)
NFT_ID=$(echo "$CREATE_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null) | select(.objectType | contains("LPPosition")) | .objectId' | head -n 1)

if [ -z "$POOL_ID" ] || [ "$POOL_ID" == "null" ]; then
    echo -e "${YELLOW}Error: Could not extract Pool ID from output${NC}"
    echo "Check create_pool.json for details"
    cat create_pool.json
    exit 1
fi

echo "POOL_ID=$POOL_ID" >> .env
echo "NFT_ID=$NFT_ID" >> .env

echo ""
echo -e "${BLUE}[4/4]${NC} Pool Created!"
echo ""
echo -e "Pool ID: ${GREEN}$POOL_ID${NC}"
echo -e "NFT ID: ${GREEN}$NFT_ID${NC}"
echo ""
echo -e "${GREEN}✓ Pool created successfully!${NC}"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ Fee tier validation (0.05%, 0.30%, 1.00%)"
echo "  ✓ Pool creation fee (5 SUI - DoS protection)"
echo "  ✓ Atomic pool creation + initial liquidity"
echo "  ✓ NFT position minted to creator"
echo "  ✓ Pool indexed in registry"
echo ""
echo -e "${YELLOW}Next: Run ./04_add_liquidity.sh${NC}"
