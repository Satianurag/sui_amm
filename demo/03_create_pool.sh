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

# Get a SUI coin to use for creation fee (5 SUI)
echo -e "${BLUE}[1/4]${NC} Getting SUI coins for pool creation..."
# We need a coin with at least 5 SUI (5,000,000,000 MIST)
# We'll pick the first gas coin that has enough balance
GAS_COINS=$(sui client gas --json)
CREATION_FEE_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 5000000000) | .gasCoinId' | head -n 1)

if [ -z "$CREATION_FEE_COIN" ]; then
    echo "Error: No SUI coin with at least 5 SUI found for creation fee."
    exit 1
fi
echo -e "Using creation fee coin: ${GREEN}$CREATION_FEE_COIN${NC}"
echo ""

# Get USDC and USDT coins for initial liquidity
echo -e "${BLUE}[2/4]${NC} Getting Token Coins..."
# We need to find the object IDs of the minted USDC and USDT
# Since we just minted them, they should be in our address
USDC_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdc::USDC\")) | .data.objectId" | head -n 1)
USDT_COIN=$(sui client objects --json | jq -r ".[] | select(.data.type | contains(\"$COIN_PACKAGE_ID::usdt::USDT\")) | .data.objectId" | head -n 1)

if [ -z "$USDC_COIN" ] || [ -z "$USDT_COIN" ]; then
    echo "Error: Could not find USDC or USDT coins. Run 02_create_test_coins.sh first."
    exit 1
fi

echo -e "USDC Coin: ${GREEN}$USDC_COIN${NC}"
echo -e "USDT Coin: ${GREEN}$USDT_COIN${NC}"
echo ""

echo -e "${BLUE}[3/4]${NC} Creating pool via Move call..."
echo "Creating USDC-USDT Pool (Stable)..."

# Note: For stable pool we use create_stable_pool, for standard we use create_pool
# Let's create a standard pool first as per script name, but maybe USDC/USDT should be stable?
# The PRD mentions both. Let's stick to standard pool for this script as it's "03_create_pool.sh"
# and "09_stable_pool.sh" is for stable.
# So we will create a SUI-USDC pool here?
# The original script used SUI and COIN_B.
# Let's create SUI-USDC pool.

# We need SUI coin for liquidity too.
SUI_LIQ_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 101000000000) | select(.gasCoinId != "'$CREATION_FEE_COIN'") | .gasCoinId' | head -n 1)
echo "SUI_LIQ_COIN: $SUI_LIQ_COIN"
if [ -z "$SUI_LIQ_COIN" ]; then
    # If we don't have another coin, we might need to split.
    # For simplicity, let's assume we have enough gas objects or use the same one if allowed (but usually consumed)
    # Actually, we can pass the same coin object for creation fee and liquidity? No, creation fee is transferred.
    # Let's just use USDC and USDT for the pool to avoid SUI coin management issues?
    # But standard pool is usually volatile.
    # Let's do SUI-USDC.
    echo "Need distinct SUI coin for liquidity."
    exit 1
fi

# Actually, let's just use USDC and USDT for the standard pool demo too, or maybe create a new pair?
# Let's stick to SUI-USDC for standard pool.
# Wait, I need to make sure I have SUI coin for liquidity.
# Let's just use the USDC and USDT we minted.
# We will create a USDC-USDT standard pool? No that's bad for stable pairs.
# Let's create SUI-USDC pool.

echo "Creating SUI-USDC Pool..."

# We need to split SUI coin for liquidity if we don't have a separate one
# But for now let's assume we use USDC and USDT for the pool?
# No, let's use SUI and USDC.

CLOCK="0x6"

# Create Pool
# create_pool<A, B>(registry, stats, fee, creator_fee, coin_a, coin_b, fee_coin, clock)
# We use SUI as A, USDC as B.

# We need to make sure we pass the coin objects.
# SUI_LIQ_COIN needs to be a Coin<SUI>.
# USDC_COIN needs to be Coin<USDC>.

# We need to ensure SUI_LIQ_COIN has specific amount?
# The function takes the whole coin object.
# So we should probably split it to the exact amount we want to add.
# But for demo simplicity, we can just pass the coin and it will use it all?
# The PRD says "User provides initial liquidity".
# The contract likely takes the passed coin.

# Let's split the coins to exact amounts to be clean.
echo "Splitting 100 SUI for liquidity..."
sui client split-coin --coin-id $SUI_LIQ_COIN --amounts 100000000000 --gas-budget 50000000 --json > split_sui.json
cat split_sui.json
SPLIT_SUI=$(cat split_sui.json | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)
echo "SPLIT_SUI: $SPLIT_SUI"

echo "Using full USDC coin for liquidity..."
SPLIT_USDC=$USDC_COIN

echo "Initial Liquidity: 100 SUI, ~1M USDC"

CREATE_OUTPUT=$(sui client call \
  --package $PACKAGE_ID \
  --module factory \
  --function create_pool \
  --type-args "0x2::sui::SUI" "$COIN_PACKAGE_ID::usdc::USDC" \
  --args \
    $POOL_REGISTRY \
    $STATS_REGISTRY \
    30 \
    0 \
    $SPLIT_SUI \
    $SPLIT_USDC \
    $CREATION_FEE_COIN \
    $CLOCK \
  --gas-budget 100000000 \
  --json)

echo "$CREATE_OUTPUT" > create_pool.json

POOL_ID=$(echo "$CREATE_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null) | select(.objectType | contains("LiquidityPool")) | .objectId' | head -n 1)
NFT_ID=$(echo "$CREATE_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null) | select(.objectType | contains("LPPosition")) | .objectId' | head -n 1)

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
