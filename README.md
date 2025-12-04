# SUI AMM - Decentralized AMM with NFT LP Positions

A sophisticated automated market maker (AMM) protocol on Sui blockchain featuring NFT-based LP positions, StableSwap pools, and advanced DeFi capabilities.

## Testnet Deployment

**Network:** Sui Testnet  

| Resource | Address |
|----------|---------|
| Package ID | `0x6ddd7fa2cb774fdf82425c70f0f54797abef9f6b74e42d260c0d0ad3dc148001` |
| PoolRegistry | `0xa3f09fde64bafa93790f85f526ef4af002fcfe72214761090294e1f94216a8e0` |
| StatisticsRegistry | `0xd3da6ae9f10c018e289e6c45e52867632c9b6c6974fa81bff599eea28c78d873` |
| OrderRegistry | `0xfc6e61245144e3c9dea60448b5bc46525caf1f98c95699895bc99474dda8b4b2` |
| GovernanceConfig | `0x36d7e0d53f3fe1b88138f2f4532ad2e3ae981bb21b63c57158e9b6f31fc1aa87` |
| Publisher | `0x069365f26289a9187475a106552adc33c57582bda6b16213cd0d007a954d2505` |
| AdminCap | `0xcfef50a23eec5c9c7d598f5ac3f546d7a842523e2cbc19f55153c2e496fa0d5c` |
| UpgradeCap | `0x96f2e09bc5d16701122d00cac0674204b8c9e2a09a29aab760ca24a56d3cc932` |

**Deployment Digest:** `5iMW4cq1M7sULbEG2PgD295HwyTRZg4N3vaPpYdD1YqY`

**Explorer:** [View on Sui Explorer](https://suiscan.xyz/testnet/object/0x6ddd7fa2cb774fdf82425c70f0f54797abef9f6b74e42d260c0d0ad3dc148001)

> 📝 **Full deployment details and transaction history**: See [TESTNET_DEPLOYMENT.md](./TESTNET_DEPLOYMENT.md)

## Table of Contents
- [Testnet Deployment](#testnet-deployment)
- [Features](#features)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Demo](#demo)
- [Core Modules](#core-modules)
- [Usage Examples](#usage-examples)
- [Testing](#testing)
- [Gas Benchmarks](#gas-benchmarks)
- [Security](#security)

---

## Features

### Core Trading
- **Constant Product AMM** - Standard x*y=k pools for volatile pairs
- **StableSwap Pools** - Curve-style low-slippage pools for stable assets
- **Multi-Tier Fees** - 0.05%, 0.3%, and 1% fee tiers
- **Slippage Protection** - Deadline enforcement and minimum output guarantees
- **Price Impact Limits** - Configurable maximum slippage per pool

### NFT LP Positions
- **Dynamic NFT Metadata** - Real-time position value and fees displayed on-chain
- **SVG Generation** - Beautiful, on-chain generated LP position NFTs
- **Transferable Positions** - LP positions can be transferred or traded
- **Fee Tracking** - Automatic fee accrual tracking per position
- **Impermanent Loss** - Real-time IL calculation and display

### Advanced Features
- **Fee Auto-Compounding** - One-click reinvestment of earned fees
- **Limit Orders** - Decentralized limit order book with expiry
- **Governance** - Timelock-based parameter adjustments
- **Swap History** - On-chain analytics and statistics tracking
- **Gas-Optimized** - Extensive optimizations for minimal transaction costs

### Security
- **Minimum Liquidity Burn** - Prevents pool manipulation attacks
- **DoS Protection** - Pool creation fees and registry limits
- **Reentrancy Guards** - Fee debt accounting prevents double-claiming
- **Overflow Protection** - u128 arithmetic for large values
- **Governance Timelock** - 24-hour delay for critical changes

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Factory (Registry)                    │
│  • Pool creation & indexing                             │
│  • Fee tier management                                  │
│  • DoS protection (10 SUI creation fee)                 │
└─────────────────┬───────────────────────────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
┌───────▼──────┐    ┌──────▼────────┐
│ Standard Pool│    │ Stable Pool   │
│  (x*y=k)     │    │ (StableSwap)  │
└───────┬──────┘    └──────┬────────┘
        │                   │
        └─────────┬─────────┘
                  │
        ┌─────────▼─────────┐
        │   LP Position NFT  │
        │  • Ownership       │
        │  • Fee tracking    │
        │  • SVG display     │
        └─────────┬──────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
┌───────▼─────┐    ┌───────▼────────┐
│Fee Distrib. │    │  Governance    │
│• Claim fees │    │ • Timelocks    │
│• Compound   │    │ • Proposals    │
└─────────────┘    └────────────────┘
```

---

## Quick Start

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd sui_amm

# Build the project
sui move build

# Run tests
sui move test
```

### Deploy

```bash
# Publish to testnet
sui client publish --gas-budget 500000000
```

## Core Modules

### 1. Factory (`factory.move`)

Central registry for pool creation and discovery.

**Key Functions:**
- `create_pool<CoinA, CoinB>()` - Create standard AMM pool
- `create_stable_pool<CoinA, CoinB>()` - Create StableSwap pool
- `get_pool_id()` - Lookup pool by token pair and fee tier
- `add_fee_tier()` - Admin function to add new fee tiers

**Features:**
- Atomic pool creation with initial liquidity
- Per-token pool limits (500 max) for DoS protection
- Global pool cap (50,000 pools)
- Reverse lookup: pool ID → pool metadata

### 2. Liquidity Pool (`pool.move`)

Standard constant product AMM implementation.

**Key Functions:**
- `add_liquidity()` - Add liquidity and receive LP NFT
- `remove_liquidity()` - Burn LP position for underlying tokens
- `swap_a_to_b()` / `swap_b_to_a()` - Execute swaps with fees
- `withdraw_fees()` - Claim accumulated fees
- `preview_swap_output()` - Quote swap without execution

**Formula:** `x * y = k`

**Features:**
- Minimum liquidity burn (1,000 shares to address 0x0)
- Pro-rata fee distribution
- Price impact calculation
- Ratio tolerance for liquidity additions (0.5%)

### 3. Stable Pool (`stable_pool.move`)

StableSwap invariant for low-slippage stable pairs.

**Key Functions:**
- `add_liquidity()` - Add liquidity to stable pool
- `remove_liquidity()` - Remove liquidity
- `swap_a_to_b()` / `swap_b_to_a()` - Low-slippage swaps
- `start_ramp_amp()` - Gradually adjust amplification
- `stop_ramp_amp()` - Emergency stop amp ramping

**Formula:** StableSwap invariant (Curve-style)
```
A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
```

**Features:**
- Amplification coefficient (1-1000)
- Gradual amp ramping for safety
- Lower fees for stable pairs
- Same NFT position system as standard pools

### 4. LP Position NFT (`position.move`)

NFT representation of liquidity positions.

**Key Functions:**
- `new()` - Create new position NFT
- `increase_liquidity()` - Add to existing position
- `decrease_liquidity()` - Partial removal
- `calculate_pending_fees()` - View claimable fees
- `calculate_impermanent_loss()` - View current IL

**Cached Metadata:**
- Current position value (token A & B)
- Pending fees (token A & B)
- Impermanent loss percentage
- Pool type and fee tier
- SVG image URL

**Precision:** 1e12 for IL calculations (upgraded from 1e9)

### 5. Fee Distributor (`fee_distributor.move`)

Manages fee claiming and auto-compounding.

**Key Functions:**
- `claim_fees()` - Withdraw earned fees
- `compound_fees()` - Auto-reinvest fees into position
- `is_worth_compounding()` - Check if fees exceed dust threshold

**Features:**
- Dust prevention (1,000 unit minimum)
- Gas-efficient compounding
- Works with both pool types
- Defense against double-claiming

### 6. Governance (`governance.move`)

Timelock-based parameter governance.

**Key Functions:**
- `propose_fee_change()` - Propose protocol fee adjustment
- `propose_parameter_change()` - Propose pool parameter change
- `propose_pause()` - Propose emergency pause
- `execute_*()` - Execute approved proposals

**Features:**
- 24-hour timelock for safety
- Proposal expiry (7 days)
- Admin-only proposal creation
- Per-pool parameter control

### 7. Limit Orders (`limit_orders.move`)

Decentralized limit order book.

**Key Functions:**
- `create_limit_order()` - Place limit order
- `execute_limit_order_a_to_b()` - Fill order when price reached
- `cancel_limit_order()` - Cancel unfilled order
- `get_user_orders()` - View user's active orders

**Features:**
- Anyone can execute orders when price target met
- Expiry timestamps
- Per-pool and per-user indexing
- Automatic execution at target price

### 8. Slippage Protection (`slippage_protection.move`)

Transaction safety mechanisms.

**Key Functions:**
- `check_deadline()` - Enforce transaction deadlines
- `check_slippage()` - Verify minimum output received
- `check_price_limit()` - Validate price limits
- `calculate_slippage_bps()` - Compute slippage percentage

### 9. SVG NFT (`svg_nft.move`)

On-chain SVG generation for LP positions.

**Key Functions:**
- `generate_lp_position_svg()` - Create full position card
- `generate_badge_svg()` - Create compact badge

**Features:**
- Gradient backgrounds
- Real-time value display
- Fee and IL indicators
- Color-coded impermanent loss
- Fully on-chain (no IPFS/external hosting)

### 10. Additional Modules

- **Math** (`math.move`) - Safe arithmetic operations
- **Stable Math** (`stable_math.move`) - StableSwap invariant calculations
- **Swap History** (`swap_history.move`) - Analytics and statistics
- **User Preferences** (`user_preferences.move`) - Per-user settings
- **Admin** (`admin.move`) - Admin capability management
- **Base64** (`base64.move`) - Base64 encoding for SVG data URIs

---

## Usage Examples

### Create a Pool

```move
use sui_amm::factory;

// Create USDC/USDT stable pool with 0.05% fee
let (position, refund_a, refund_b) = factory::create_stable_pool<USDC, USDT>(
    registry,
    statistics_registry,
    5,      // 0.05% fee
    10,     // 0.1% creator fee
    100,    // amplification coefficient
    coin_usdc,  // initial liquidity
    coin_usdt,  // initial liquidity
    creation_fee,  // 10 SUI
    clock,
    ctx
);
```

### Add Liquidity

```move
use sui_amm::pool;

// Add liquidity to existing pool
let (position, refund_a, refund_b) = pool::add_liquidity<USDC, USDT>(
    pool,
    coin_a,
    coin_b,
    min_liquidity,  // minimum LP shares to receive
    clock,
    deadline_ms,    // transaction deadline
    ctx
);

// The position is an NFT you can hold, transfer, or display
transfer::public_transfer(position, user_address);
```

### Swap Tokens

```move
use sui_amm::pool;

// Swap USDC for USDT
let output_coin = pool::swap_a_to_b<USDC, USDT>(
    pool,
    input_coin,
    min_output,     // slippage protection
    option::none(), // no price limit
    clock,
    deadline_ms,
    ctx
);
```

### Claim Fees

```move
use sui_amm::fee_distributor;

// Claim accumulated fees
let (fee_a, fee_b) = fee_distributor::claim_fees<USDC, USDT>(
    pool,
    position,  // your LP position NFT
    clock,
    deadline_ms,
    ctx
);
```

### Auto-Compound Fees

```move
use sui_amm::fee_distributor;

// Automatically reinvest fees into position
let (refund_a, refund_b) = fee_distributor::compound_fees<USDC, USDT>(
    pool,
    position,
    min_liquidity,
    clock,
    deadline_ms,
    ctx
);
```

### Place Limit Order

```move
use sui_amm::limit_orders;

// Create limit order to buy USDT with USDC at specific price
let order_id = limit_orders::create_limit_order<USDC, USDT>(
    registry,
    pool_id,
    true,          // A to B direction
    coin_usdc,     // deposit
    target_price,  // desired price (scaled by 1e9)
    min_output,
    clock,
    expiry_timestamp,
    ctx
);
```

---

## Testing

### Test Structure

The project includes 24 comprehensive test modules:

**Core Tests:**
- `test_factory.move` - Pool creation and registry
- `test_pool_core.move` - Basic AMM operations
- `test_stable_pool.move` - StableSwap functionality
- `test_position.move` - NFT position management
- `test_fee_distributor.move` - Fee operations

**Security Tests:**
- `test_attack_vectors.move` - Attack simulations
- `test_overflow.move` - Arithmetic overflow scenarios
- `test_invariants.move` - Pool invariant verification
- `test_k_invariant.move` - Constant product validation

**Edge Case Tests:**
- `test_edge_cases.move` - Boundary conditions
- `test_slippage.move` - Slippage protection
- `test_multi_lp.move` - Multiple liquidity providers

**Advanced Tests:**
- `test_governance.move` - Governance proposals
- `test_limit_orders.move` - Order book functionality
- `test_workflows.move` - End-to-end scenarios

### Run Tests

```bash
# Run all tests
sui move test

# Run specific test module
sui move test test_pool_core

# Run with gas profiling
sui move test --gas-limit 500000000

# Run with coverage
sui move test --coverage
```

### Test Coverage

The test suite achieves **>80% code coverage** across all modules with **320 passing tests**:
- AMM mathematics verification
- Fee calculation accuracy
- Edge case handling (large/small amounts)
- Concurrent operations
- Attack vector simulations
- Gas benchmarking
- Property-based testing for correctness

**Test Results:**
- ✅ 320/320 tests passing
- ✅ Zero warnings in build and test
- ✅ All property-based tests passing
- ✅ 100% success rate

---

## Gas Benchmarks

Comprehensive gas consumption measurements for all core operations:

### Summary

| Operation | Pool Type | Gas Cost | Notes |
|-----------|-----------|----------|-------|
| **Create Pool** | Standard | ~2,150,000 | Includes initial liquidity + NFT |
| **Create Pool** | Stable | ~2,300,000 | Includes D-invariant calculation |
| **Add Liquidity** | Standard | ~485,000 | Initial (with NFT mint) |
| **Add Liquidity** | Standard | ~420,000 | Subsequent |
| **Swap** | Standard | ~295,000 | Constant product formula |
| **Swap** | Stable | ~380,000 | StableSwap formula |
| **Remove Liquidity** | Standard | ~380,000 | Partial withdrawal |
| **Claim Fees** | Both | ~185,000 | Fee withdrawal only |
| **Auto-Compound** | Both | ~595,000 | Claim + reinvest |

### Key Insights

- **Efficient Swaps**: Standard swaps consume only ~295K gas, optimized for frequent trading
- **Stable Pool Overhead**: StableSwap adds ~25-30% gas cost for improved price stability
- **NFT Positions**: Initial liquidity provision includes NFT minting (~300K gas)
- **Auto-Compound**: More efficient than separate claim + add operations (saves ~70K gas)

### Comparison with Other Protocols

| Protocol | Swap Gas | Add Liquidity | Remove Liquidity |
|----------|----------|---------------|------------------|
| **Sui AMM** | 295,000 | 485,000 | 380,000 |
| Uniswap V2 (EVM) | ~110,000 | ~180,000 | ~150,000 |
| Curve (EVM) | ~150,000 | ~220,000 | ~180,000 |
| Uniswap V3 (EVM) | ~130,000 | ~250,000 | ~200,000 |

> **Note**: Direct comparison with EVM protocols is approximate. Sui's object-based model and Move VM have different gas accounting than EVM. Sui gas units are not directly comparable to Ethereum gas units.

### Running Benchmarks

```bash
# Run gas profiling tests
sui move test benchmark --gas-limit 100000000000

# Generate report
./scripts/generate_gas_report.sh

# View detailed report
cat docs/GAS_BENCHMARKS.md
```

**Full Report**: See [docs/GAS_BENCHMARKS.md](docs/GAS_BENCHMARKS.md) for detailed analysis, methodology, and optimization recommendations.

---

## Security

### Audited Vulnerabilities Fixed

1. **LP Minting Precision** - Uses u128 arithmetic to prevent dust loss
2. **Fee Debt Tracking** - Prevents double-claiming exploits
3. **Minimum Liquidity** - Burns 1,000 shares to prevent manipulation
4. **DoS Protection** - Pool creation fees and registry limits
5. **Overflow Protection** - Checked arithmetic in all calculations
6. **Governance Timelock** - 24-hour delay for critical changes
7. **Il Calculation** - Increased precision from 1e9 to 1e12

### Best Practices

- **No Flash Loan Attacks** - Minimum liquidity permanently locked
- **Reentrancy Safe** - Fee debt accounting prevents exploits
- **Price Manipulation** - Large liquidity requirements
- **Front-Running** - Deadline and slippage protection
- **Admin Controls** - Timelock for all parameter changes

### Constants & Limits

| Parameter | Value | Purpose |
|-----------|-------|---------|
| Minimum Liquidity | 1,000 shares | Prevents manipulation |
| Pool Creation Fee | 10 SUI | DoS protection |
| Max Pools Per Token | 500 | Registry DoS prevention |
| Max Global Pools | 50,000 | Scalability limit |
| Ratio Tolerance | 0.5% | Liquidity add flexibility |
| Max Price Impact | 10% | Default slippage cap |
| Min Fee Tier | 0.01% | Minimum LP incentive |
| Governance Timelock | 24 hours | Change safety delay |
| Proposal Expiry | 7 days | Governance cleanup |

---

## Mathematical Correctness

### Constant Product Formula

```
x * y = k

amount_out = (amount_in * fee_multiplier * reserve_out) / (reserve_in + amount_in * fee_multiplier)

fee_multiplier = 1 - (fee_bps / 10000)
```

### StableSwap Invariant

```
D = get_d(x, y, amp)

where D satisfies:
A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
```

### Fee Distribution

```
acc_fee_per_share += (fee_amount * ACC_PRECISION) / total_liquidity

pending_fee = (liquidity * acc_fee_per_share / ACC_PRECISION) - fee_debt
```

### Impermanent Loss

```
IL% = ((current_price_ratio - entry_price_ratio) / entry_price_ratio) * 10000

Precision: 1e12 (0.0001% accuracy)
```

---

## Gas Optimization

### Optimizations Implemented

1. **Batch Operations** - Combine multiple actions in single transaction
2. **Efficient Storage** - Minimal on-chain data
3. **U128 Arithmetic** - Only when necessary for precision
4. **Event Pruning** - Essential data only
5. **Table Indexing** - Fast lookups without iteration

### Typical Gas Costs

| Operation | Estimated Gas |
|-----------|--------------|
| Create Pool | ~2M gas |
| Add Liquidity | ~500K gas |
| Remove Liquidity | ~400K gas |
| Swap | ~300K gas |
| Claim Fees | ~200K gas |
| Compound Fees | ~600K gas |

*Note: Actual costs vary based on pool state and transaction complexity*

---

## Advanced Features

### Dynamic NFT Metadata

LP Position NFTs automatically update their displayed information:
- Current position value in both tokens
- Accumulated fees ready to claim
- Real-time impermanent loss percentage
- Beautiful SVG rendering with gradients
- Color-coded IL (green=profit, yellow=minor loss, red=significant loss)

### Statistics Tracking

The protocol tracks comprehensive analytics:
- Total volume per pool
- Swap count and timestamps
- Liquidity depth over time
- Fee generation rates
- Price history

### User Preferences

Users can configure:
- Default slippage tolerance
- Deadline preferences
- Auto-compound settings
- Notification preferences

---

## Development Roadmap

### Completed
- ✅ Core AMM with x*y=k formula
- ✅ StableSwap pools
- ✅ NFT LP positions with SVG
- ✅ Fee auto-compounding
- ✅ Limit orders
- ✅ Governance with timelocks
- ✅ Comprehensive test suite (>80% coverage)
- ✅ Security audit fixes
- ✅ Gas optimizations