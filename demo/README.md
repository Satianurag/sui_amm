# SUI AMM Demo

Interactive demo scripts for the SUI AMM decentralized exchange.

## Prerequisites

Before running the demo, you need:

1. **Sui CLI** installed ([installation guide](https://docs.sui.io/guides/developer/getting-started/sui-install))
2. **jq** installed (JSON processor)
   ```bash
   # Ubuntu/Debian
   sudo apt install jq
   
   # macOS
   brew install jq
   ```

## Quick Start (Automated)

The easiest way to run the full demo:

```bash
# 1. Start Sui localnet (in a separate terminal)
RUST_LOG=off,sui_node=warn sui start --with-faucet --force-regenesis

# 2. Wait ~15 seconds for localnet to start, then run:
cd demo
./run_automated.sh
```

That's it! The automated script handles everything.

## Manual Step-by-Step

If you prefer running scripts individually:

```bash
# 1. Start localnet (separate terminal)
RUST_LOG=off,sui_node=warn sui start --with-faucet --force-regenesis

# 2. Wait for localnet, then get test SUI
sui client faucet
sleep 5

# 3. Run scripts in order
cd demo
./01_deploy.sh
./02_create_test_coins.sh
./03_create_pool.sh
./04_add_liquidity.sh
./05_swap.sh
./06_view_position.sh
./07_claim_fees.sh
./08_remove_liquidity.sh
./09_stable_pool.sh
./10_advanced_features.sh
```

## Common Issues & Solutions

### "Connection refused" error
**Problem:** Localnet isn't running.
**Solution:** Start localnet first:
```bash
RUST_LOG=off,sui_node=warn sui start --with-faucet --force-regenesis
```

### "No gas coins found" error
**Problem:** Your wallet has no SUI tokens.
**Solution:** Request from faucet:
```bash
sui client faucet
sleep 5  # Wait for faucet
sui client gas  # Verify you have SUI
```

### "POOL_ID not found" error
**Problem:** Running scripts out of order.
**Solution:** Run scripts in numerical order (01, 02, 03...) or use `run_automated.sh`.

### Deploy fails silently
**Problem:** Not enough gas or localnet issues.
**Solution:** 
```bash
# Check you have enough SUI (need ~2 SUI for deploy)
sui client gas

# If low, request more
sui client faucet
```

### "Invalid fee tier" error
**Problem:** Using wrong fee value for pool creation.
**Solution:** Valid fee tiers are: 5 (0.05%), 30 (0.30%), 100 (1.00%) basis points.

## Demo Scripts Overview

| Script | What it does |
|--------|--------------|
| `01_deploy.sh` | Deploys all AMM contracts |
| `02_create_test_coins.sh` | Creates USDC & USDT test tokens |
| `03_create_pool.sh` | Creates SUI-USDC liquidity pool |
| `04_add_liquidity.sh` | Adds liquidity, mints LP NFT |
| `05_swap.sh` | Executes a token swap |
| `06_view_position.sh` | Shows LP position details |
| `07_claim_fees.sh` | Info about fee claiming |
| `08_remove_liquidity.sh` | Info about removing liquidity |
| `09_stable_pool.sh` | Creates USDC-USDT stable pool |
| `10_advanced_features.sh` | Shows limit orders, governance |

## Files

```
demo/
├── run_automated.sh          # ⭐ Run this for full demo
├── 01_deploy.sh              # Deploy contracts
├── 02_create_test_coins.sh   # Create test tokens
├── 03_create_pool.sh         # Create pool
├── 04_add_liquidity.sh       # Add liquidity
├── 05_swap.sh                # Execute swap
├── 06_view_position.sh       # View LP position
├── 07_claim_fees.sh          # Fee claiming info
├── 08_remove_liquidity.sh    # Remove liquidity info
├── 09_stable_pool.sh         # StableSwap demo
├── 10_advanced_features.sh   # Advanced features
├── test_coins/               # Test token package
└── .env                      # Generated config (after deploy)
```

## Environment Variables

After running `01_deploy.sh`, a `.env` file is created with:
- `PACKAGE_ID` - Deployed AMM package
- `POOL_REGISTRY` - Pool registry object
- `POOL_ID` - Created pool (after `03_create_pool.sh`)
- `COIN_PACKAGE_ID` - Test coins package
- etc.

## Tips

1. **Always start fresh:** If something breaks, restart localnet with `--force-regenesis`
2. **Check gas:** Make sure you have enough SUI before each script
3. **Read output:** Scripts show what's happening and next steps
4. **Use automated script:** `run_automated.sh` handles all the complexity
