# Specification Deviations & Design Decisions

This document explicitly lists all intentional deviations from the PRD specification, along with rationale for each decision.

## Security Hardening Deviations

### [S1] Pool Creation Fee (5 SUI Default)

**PRD Says:** "User calls create_pool with token pair and fee tier" (no mention of fee)

**Implementation:** Requires a configurable pool creation fee (default 5 SUI, governance-adjustable 0-100 SUI)

**Rationale:** Without a creation barrier, attackers could:
- Create millions of spam pools to exhaust on-chain storage
- Degrade indexer performance
- Make pool discovery impractical for users

**Location:** `sources/factory.move:147-150`

**Mitigation:** Fee is burned (sent to @0x0), not extracted as profit. Can be set to 0 via governance if spam is not a concern.

---

### [S2] Creator Fee Cap (5% Maximum)

**PRD Says:** Pool creators can "Earn from pool creation fees (optional)"

**Implementation:** Creator fee is capped at 5% (500 bps) to protect LPs

**Rationale:** Without a cap, malicious pool creators could set 100% creator fee, extracting all swap fees from LPs.

**Location:** `sources/pool.move:35`, `sources/stable_pool.move:127`

---

### [S3] Stable Pool Requires Both Tokens

**PRD Says:** Allows adding liquidity to stable pools

**Implementation:** Stable pools require both token amounts > 0 (no single-sided deposits)

**Rationale:** Single-sided deposits in StableSwap can manipulate the D invariant, causing unexpected slippage for other users.

**Location:** `sources/stable_pool.move:199`

---

## Performance Optimizations

### [P1] NFT Metadata and On-Chain SVG

**PRD Says:** "Display current position value", "Show accumulated fees", "Display my LP NFT in wallets and marketplaces"

**Implementation:** 
- NFT cached values are NOT automatically updated on every swap (gas optimization)
- On-chain SVG generation via `svg_nft.move` module
- SVG is regenerated when metadata is refreshed

**Features:**
- Full on-chain SVG rendering (no external dependencies)
- Base64-encoded data URI for image_url
- Visual display of liquidity, value, fees, and IL
- Color-coded IL indicator (green/yellow/red)

**Mitigation for Staleness:** 
- `get_position_view()` provides real-time values on-demand
- `refresh_position_metadata()` updates cached values AND regenerates SVG
- Metadata IS auto-refreshed on: `remove_liquidity_partial()`, `withdraw_fees()`, `increase_liquidity()`

**Location:** `sources/svg_nft.move`, `sources/position.move`

---

### [P2] Pool Enumeration Limit

**PRD Says:** Pool registry and indexing

**Implementation:** `get_all_pools()` limited to 100 pools; use `get_all_pools_paginated()` for larger registries

**Rationale:** Unbounded iteration can cause gas exhaustion

**Location:** `sources/factory.move:296-305`

---

## Feature Clarifications

### [F1] Swap History is On-Chain

**PRD Says:** "View swap history and statistics"

**Implementation:** Full on-chain swap history via `swap_history.move` module

**Features:**
- `UserSwapHistory` - Per-user swap history (last 100 swaps)
- `PoolStatistics` - Per-pool statistics including 24h volume
- Cumulative volume and fee tracking
- Paginated history retrieval

**Location:** `sources/swap_history.move`

---

### [F2] Slippage Preferences are User-Owned

**PRD Says:** "Set slippage tolerance preferences"

**Implementation:** `UserPreferences` object is owned by user, not stored in pool

**Rationale:** User preferences are personal and should be controlled by the user, not the protocol.

**Location:** `sources/user_preferences.move`

---

### [F3] Limit Orders Use Spot Price

**PRD Says:** "Price limit orders"

**Implementation:** Limit orders compare against spot price (reserve ratio), not execution price

**Semantics:**
- `target_price` = Maximum amount of input token user is willing to pay per 1 output token (scaled by 1e9)
- For A→B swap: Execute when `reserve_a/reserve_b <= target_price`
- For B→A swap: Execute when `reserve_b/reserve_a <= target_price`
- This is a "sell limit order" - sell input token when output token is cheap enough

**Rationale:** Spot price is deterministic and can be checked before execution. Execution price depends on trade size.

**Location:** `sources/limit_orders.move:143-175`

---

## Governance Additions

### [G1] 48-Hour Timelock

**PRD Says:** (Not specified)

**Implementation:** All parameter changes require 48-hour timelock via governance

**Rationale:** Prevents instant malicious parameter changes; gives users time to exit if they disagree with changes.

**Location:** `sources/governance.move:17`

---

### [G2] Amp Ramping Safety Limits

**PRD Says:** "Amplification coefficient for curve adjustment"

**Implementation:** Amp changes limited to 2x increase or 0.5x decrease per ramp, minimum 24-hour duration

**Rationale:** Sudden amp changes can cause significant value extraction. Gradual ramping protects LPs.

**Location:** `sources/stable_pool.move:1073-1082`

---

## Bug Fixes Applied

### [BF1] Fee Debt Precision in Partial Removal

**Issue:** Integer division in fee debt calculation caused cumulative fee loss for users doing multiple partial removals.

**Fix:** Use ceiling division for debt removal to ensure users never lose fees.

**Location:** `sources/pool.move:395-410`, `sources/stable_pool.move:395-410`

---

### [BF2] Strict D-Invariant Check in StableSwap

**Issue:** 1 bps tolerance on D-invariant allowed value extraction through repeated swaps.

**Fix:** Strict check requiring `d_new + 1 >= d` (only allowing +1 for rounding).

**Location:** `sources/stable_pool.move:548-551`, `sources/stable_pool.move:648-651`

---

## Summary

All deviations are made for:
1. **Security** - Preventing attacks and protecting user funds
2. **Performance** - Ensuring gas efficiency at scale
3. **Practicality** - Making the protocol usable in production

All PRD requirements are now implemented on-chain:
- ✅ Swap history and statistics (`swap_history.move`)
- ✅ LP NFT display in wallets/marketplaces (`svg_nft.move` - on-chain SVG)
- ✅ Slippage tolerance preferences (`user_preferences.move`)
- ✅ Price limit orders (`limit_orders.move`)
- ✅ Impermanent loss calculations (`pool.move`, `stable_pool.move`)
- ✅ Fee distribution and auto-compounding (`fee_distributor.move`)

None of these deviations reduce functionality; they add guardrails that a production DeFi protocol requires.
