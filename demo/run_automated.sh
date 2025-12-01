#!/bin/bash
# ============================================
# Automated Demo Runner - SUI AMM
# ============================================
# Runs all demo scripts in sequence with proper error handling
# ============================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          SUI AMM - Automated Demo Runner                   ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Track timing
START_TIME=$(date +%s)

run_step() {
    local step_num=$1
    local script=$2
    local description=$3
    
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[$step_num/10] $description${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ./$script; then
        echo ""
        echo -e "${GREEN}✓ Step $step_num completed successfully${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}✗ Step $step_num failed${NC}"
        return 1
    fi
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v sui &> /dev/null; then
    echo -e "${RED}Error: sui CLI not found. Please install Sui first.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq not found. Please install jq first.${NC}"
    exit 1
fi

# Check if localnet is running
if ! sui client gas --json 2>/dev/null | jq -e '.' > /dev/null 2>&1; then
    echo -e "${YELLOW}Localnet not responding. Attempting to start...${NC}"
    echo "Run: RUST_LOG=off,sui_node=warn sui start --with-faucet --force-regenesis"
    echo "Then run this script again."
    exit 1
fi

# Request faucet if no gas
GAS_COUNT=$(sui client gas --json 2>/dev/null | jq 'length')
if [ "$GAS_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No gas coins found. Requesting from faucet...${NC}"
    sui client faucet
    sleep 5
fi

echo -e "${GREEN}✓ Prerequisites check passed${NC}"

# Clean up any previous state
echo ""
echo -e "${YELLOW}Cleaning up previous demo state...${NC}"
rm -f .env 2>/dev/null || true
rm -f *.json 2>/dev/null || true
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Run all demo steps
run_step 1 "01_deploy.sh" "Deploy Contracts"
run_step 2 "02_create_test_coins.sh" "Create Test Coins (USDC & USDT)"
run_step 3 "03_create_pool.sh" "Create SUI-USDC Pool"
run_step 4 "04_add_liquidity.sh" "Add Liquidity"
run_step 5 "05_swap.sh" "Execute Swap"
run_step 6 "06_view_position.sh" "View LP Position"
run_step 7 "07_claim_fees.sh" "Fee Claiming Info"
run_step 8 "08_remove_liquidity.sh" "Remove Liquidity Info"
run_step 9 "09_stable_pool.sh" "StableSwap Pool Demo"
run_step 10 "10_advanced_features.sh" "Advanced Features"

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          ALL DEMOS COMPLETED SUCCESSFULLY!                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total time: ${CYAN}${MINUTES}m ${SECONDS}s${NC}"
echo ""
echo "Environment saved to: demo/.env"
echo ""
echo "Key objects created:"
source .env 2>/dev/null
echo -e "  Package ID:     ${GREEN}${PACKAGE_ID:0:20}...${NC}"
echo -e "  Pool Registry:  ${GREEN}${POOL_REGISTRY:0:20}...${NC}"
echo -e "  Pool ID:        ${GREEN}${POOL_ID:0:20}...${NC}"
[ -n "$STABLE_POOL_ID" ] && echo -e "  Stable Pool:    ${GREEN}${STABLE_POOL_ID:0:20}...${NC}"
echo ""
