# Sui AMM Demo Walkthrough

This document guides you through the `demo_script.move` test, which simulates a complete user journey on the Sui AMM.

## Overview

The demo script demonstrates the following core features:
1.  **Pool Creation**: Creating a standard AMM pool with initial liquidity.
2.  **Swapping**: Executing trades to generate volume and fees.
3.  **Dynamic Metadata**: Verifying that LP NFT metadata (fees, value, IL) updates correctly.
4.  **Fee Claiming**: Withdrawing accumulated trading fees.
5.  **Liquidity Removal**: Removing liquidity and burning the LP NFT.

## Running the Demo

To run the demo script, execute the following command in your terminal:

```bash
sui move test --path . --filter demo_script
```

## Expected Output

You should see output indicating the success of each step:

```text
[debug] "Step 1: Pool Created"
[debug] "Step 2: Swaps Executed"
[debug] "Step 3: Metadata Verified - Fees accumulated"
[debug] "Step 4: Fees Claimed"
[debug] "Step 5: Liquidity Removed"
```

## Detailed Steps

### 1. Setup & Pool Creation
- The script initializes the `Clock` and test scenario.
- It mints test tokens (`COIN_A`, `COIN_B`) and `SUI` for the creation fee.
- Calls `factory::create_pool` to establish a new pool with a 0.3% fee tier.

### 2. Trading Activity
- A separate user performs a swap (A -> B).
- This action changes the reserve ratio (causing Impermanent Loss) and generates trading fees.

### 3. Metadata Verification
- The script retrieves the LP Position NFT.
- It calls `pool::refresh_position_metadata` to force an update (simulating a view or interaction).
- It asserts that `cached_fee_a` is greater than 0, proving fee accumulation.
- It asserts that `cached_il_bps` is greater than 0, proving IL calculation.

### 4. Fee Claiming
- The LP calls `fee_distributor::claim_fees`.
- The script verifies that fee coins are received.

### 5. Liquidity Removal
- The LP removes all liquidity.
- The script verifies that the principal tokens are returned.
