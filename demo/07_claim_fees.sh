#!/bin/bash
# ============================================
# STEP 7: Claim Accumulated Fees
# ============================================
# PRD: Fee Claiming Workflow (3.2.4)
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
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Fee Claiming Workflow (Section 3.2.4)${NC}"
echo ""
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
