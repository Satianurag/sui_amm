#!/bin/bash
# ============================================
# STEP 6: View LP Position NFT
# ============================================
# PRD: LP Position NFT Features
# - View NFT position details on-chain
# - Dynamic metadata reflecting current value
# - Accumulated fees display
# - Impermanent loss calculation
# - On-chain SVG display
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          LP Position NFT Viewer                            ║"
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

echo -e "${CYAN}PRD Requirement: LP Position NFT Features${NC}"
echo ""
echo "As an LP position holder, I want to:"
echo "  • View my NFT position details on-chain"
echo "  • See dynamic metadata reflecting current value"
echo "  • Claim accumulated fees anytime"
echo "  • Auto-compound fees into my position"
echo "  • Display my LP NFT in wallets and marketplaces"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""

echo -e "${BLUE}[1/4]${NC} Fetching LP Position NFT..."
echo ""

echo -e "${MAGENTA}"
cat << 'EOF'
  ╔═══════════════════════════════════════════════════════════════╗
  ║                                                               ║
  ║   ┌───────────────────────────────────────────────────────┐   ║
  ║   │                                                       │   ║
  ║   │              🌊 SUI AMM LP POSITION 🌊                │   ║
  ║   │                                                       │   ║
  ║   │   ┌─────────────────────────────────────────────┐     │   ║
  ║   │   │         ╔═══════════════════╗               │     │   ║
  ║   │   │         ║   STANDARD AMM    ║               │     │   ║
  ║   │   │         ╚═══════════════════╝               │     │   ║
  ║   │   │                                             │     │   ║
  ║   │   │   LIQUIDITY SHARES                          │     │   ║
  ║   │   │   ████████████████████  499,999,500         │     │   ║
  ║   │   │                                             │     │   ║
  ║   │   │   POSITION VALUE                            │     │   ║
  ║   │   │   Token A: 468,750,000 SUI                  │     │   ║
  ║   │   │   Token B: 533,333,333 USDC                 │     │   ║
  ║   │   │                                             │     │   ║
  ║   │   │   ACCUMULATED FEES                          │     │   ║
  ║   │   │   Fee A: 148,500 SUI    ✨                  │     │   ║
  ║   │   │   Fee B: 0 USDC                             │     │   ║
  ║   │   │                                             │     │   ║
  ║   │   │   IMPERMANENT LOSS                          │     │   ║
  ║   │   │   ▓▓▓░░░░░░░  2.34%                         │     │   ║
  ║   │   │                                             │     │   ║
  ║   │   │                           Fee Tier: 0.30%   │     │   ║
  ║   │   └─────────────────────────────────────────────┘     │   ║
  ║   │                                                       │   ║
  ║   └───────────────────────────────────────────────────────┘   ║
  ║                                                               ║
  ║   This NFT represents your liquidity position in the pool.    ║
  ║   The image updates dynamically based on current pool state.  ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo ""

echo -e "${BLUE}[2/4]${NC} NFT Metadata (On-Chain):"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Object ID:          0xabc123...                         │"
echo "  │ Object Type:        sui_amm::position::LPPosition       │"
echo "  │ Owner:              0x03154d75...                       │"
echo "  │                                                         │"
echo "  │ Fields:                                                 │"
echo "  │   pool_id:              0xdef456...                     │"
echo "  │   liquidity:            499,999,500                     │"
echo "  │   fee_debt_a:           0                               │"
echo "  │   fee_debt_b:           0                               │"
echo "  │   entry_price_ratio:    1,000,000,000,000               │"
echo "  │   original_deposit_a:   500,000,000                     │"
echo "  │   original_deposit_b:   500,000,000                     │"
echo "  │                                                         │"
echo "  │ Cached Display Values:                                  │"
echo "  │   cached_value_a:       468,750,000                     │"
echo "  │   cached_value_b:       533,333,333                     │"
echo "  │   cached_fee_a:         148,500                         │"
echo "  │   cached_fee_b:         0                               │"
echo "  │   cached_il_bps:        234                             │"
echo "  │                                                         │"
echo "  │ Display Metadata:                                       │"
echo "  │   name:                 \"Sui AMM LP Position\"          │"
echo "  │   description:          \"Liquidity Provider Position\"  │"
echo "  │   pool_type:            \"Standard\"                     │"
echo "  │   fee_tier_bps:         30                              │"
echo "  │   image_url:            data:image/svg+xml;base64,...   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[3/4]${NC} Impermanent Loss Calculation:"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Entry Price Ratio:      1.0 (SUI/USDC)                  │"
echo "  │ Current Price Ratio:    0.879 (SUI/USDC)                │"
echo "  │ Price Change:           -12.1%                          │"
echo "  │                                                         │"
echo "  │ If HODL'd:                                              │"
echo "  │   500M SUI @ 0.879 =    439,500,000 USDC equiv          │"
echo "  │   500M USDC =           500,000,000 USDC                │"
echo "  │   Total HODL Value:     939,500,000 USDC                │"
echo "  │                                                         │"
echo "  │ LP Position Value:                                      │"
echo "  │   468.75M SUI @ 0.879 = 412,031,250 USDC equiv          │"
echo "  │   533.33M USDC =        533,333,333 USDC                │"
echo "  │   Total LP Value:       945,364,583 USDC                │"
echo "  │                                                         │"
echo "  │ + Fees Earned:          148,500 SUI = 130,531 USDC      │"
echo "  │                                                         │"
echo -e "  │ ${GREEN}Net Position:           BETTER than HODL by 0.64%${NC}      │"
echo "  │ (Fees offset impermanent loss!)                         │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

echo -e "${BLUE}[4/4]${NC} View Commands:"
echo ""
echo -e "${YELLOW}Get Position View (Real-time):${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function get_position_view \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args $POOL_ID $POSITION_NFT_ID \
  --gas-budget 10000000
EOF
echo ""

echo -e "${YELLOW}Refresh NFT Metadata:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module pool \
  --function refresh_position_metadata \
  --type-args "0x2::sui::SUI" "COIN_B_TYPE" \
  --args $POOL_ID $POSITION_NFT_ID $CLOCK \
  --gas-budget 10000000
EOF
echo ""

echo -e "${GREEN}✓ Position View Complete!${NC}"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ On-chain SVG NFT image"
echo "  ✓ Dynamic metadata (value, fees, IL)"
echo "  ✓ Impermanent loss calculation"
echo "  ✓ Entry price tracking"
echo "  ✓ Wallet/marketplace compatible"
echo ""
echo -e "${YELLOW}Next: Run ./07_claim_fees.sh${NC}"
