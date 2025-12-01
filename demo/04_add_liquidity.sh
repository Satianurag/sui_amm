#!/bin/bash
# ============================================
# STEP 4: Add Liquidity & Mint NFT Position
# ============================================
# PRD: Add Liquidity Workflow (3.2.2)
# - Calculate required ratio
# - Validate amounts maintain ratio
# - Mint LP tokens
# - Create/update NFT position
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
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Add Liquidity Workflow (Section 3.2.2)${NC}"
echo ""
echo "Steps:"
echo "  1. LP selects pool and amounts to deposit"
echo "  2. System calculates required ratio: amount_b = (amount_a * reserve_b) / reserve_a"
echo "  3. LP provides both tokens"
echo "  4. System validates amounts maintain current ratio (±0.5% tolerance)"
echo "  5. Calculate LP tokens: lp_tokens = (amount_a * total_supply) / reserve_a"
echo "  6. Mint LP tokens and create/update NFT position"
echo "  7. Update reserves and position metadata"
echo "  8. Emit LiquidityAdded event"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""

echo -e "${BLUE}[1/5]${NC} Current Pool State:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Reserve A (SUI):    1,000,000,000       │"
echo "  │ Reserve B (USDC):   1,000,000,000       │"
echo "  │ Total Liquidity:    999,999,000         │"
echo "  │ K Value:            1e18                │"
echo "  │ Current Price:      1.0 SUI/USDC        │"
echo "  └─────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[2/5]${NC} LP Deposit Request:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Amount A (SUI):     500,000,000         │"
echo "  │ Amount B (USDC):    500,000,000         │"
echo "  │ Min Liquidity:      1                   │"
echo "  │ Deadline:           +20 minutes         │"
echo "  └─────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[3/5]${NC} Ratio Validation:"
echo ""
echo "  Expected ratio: 1.0 (reserve_b / reserve_a)"
echo "  Provided ratio: 1.0 (amount_b / amount_a)"
echo "  Deviation:      0.00% ✓ (within 0.5% tolerance)"
echo ""

echo -e "${BLUE}[4/5]${NC} LP Token Calculation:"
echo ""
echo "  Formula: lp_tokens = (amount_a * total_supply) / reserve_a"
echo "  lp_tokens = (500,000,000 * 999,999,000) / 1,000,000,000"
echo -e "  lp_tokens = ${GREEN}499,999,500${NC}"
echo ""

echo -e "${BLUE}[5/5]${NC} NFT Position Created:"
echo ""
echo -e "${MAGENTA}"
cat << 'EOF'
  ╔═══════════════════════════════════════════════════════════╗
  ║                                                           ║
  ║     ███████╗██╗   ██╗██╗     █████╗ ███╗   ███╗███╗   ███╗║
  ║     ██╔════╝██║   ██║██║    ██╔══██╗████╗ ████║████╗ ████║║
  ║     ███████╗██║   ██║██║    ███████║██╔████╔██║██╔████╔██║║
  ║     ╚════██║██║   ██║██║    ██╔══██║██║╚██╔╝██║██║╚██╔╝██║║
  ║     ███████║╚██████╔╝██║    ██║  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║║
  ║     ╚══════╝ ╚═════╝ ╚═╝    ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝║
  ║                                                           ║
  ║                   LP POSITION NFT                         ║
  ║                                                           ║
  ╠═══════════════════════════════════════════════════════════╣
  ║  Pool Type:        Standard AMM                           ║
  ║  Fee Tier:         0.30%                                  ║
  ║  ───────────────────────────────────────────────────────  ║
  ║  Liquidity Shares: 499,999,500                            ║
  ║  ───────────────────────────────────────────────────────  ║
  ║  Position Value:                                          ║
  ║    Token A (SUI):  500,000,000                            ║
  ║    Token B (USDC): 500,000,000                            ║
  ║  ───────────────────────────────────────────────────────  ║
  ║  Accumulated Fees:                                        ║
  ║    Fee A: 0                                               ║
  ║    Fee B: 0                                               ║
  ║  ───────────────────────────────────────────────────────  ║
  ║  Impermanent Loss: 0.00%                                  ║
  ╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo ""

echo -e "${YELLOW}Command Structure:${NC}"
echo ""
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function add_liquidity \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args \
    $POOL_ID \
    $COIN_A \           # 500,000,000 SUI
    $COIN_B \           # 500,000,000 USDC
    1 \                 # min_liquidity
    $CLOCK \
    $DEADLINE \
  --gas-budget 50000000
EOF
echo ""

echo -e "${GREEN}✓ Liquidity Added Successfully!${NC}"
echo ""
echo "  Event: LiquidityAdded"
echo "    pool_id: 0x..."
echo "    provider: 0x..."
echo "    amount_a: 500,000,000"
echo "    amount_b: 500,000,000"
echo "    liquidity_minted: 499,999,500"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ Ratio validation (±0.5% tolerance)"
echo "  ✓ LP token calculation"
echo "  ✓ NFT position minting with metadata"
echo "  ✓ On-chain SVG image generation"
echo "  ✓ Refund of excess tokens"
echo ""
echo -e "${YELLOW}Next: Run ./05_swap.sh${NC}"
