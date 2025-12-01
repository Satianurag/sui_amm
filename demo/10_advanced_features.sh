#!/bin/bash
# ============================================
# STEP 10: Advanced Features Demo
# ============================================
# PRD: Additional Features
# - Limit Orders
# - Governance (Timelock)
# - User Preferences
# - Swap History
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Advanced Features Demo                            ║"
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

echo "════════════════════════════════════════════════════════════"
echo -e "${CYAN}FEATURE 1: Price Limit Orders${NC}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "PRD: \"Price limit orders\" in SlippageProtection"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Limit orders execute automatically when target price    │"
echo "  │ is reached. Anyone can trigger execution (keeper model).│"
echo "  │                                                         │"
echo "  │ Example:                                                │"
echo "  │   \"Sell 100 SUI when price reaches 1.2 USDC/SUI\"       │"
echo "  │                                                         │"
echo "  │ Features:                                               │"
echo "  │   • Deposit tokens into order                           │"
echo "  │   • Set target price and expiry                         │"
echo "  │   • Anyone can execute when conditions met              │"
echo "  │   • Cancel anytime to reclaim deposit                   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}Create Limit Order:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module limit_orders \
  --function create_limit_order \
  --type-args "0x2::sui::SUI" "USDC_TYPE" \
  --args \
    $ORDER_REGISTRY \
    $POOL_ID \
    true \              # is_a_to_b (SUI → USDC)
    $COIN_IN \          # deposit
    1200000000 \        # target_price (1.2 scaled by 1e9)
    95000000 \          # min_amount_out
    $CLOCK \
    $EXPIRY_TIMESTAMP \
  --gas-budget 50000000
EOF
echo ""

echo "════════════════════════════════════════════════════════════"
echo -e "${CYAN}FEATURE 2: Governance with Timelock${NC}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "PRD: Protocol fee collection, parameter changes"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ All protocol changes go through 48-hour timelock:       │"
echo "  │                                                         │"
echo "  │   1. Admin proposes change                              │"
echo "  │   2. 48-hour waiting period                             │"
echo "  │   3. Anyone can execute after timelock                  │"
echo "  │   4. Proposals expire after 7 days                      │"
echo "  │                                                         │"
echo "  │ Proposal Types:                                         │"
echo "  │   • Fee changes                                         │"
echo "  │   • Risk parameter updates                              │"
echo "  │   • Pool pause/unpause                                  │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}Propose Fee Change:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module governance \
  --function propose_fee_change \
  --args \
    $ADMIN_CAP \
    $GOV_CONFIG \
    $POOL_ID \
    50 \                # new_fee_percent (0.5%)
    $CLOCK \
  --gas-budget 50000000
EOF
echo ""
echo "  → Proposal created, executable after 48 hours"
echo ""

echo "════════════════════════════════════════════════════════════"
echo -e "${CYAN}FEATURE 3: User Preferences${NC}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "PRD: \"Set slippage tolerance preferences\""
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Users can save their trading preferences on-chain:      │"
echo "  │                                                         │"
echo "  │   • Default slippage tolerance (0.5% default)           │"
echo "  │   • Transaction deadline (20 min default)               │"
echo "  │   • Auto-compound preference                            │"
echo "  │   • Max price impact tolerance                          │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}Create User Preferences:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module user_preferences \
  --function create_and_transfer \
  --args $MY_ADDRESS \
  --gas-budget 10000000
EOF
echo ""
echo -e "${YELLOW}Update Preferences:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module user_preferences \
  --function update_all \
  --args \
    $PREFS_OBJECT \
    100 \               # slippage_bps (1%)
    1800 \              # deadline_seconds (30 min)
    true \              # auto_compound
    500 \               # max_price_impact_bps (5%)
  --gas-budget 10000000
EOF
echo ""

echo "════════════════════════════════════════════════════════════"
echo -e "${CYAN}FEATURE 4: Swap History & Statistics${NC}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "PRD: \"View swap history and statistics\""
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ On-chain tracking of:                                   │"
echo "  │                                                         │"
echo "  │ Per User:                                               │"
echo "  │   • Last 100 swaps                                      │"
echo "  │   • Total volume traded                                 │"
echo "  │   • Total fees paid                                     │"
echo "  │                                                         │"
echo "  │ Per Pool:                                               │"
echo "  │   • Recent 50 swaps                                     │"
echo "  │   • Total volume (A and B)                              │"
echo "  │   • Total fees collected                                │"
echo "  │   • 24h rolling statistics                              │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}Create User History:${NC}"
cat << 'EOF'
sui client call \
  --package $PACKAGE_ID \
  --module swap_history \
  --function create_and_transfer_history \
  --args $MY_ADDRESS \
  --gas-budget 10000000
EOF
echo ""

echo "════════════════════════════════════════════════════════════"
echo -e "${CYAN}FEATURE 5: Emergency Controls${NC}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Admin can pause pools in emergencies:                   │"
echo "  │                                                         │"
echo "  │   • Pause blocks swaps and liquidity changes            │"
echo "  │   • Fee claims still allowed                            │"
echo "  │   • Unpause resumes normal operation                    │"
echo "  │                                                         │"
echo "  │ Note: Pause now requires governance proposal with       │"
echo "  │ timelock to prevent instant pause abuse.                │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

echo -e "${GREEN}✓ Advanced Features Demo Complete!${NC}"
echo ""
echo "Summary of Advanced Features:"
echo "  ✓ Price limit orders with keeper execution"
echo "  ✓ Governance with 48-hour timelock"
echo "  ✓ User preferences (slippage, deadline, auto-compound)"
echo "  ✓ On-chain swap history and statistics"
echo "  ✓ Emergency pause/unpause controls"
echo "  ✓ Protocol fee collection"
echo ""
echo -e "${YELLOW}Demo Complete! Run ./run_all.sh for full walkthrough.${NC}"
