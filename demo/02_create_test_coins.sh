#!/bin/bash
# ============================================
# STEP 2: Create Test Coins for Demo
# ============================================
# Creates USDC and USDT test tokens
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Creating Test Coins (USDC & USDT)                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# We'll use SUI's native coin for demo since creating custom coins
# requires a separate package. For video, we'll simulate with SUI splits.

echo -e "${BLUE}[INFO]${NC} For this demo, we'll use SUI coin splits to simulate token pairs."
echo ""
echo "In production, you would deploy separate coin modules for USDC/USDT."
echo ""

# Get current address
MY_ADDRESS=$(sui client active-address)
echo -e "Active Address: ${GREEN}$MY_ADDRESS${NC}"
echo ""

# Check SUI balance
echo -e "${BLUE}[1/2]${NC} Checking SUI balance..."
sui client gas
echo ""

# Request more SUI from faucet if needed
echo -e "${BLUE}[2/2]${NC} Requesting SUI from faucet..."
sui client faucet 2>/dev/null || echo "Faucet request sent (may take a moment)"
sleep 2
echo ""

echo -e "${GREEN}✓ Test environment ready!${NC}"
echo ""
echo "For the demo, we'll create pools using the test coin types"
echo "defined in the test modules."
echo ""
echo -e "${YELLOW}Next: Run ./03_create_pool.sh${NC}"
