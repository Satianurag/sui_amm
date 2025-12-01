#!/bin/bash
# ============================================
# STEP 7: Claim Accumulated Fees
# ============================================
# PRD: Fee Claiming Workflow (3.2.4)
# - View accumulated fees through NFT position
# - Calculate pro-rata share
# - Transfer fees to LP
# - Auto-compound option
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Fee Claiming Workflow                             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Fee Claiming Workflow (Section 3.2.4)${NC}"
echo ""
echo "Steps:"
echo "  1. LP views accumulated fees through NFT position"
echo "  2. LP calls claim_fees with position NFT"
echo "  3. System calculates pro-rata share:"
echo "     - LP share = (lp_tokens / total_supply)"
echo "     - Claimable fees = accumulated_fees × LP share"
echo "  4. Transfer fees to LP"
echo "  5. Update position metadata"
echo "  6. Emit FeeClaimed event"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""

echo -e "${BLUE}[1/5]${NC} Current Fee Pool State:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Total LP Fee Pool A:   297,000 SUI      │"
echo "  │ Total LP Fee Pool B:   0 USDC           │"
echo "  │ Protocol Fees A:       3,000 SUI        │"
echo "  │ Protocol Fees B:       0 USDC           │"
echo "  └─────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[2/5]${NC} Your Position Share:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Your Liquidity:        499,999,500      │"
echo "  │ Total Pool Liquidity:  999,999,000      │"
echo "  │ Your Share:            50.00%           │"
echo "  └─────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[3/5]${NC} Claimable Fees Calculation:"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Formula: claimable = accumulated_fees × (your_lp / total_lp)"
echo "  │                                                         │"
echo "  │ Fee A Claimable:                                        │"
echo "  │   297,000 × (499,999,500 / 999,999,000)                 │"
echo "  │   = 297,000 × 0.5                                       │"
echo -e "  │   = ${GREEN}148,500 SUI${NC}                                       │"
echo "  │                                                         │"
echo "  │ Fee B Claimable:                                        │"
echo "  │   0 × 0.5                                               │"
echo -e "  │   = ${GREEN}0 USDC${NC}                                             │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[4/5]${NC} Option A - Claim Fees:"
echo ""
echo -e "${YELLOW}Command:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module fee_distributor \
  --function claim_fees \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args \
    $POOL_ID \
    $POSITION_NFT_ID \
    $CLOCK \
    $DEADLINE \
  --gas-budget 50000000
EOF
echo ""
echo "  Result: 148,500 SUI transferred to your wallet"
echo ""

echo -e "${BLUE}[5/5]${NC} Option B - Auto-Compound Fees:"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Instead of withdrawing, compound fees back into pool!   │"
echo "  │                                                         │"
echo "  │ Before Compound:                                        │"
echo "  │   Liquidity Shares: 499,999,500                         │"
echo "  │   Pending Fees: 148,500 SUI + 0 USDC                    │"
echo "  │                                                         │"
echo "  │ After Compound:                                         │"
echo "  │   Liquidity Shares: 499,999,500 + ~74,000 = 500,073,500 │"
echo "  │   Pending Fees: 0 SUI + 0 USDC                          │"
echo "  │                                                         │"
echo "  │ Note: Requires both tokens for ratio. If only one token │"
echo "  │ has fees, they're returned as refund.                   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}Command:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module fee_distributor \
  --function compound_fees \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args \
    $POOL_ID \
    $POSITION_NFT_ID \
    1 \                 # min_liquidity
    $CLOCK \
    $DEADLINE \
  --gas-budget 50000000
EOF
echo ""

echo -e "${GREEN}✓ Fee Claim Complete!${NC}"
echo ""
echo "  Event: FeesClaimed"
echo "    pool_id: 0x..."
echo "    owner: 0x..."
echo "    amount_a: 148,500"
echo "    amount_b: 0"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ Pro-rata fee distribution"
echo "  ✓ Accumulated fee tracking per position"
echo "  ✓ Fee debt mechanism (prevents double-claiming)"
echo "  ✓ Auto-compound option"
echo "  ✓ Dust prevention (min compound threshold)"
echo ""
echo -e "${YELLOW}Next: Run ./08_remove_liquidity.sh${NC}"
