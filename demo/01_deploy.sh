#!/bin/bash
# ============================================
# STEP 1: Deploy SUI AMM Contracts
# ============================================
# PRD: Deploy all smart contracts
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          SUI AMM - Contract Deployment                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}[1/3]${NC} Checking localnet connection..."
sui client active-env
echo ""

echo -e "${BLUE}[2/3]${NC} Building contracts..."
cd ..
sui move build
echo ""

echo -e "${BLUE}[3/3]${NC} Publishing to localnet..."
echo ""

# Publish and capture output
PUBLISH_OUTPUT=$(sui client publish --gas-budget 500000000 --json 2>&1)

# Save full output for debugging
echo "$PUBLISH_OUTPUT" > demo/deploy_output.json

# Extract package ID
PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.type == "published") | .packageId' 2>/dev/null)

if [ -z "$PACKAGE_ID" ] || [ "$PACKAGE_ID" == "null" ]; then
    echo -e "${YELLOW}Could not parse JSON, trying alternative method...${NC}"
    PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | grep -oP 'packageId.*?0x[a-fA-F0-9]+' | head -1 | grep -oP '0x[a-fA-F0-9]+')
fi

echo -e "${GREEN}✓ Contracts deployed successfully!${NC}"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  DEPLOYMENT SUMMARY                                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "Package ID: ${GREEN}$PACKAGE_ID${NC}"
echo ""

# Save package ID for other scripts
echo "PACKAGE_ID=$PACKAGE_ID" > demo/.env

# Extract important object IDs
echo -e "${BLUE}Extracting created objects...${NC}"

POOL_REGISTRY=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.objectType | contains("PoolRegistry")) | .objectId' 2>/dev/null)
ADMIN_CAP=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.objectType | contains("AdminCap")) | .objectId' 2>/dev/null)
STATS_REGISTRY=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.objectType | contains("StatisticsRegistry")) | .objectId' 2>/dev/null)
ORDER_REGISTRY=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.objectType | contains("OrderRegistry")) | .objectId' 2>/dev/null)
GOV_CONFIG=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.objectType | contains("GovernanceConfig")) | .objectId' 2>/dev/null)

echo "POOL_REGISTRY=$POOL_REGISTRY" >> demo/.env
echo "ADMIN_CAP=$ADMIN_CAP" >> demo/.env
echo "STATS_REGISTRY=$STATS_REGISTRY" >> demo/.env
echo "ORDER_REGISTRY=$ORDER_REGISTRY" >> demo/.env
echo "GOV_CONFIG=$GOV_CONFIG" >> demo/.env

echo ""
echo "Created Objects:"
echo "  - PoolRegistry:      $POOL_REGISTRY"
echo "  - AdminCap:          $ADMIN_CAP"
echo "  - StatisticsRegistry: $STATS_REGISTRY"
echo "  - OrderRegistry:     $ORDER_REGISTRY"
echo "  - GovernanceConfig:  $GOV_CONFIG"
echo ""
echo -e "${GREEN}✓ Environment saved to demo/.env${NC}"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Deployed Modules:                                         ║"
echo "║  • sui_amm (main)                                          ║"
echo "║  • factory (PoolFactory)                                   ║"
echo "║  • pool (LiquidityPool)                                    ║"
echo "║  • stable_pool (StableSwapPool)                            ║"
echo "║  • position (LPPosition NFT)                               ║"
echo "║  • fee_distributor                                         ║"
echo "║  • slippage_protection                                     ║"
echo "║  • limit_orders                                            ║"
echo "║  • governance                                              ║"
echo "║  • swap_history                                            ║"
echo "║  • user_preferences                                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${YELLOW}Next: Run ./02_create_test_coins.sh${NC}"
