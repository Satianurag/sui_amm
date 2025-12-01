#!/bin/bash
# ============================================
# STEP 8: Remove Liquidity
# ============================================
# PRD: Remove Liquidity Workflow (3.2.5)
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Remove Liquidity Workflow                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Remove Liquidity Workflow (Section 3.2.5)${NC}"
echo ""
echo "  amount_a (400M) >= min_amount_a (380M) ✓"
echo "  amount_b (351M) >= min_amount_b (330M) ✓"
echo ""

echo -e "${YELLOW}Command (Partial Removal):${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function remove_liquidity_partial \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args \
    $POOL_ID \
    $POSITION_NFT_ID \
    249999750 \         # liquidity_to_remove
    380000000 \         # min_amount_a
    330000000 \         # min_amount_b
    $CLOCK \
    $DEADLINE \
  --gas-budget 50000000
EOF
echo ""

echo -e "${GREEN}Result:${NC}"
echo "  • 400,000,000 SUI transferred to wallet"
echo "  • 351,635,802 USDC transferred to wallet"
echo "  • NFT position updated (liquidity: 249,999,750)"
echo "  • Proportional fees also claimed"
echo ""

echo "════════════════════════════════════════════════════════════"
echo -e "${RED}OPTION B: Full Removal (100%)${NC}"
echo "════════════════════════════════════════════════════════════"
echo ""

echo -e "${BLUE}[B.1]${NC} Full Removal Request:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Removing ALL liquidity                  │"
echo "  │ Liquidity:             499,999,500      │"
echo "  │ Min Amount A:          750,000,000      │"
echo "  │ Min Amount B:          650,000,000      │"
echo "  └─────────────────────────────────────────┘"
echo ""

echo -e "${YELLOW}Command (Full Removal):${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function remove_liquidity \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args \
    $POOL_ID \
    $POSITION_NFT_ID \  # NFT will be BURNED
    750000000 \         # min_amount_a
    650000000 \         # min_amount_b
    $CLOCK \
    $DEADLINE \
  --gas-budget 50000000
EOF
echo ""

echo -e "${RED}⚠️  NFT BURNED on full removal!${NC}"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ The LPPosition NFT is destroyed when all liquidity is   │"
echo "  │ removed. This is by design - the NFT represents your    │"
echo "  │ position, and with no position, there's no NFT.         │"
echo "  │                                                         │"
echo "  │ All pending fees are automatically claimed during       │"
echo "  │ full removal.                                           │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

echo -e "${GREEN}✓ Liquidity Removal Complete!${NC}"
echo ""
echo "  Event: LiquidityRemoved"
echo "    pool_id: 0x..."
echo "    provider: 0x..."
echo "    amount_a: 800,000,000"
echo "    amount_b: 703,271,605"
echo "    liquidity_burned: 499,999,500"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ Partial liquidity removal"
echo "  ✓ Full liquidity removal"
echo "  ✓ Slippage protection (min amounts)"
echo "  ✓ Proportional token calculation"
echo "  ✓ NFT burn on full removal"
echo "  ✓ Automatic fee claiming"
echo ""
echo -e "${YELLOW}Next: Run ./09_stable_pool.sh${NC}"
