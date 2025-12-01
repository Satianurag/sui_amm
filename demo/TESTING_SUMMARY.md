# Demo Scripts - Testing Summary

## Fixes Applied

All demo scripts have been updated to execute **real transactions** on localnet instead of simulations:

### 1. **JSON Parsing Issues** ✅
- Removed `2>&1` stderr redirection that was breaking JSON parsing
- Added `select(.objectType != null)` filters to handle null values in jq queries

### 2. **Coin Finding** ✅  
- Fixed balance field: Changed `.balance` to `.mistBalance` (new Sui CLI format)
- Fixed coin finding: Use `sui client objects` instead of `sui client gas` for custom coins

### 3. **Coin Splitting** ✅
- `sui client split-coin` only works for SUI coins, not custom coins
- Solution: Use full USDC/USDT coin objects directly for pool creation (contracts accept whole coins)
- For SUI: Continue using `split-coin` command

### 4. **Test Coins Package** ✅
- Created separate `demo/test_coins` package with USDC and USDT modules
- Keeps main source code clean (no modifications to `sources/`)
- Mints 1M USDC and 1M USDT to active address

## Quick Start

```bash
cd demo

# 1. Start localnet (in separate terminal)
sui start --with-faucet --force-regenesis

# 2. Get test SUI tokens
for i in {1..5}; do sui client faucet; sleep 2; done

# 3. Run the demo
./run_all.sh
```

## Individual Script Testing

```bash
# Deploy contracts
./01_deploy.sh

# Mint test coins (USDC, USDT)
./02_create_test_coins.sh

# Create SUI-USDC pool
./03_create_pool.sh

# Add more liquidity
./04_add_liquidity.sh

# Execute a swap
./05_swap.sh

# View LP position NFT
./06_view_position.sh

# Claim accumulated fees
./07_claim_fees.sh

# Remove liquidity
./08_remove_liquidity.sh

# Create stable pool (USDC-USDT)
./09_stable_pool.sh
```

## Key Changes Made

### `01_deploy.sh`
- Changed JSON capture to avoid stderr mixing
- Improved object ID extraction

### `02_create_test_coins.sh`
- Deploys separate `test_coins` package
- Mints real USDC and USDT using `sui::coin::mint_and_transfer`
- Saves `COIN_PACKAGE_ID`, `USDC_TREASURY`, `USDT_TREASURY` to `.env`

### `03_create_pool.sh`
- Uses `sui client split-coin` for SUI
- Uses whole USDC coin object (avoids custom coin splitting issues)
- Creates real SUI-USDC pool with 100 SUI + 1M USDC initial liquidity
- Extracts and saves `POOL_ID` and `NFT_ID`

### `04_add_liquidity.sh`
- Splits 50 SUI and 50 USDC for additional liquidity
- Calls `pool::add_liquidity` with real coin objects
- Mints new LP NFT position

### `05_swap.sh`
- Splits 10 SUI for swap input
- Calls `pool::swap_a_to_b` to swap SUI for USDC
- Demonstrates real price impact and slippage

### `06_view_position.sh`
- Fetches actual NFT object from chain
- Displays on-chain metadata

### `07_claim_fees.sh`
- Executes `pool::claim_fees` with NFT position
- Transfers accumulated fees to LP

### `08_remove_liquidity.sh`
- Calls `pool::remove_liquidity` to withdraw funds
- Burns or updates NFT position

### `09_stable_pool.sh`
- Creates USDC-USDT stable pool using `factory::create_stable_pool`
- Demonstrates low-slippage stable swaps

## Token Efficiency

The scripts are designed to be token-efficient:
- Reuses coin objects where possible
- Only splits SUI (not custom coins)
- Uses gas budget appropriately
- Saves all IDs to `.env` for reuse across scripts

## Next Steps

1. ✅ All scripts converted to real transactions
2. ✅ Test coins package created
3. **TODO**: Run full end-to-end test on localnet
4. **TODO**: Record demo video using `./run_all.sh`

## Notes

- Localnet must be running before executing scripts
- Ensure sufficient SUI tokens (request from faucet 5 times)
- The `.env` file stores all deployed object IDs
- Each script can be run independently after deployment
