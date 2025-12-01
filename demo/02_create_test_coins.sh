#!/bin/bash
# ============================================
# STEP 2: Create Test Coins for Demo
# ============================================
# Creates USDC and USDT test tokens
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Creating Test Coins (USDC & USDT)                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get current address
MY_ADDRESS=$(sui client active-address)
echo -e "Active Address: ${GREEN}$MY_ADDRESS${NC}"
echo ""

echo -e "${BLUE}[1/3]${NC} Deploying Test Coins Package..."
cd test_coins
sui move build
PUBLISH_OUTPUT=$(sui client publish --gas-budget 100000000 --json)
cd ..

# Extract package ID
COIN_PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.type == "published") | .packageId' | head -n 1)
echo "COIN_PACKAGE_ID=$COIN_PACKAGE_ID" >> .env

# Extract TreasuryCaps
USDC_TREASURY=$(echo "$PUBLISH_OUTPUT" | jq -r ".objectChanges[] | select(.objectType != null) | select(.objectType | contains(\"0x$COIN_PACKAGE_ID::usdc::USDC\")) | .objectId" | head -n 1)
USDT_TREASURY=$(echo "$PUBLISH_OUTPUT" | jq -r ".objectChanges[] | select(.objectType != null) | select(.objectType | contains(\"0x$COIN_PACKAGE_ID::usdt::USDT\")) | .objectId" | head -n 1)

# Fallback extraction if needed
if [ -z "$USDC_TREASURY" ]; then
    USDC_TREASURY=$(echo "$PUBLISH_OUTPUT" | jq -r ".objectChanges[] | select(.objectType != null) | select(.objectType | contains(\"TreasuryCap\")) | select(.objectType | contains(\"USDC\")) | .objectId" | head -n 1)
fi
if [ -z "$USDT_TREASURY" ]; then
    USDT_TREASURY=$(echo "$PUBLISH_OUTPUT" | jq -r ".objectChanges[] | select(.objectType != null) | select(.objectType | contains(\"TreasuryCap\")) | select(.objectType | contains(\"USDT\")) | .objectId" | head -n 1)
fi

echo "USDC_TREASURY=$USDC_TREASURY" >> .env
echo "USDT_TREASURY=$USDT_TREASURY" >> .env
echo "COIN_PACKAGE_ID=$COIN_PACKAGE_ID" >> .env

echo -e "Coin Package: ${GREEN}$COIN_PACKAGE_ID${NC}"
echo -e "USDC Treasury: ${GREEN}$USDC_TREASURY${NC}"
echo -e "USDT Treasury: ${GREEN}$USDT_TREASURY${NC}"
echo ""

# Mint USDC
echo -e "${BLUE}[2/3]${NC} Minting USDC..."
echo "Minting 1,000,000 USDC to $MY_ADDRESS..."
sui client call \
    --package 0x2 \
    --module coin \
    --function mint_and_transfer \
    --type-args "$COIN_PACKAGE_ID::usdc::USDC" \
    --args $USDC_TREASURY "1000000000000" $MY_ADDRESS \
    --gas-budget 100000000 \
    --json > mint_usdc.json

echo -e "${GREEN}✓ USDC Minted${NC}"

# Mint USDT
echo -e "${BLUE}[3/3]${NC} Minting USDT..."
echo "Minting 1,000,000 USDT to $MY_ADDRESS..."
sui client call \
    --package 0x2 \
    --module coin \
    --function mint_and_transfer \
    --type-args "$COIN_PACKAGE_ID::usdt::USDT" \
    --args $USDT_TREASURY "1000000000000" $MY_ADDRESS \
    --gas-budget 100000000 \
    --json > mint_usdt.json

echo -e "${GREEN}✓ USDT Minted${NC}"

echo ""
echo -e "${GREEN}✓ Test coins created successfully!${NC}"
echo ""
echo -e "${YELLOW}Next: Run ./03_create_pool.sh${NC}"
