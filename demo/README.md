# SUI AMM Demo - Video Walkthrough Guide

## 🎬 Demo Flow for Video Recording

This demo showcases all PRD requirements on localnet.

## 📁 Demo Files

```
demo/
├── README.md                 # This file
├── run_all.sh               # 🎬 Run complete demo (for video)
├── 01_deploy.sh             # Deploy contracts
├── 02_create_test_coins.sh  # Setup test environment
├── 03_create_pool.sh        # Pool creation workflow
├── 04_add_liquidity.sh      # Add liquidity + NFT mint
├── 05_swap.sh               # Swap execution
├── 06_view_position.sh      # View LP Position NFT
├── 07_claim_fees.sh         # Fee claiming
├── 08_remove_liquidity.sh   # Remove liquidity
├── 09_stable_pool.sh        # StableSwap demo
├── 10_advanced_features.sh  # Limit orders, governance, etc.
└── interactive_demo.ts      # TypeScript interactive demo
```

## 🚀 Quick Start (For Video Recording)

```bash
cd demo
./run_all.sh
```

This runs all scripts with pauses between each step - perfect for video!

## Prerequisites

```bash
# 1. Start localnet
sui start --with-faucet

# 2. Switch to localnet (new terminal)
sui client switch --env localnet

# 3. Get test SUI
sui client faucet

# 4. Check balance
sui client gas
```

## Demo Scripts

Run these in order for video:

| Script | PRD Requirement | Duration |
|--------|-----------------|----------|
| `01_deploy.sh` | Deploy contracts | 1 min |
| `02_create_pool.sh` | Pool Creation Workflow | 2 min |
| `03_add_liquidity.sh` | Add Liquidity + NFT Mint | 2 min |
| `04_swap.sh` | Swap Execution | 2 min |
| `05_view_position.sh` | View LP Position NFT | 1 min |
| `06_claim_fees.sh` | Fee Claiming | 1 min |
| `07_remove_liquidity.sh` | Remove Liquidity | 1 min |
| `08_stable_pool.sh` | StableSwap Demo | 2 min |

## Quick Start

```bash
cd demo
chmod +x *.sh
./run_all.sh
```

## What Each Script Shows

### 1. Deploy (`01_deploy.sh`)
- Publishes all contracts
- Shows PoolFactory, AdminCap creation

### 2. Create Pool (`02_create_pool.sh`)
- Creates token pair pool with 0.3% fee
- Shows PoolCreated event
- Demonstrates pool registry

### 3. Add Liquidity (`03_add_liquidity.sh`)
- Adds liquidity to pool
- **Mints LP Position NFT** ⭐
- Shows liquidity shares calculation

### 4. Swap (`04_swap.sh`)
- Executes token swap
- Shows price impact calculation
- Demonstrates slippage protection

### 5. View Position (`05_view_position.sh`)
- Displays NFT metadata
- Shows current position value
- Shows accumulated fees
- **On-chain SVG display** ⭐

### 6. Claim Fees (`06_claim_fees.sh`)
- Claims accumulated swap fees
- Shows pro-rata distribution

### 7. Remove Liquidity (`07_remove_liquidity.sh`)
- Partial/full liquidity removal
- NFT burn on full removal

### 8. StableSwap (`08_stable_pool.sh`)
- Creates stable pool (USDC-USDT style)
- Shows lower slippage for stable pairs
- Amplification coefficient demo
