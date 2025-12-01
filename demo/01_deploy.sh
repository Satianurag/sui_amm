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
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}[1/3]${NC} Checking localnet connection..."
sui client active-env
echo ""

echo -e "${BLUE}[2/3]${NC} Building contracts..."
sui move build -p "$PROJECT_DIR"
echo ""

echo -e "${BLUE}[3/3]${NC} Publishing to localnet..."
echo ""

# Publish and capture output
RAW_OUTPUT=$(sui client publish "$PROJECT_DIR" --gas-budget 2000000000 --json 2>&1)

# Extract JSON from output (starts with { and ends with })
PUBLISH_OUTPUT=$(echo "$RAW_OUTPUT" | sed -n '/^{/,/^}/p')

# Save full output for debugging
echo "$PUBLISH_OUTPUT" > "$SCRIPT_DIR/deploy_output.json"

# Check for errors
if echo "$PUBLISH_OUTPUT" | jq -e '.effects.status.status == "failure"' > /dev/null 2>&1; then
    echo -e "${RED}Deployment failed:${NC}"
    echo "$PUBLISH_OUTPUT" | jq -r '.effects.status.error // "Unknown error"'
    exit 1
fi

# Extract package ID
PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.type == "published") | .packageId' 2>/dev/null | head -n 1)

if [ -z "$PACKAGE_ID" ] || [ "$PACKAGE_ID" == "null" ]; then
    echo -e "${YELLOW}Could not parse JSON, trying alternative method...${NC}"
    PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | grep -oP 'packageId.*?0x[a-fA-F0-9]+' | head -1 | grep -oP '0x[a-fA-F0-9]+')
fi

if [ -z "$PACKAGE_ID" ]; then
    echo -e "${RED}Failed to deploy contracts. Check deploy_output.json${NC}"
    exit 1
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
echo "PACKAGE_ID=$PACKAGE_ID" > "$SCRIPT_DIR/.env"

# Extract important object IDs
echo -e "${BLUE}Extracting created objects...${NC}"

# Helper function to extract object ID by type
get_object_id() {
    local type=$1
    echo "$PUBLISH_OUTPUT" | jq -r ".objectChanges[] | select(.objectType != null) | select(.objectType | contains(\"$type\")) | .objectId" 2>/dev/null | head -n 1
}

POOL_REGISTRY=$(get_object_id "PoolRegistry")
ADMIN_CAP=$(get_object_id "AdminCap")
STATS_REGISTRY=$(get_object_id "StatisticsRegistry")
ORDER_REGISTRY=$(get_object_id "OrderRegistry")
GOV_CONFIG=$(get_object_id "GovernanceConfig")

echo "POOL_REGISTRY=$POOL_REGISTRY" >> "$SCRIPT_DIR/.env"
echo "ADMIN_CAP=$ADMIN_CAP" >> "$SCRIPT_DIR/.env"
echo "STATS_REGISTRY=$STATS_REGISTRY" >> "$SCRIPT_DIR/.env"
echo "ORDER_REGISTRY=$ORDER_REGISTRY" >> "$SCRIPT_DIR/.env"
echo "GOV_CONFIG=$GOV_CONFIG" >> "$SCRIPT_DIR/.env"

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
echo "║  • usdc (Test Coin)                                        ║"
echo "║  • usdt (Test Coin)                                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${YELLOW}Next: Run ./02_create_test_coins.sh${NC}"
