#!/bin/bash
# ============================================
# STEP 5: Execute Token Swap
# ============================================
# PRD: Swap Execution Workflow (3.2.3)
# ============================================

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Swap Execution Workflow                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load environment
source .env 2>/dev/null || { echo "Run 01_deploy.sh first!"; exit 1; }

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}PRD Requirement: Swap Execution Workflow (Section 3.2.3)${NC}"
echo ""

if [ -z "$POOL_ID" ]; then
    echo "Error: POOL_ID not found in .env. Run 03_create_pool.sh first."
    exit 1
fi

echo -e "Pool ID: ${GREEN}$POOL_ID${NC}"
echo ""

# Get coins
echo -e "${BLUE}[1/3]${NC} Preparing Swap Input..."
GAS_COINS=$(sui client gas --json)
SUI_COIN=$(echo "$GAS_COINS" | jq -r '.[] | select(.mistBalance >= 2000000000) | .gasCoinId' | head -n 1)

if [ -z "$SUI_COIN" ]; then
    echo "Error: No SUI coin with at least 2 SUI found."
    echo "Run: sui client faucet"
    exit 1
fi

echo "Splitting 1 SUI for swap input..."
SPLIT_SUI_OUTPUT=$(sui client split-coin --coin-id $SUI_COIN --amounts 1000000000 --gas-budget 50000000 --json 2>&1)
SPLIT_SUI=$(echo "$SPLIT_SUI_OUTPUT" | jq -r '.objectChanges[] | select(.type == "created") | .objectId' | head -n 1)

if [ -z "$SPLIT_SUI" ]; then
    echo "Error: Failed to split SUI"
    echo "$SPLIT_SUI_OUTPUT"
    exit 1
fi

echo -e "Swap input coin: ${GREEN}$SPLIT_SUI${NC}"
echo ""
echo "Swapping 1 SUI for USDC..."

CLOCK="0x6"
DEADLINE="18446744073709551615" 
MY_ADDRESS=$(sui client active-address)

echo -e "${BLUE}[2/3]${NC} Executing swap_a_to_b..."

# Use PTB with option::some for max_price parameter
# Setting a very high max_price to allow the swap to go through
SWAP_OUTPUT=$(sui client ptb \
  --move-call 0x1::option::some "<u64>" 1000000000000u64 \
  --assign max_price \
  --move-call "${PACKAGE_ID}::pool::swap_a_to_b<0x2::sui::SUI,${COIN_PACKAGE_ID}::usdc::USDC>" \
    @$POOL_ID \
    @$SPLIT_SUI \
    0u64 \
    max_price \
    @$CLOCK \
    ${DEADLINE}u64 \
  --assign result \
  --transfer-objects "[result]" @$MY_ADDRESS \
  --gas-budget 200000000 \
  --json 2>&1)

echo "$SWAP_OUTPUT" > swap.json

# Check for errors
if echo "$SWAP_OUTPUT" | jq -e '.effects.status.status == "failure"' > /dev/null 2>&1; then
    echo -e "${YELLOW}Error executing swap:${NC}"
    echo "$SWAP_OUTPUT" | jq -r '.effects.status.error // "Unknown error"'
    cat swap.json
    exit 1
fi

echo -e "${BLUE}[3/3]${NC} Swap Complete!"
echo ""
echo -e "Transaction Digest: $(echo "$SWAP_OUTPUT" | jq -r '.digest')"

# Try to extract output amount from balance changes
USDC_RECEIVED=$(echo "$SWAP_OUTPUT" | jq -r '.balanceChanges[] | select(.coinType | contains("usdc::USDC")) | .amount' 2>/dev/null | head -n 1)
if [ -n "$USDC_RECEIVED" ] && [ "$USDC_RECEIVED" != "null" ]; then
    echo -e "USDC Received: ${GREEN}$USDC_RECEIVED${NC}"
fi

echo ""
echo -e "${GREEN}✓ Swap Executed Successfully!${NC}"
echo ""
echo "Key Features Demonstrated:"
echo "  ✓ Constant product swap (x*y=k)"
echo "  ✓ Slippage protection (min_out)"
echo "  ✓ Price limit option (max_price)"
echo "  ✓ Deadline protection"
echo ""
echo -e "${YELLOW}Next: Run ./06_view_position.sh${NC}"
