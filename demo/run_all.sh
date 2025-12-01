#!/bin/bash
# ============================================
# SUI AMM - Complete Demo Walkthrough
# ============================================
# Run all demo scripts in sequence for video
# ============================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear

echo -e "${CYAN}"
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ███████╗██╗   ██╗██╗      █████╗ ███╗   ███╗███╗   ███╗        ║
║   ██╔════╝██║   ██║██║     ██╔══██╗████╗ ████║████╗ ████║        ║
║   ███████╗██║   ██║██║     ███████║██╔████╔██║██╔████╔██║        ║
║   ╚════██║██║   ██║██║     ██╔══██║██║╚██╔╝██║██║╚██╔╝██║        ║
║   ███████║╚██████╔╝██║     ██║  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║        ║
║   ╚══════╝ ╚═════╝ ╚═╝     ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝        ║
║                                                                   ║
║         Decentralized AMM with NFT LP Positions                   ║
║                                                                   ║
║   Features:                                                       ║
║   • Constant Product AMM (x*y=k)                                  ║
║   • StableSwap for Stable Pairs                                   ║
║   • NFT-based LP Positions with On-chain SVG                      ║
║   • Fee Distribution & Auto-compounding                           ║
║   • Slippage Protection & Limit Orders                            ║
║   • Governance with Timelock                                      ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo ""

echo -e "${YELLOW}Press Enter to start the demo walkthrough...${NC}"
read

# Function to run script with pause
run_step() {
    local script=$1
    local title=$2
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}$title${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    ./$script
    
    echo ""
    echo -e "${YELLOW}Press Enter to continue to next step...${NC}"
    read
    clear
}

# Run all demo scripts
run_step "01_deploy.sh" "STEP 1: Deploy Contracts"
run_step "02_create_test_coins.sh" "STEP 2: Setup Test Environment"
run_step "03_create_pool.sh" "STEP 3: Create Liquidity Pool"
run_step "04_add_liquidity.sh" "STEP 4: Add Liquidity & Mint NFT"
run_step "05_swap.sh" "STEP 5: Execute Token Swap"
run_step "06_view_position.sh" "STEP 6: View LP Position NFT"
run_step "07_claim_fees.sh" "STEP 7: Claim Accumulated Fees"
run_step "08_remove_liquidity.sh" "STEP 8: Remove Liquidity"
run_step "09_stable_pool.sh" "STEP 9: StableSwap Pool Demo"
run_step "10_advanced_features.sh" "STEP 10: Advanced Features"

echo ""
echo -e "${GREEN}"
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║                    🎉 DEMO COMPLETE! 🎉                           ║
║                                                                   ║
║   All PRD requirements demonstrated:                              ║
║                                                                   ║
║   ✓ PoolFactory - Pool creation & registry                        ║
║   ✓ LiquidityPool - Constant product AMM (x*y=k)                  ║
║   ✓ StableSwapPool - Optimized for stable pairs                   ║
║   ✓ LPPosition NFT - Dynamic metadata & on-chain SVG              ║
║   ✓ FeeDistributor - Pro-rata distribution & auto-compound        ║
║   ✓ SlippageProtection - Deadline, min output, price limits       ║
║   ✓ Limit Orders - Price-triggered execution                      ║
║   ✓ Governance - Timelock proposals                               ║
║   ✓ User Preferences - Slippage tolerance settings                ║
║   ✓ Swap History - On-chain statistics                            ║
║                                                                   ║
║   Mathematical Correctness:                                       ║
║   ✓ Constant product formula verified                             ║
║   ✓ StableSwap D-invariant verified                               ║
║   ✓ Fee calculations accurate                                     ║
║   ✓ Impermanent loss tracking                                     ║
║                                                                   ║
║   Security Features:                                              ║
║   ✓ K-invariant verification post-swap                            ║
║   ✓ Overflow protection                                           ║
║   ✓ Slippage protection                                           ║
║   ✓ Governance timelock                                           ║
║   ✓ Emergency pause mechanism                                     ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
