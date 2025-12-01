#[test_only]
module sui_amm::fixtures {
    // ═══════════════════════════════════════════════════════════════════════════
    // FEE TIER CONFIGURATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Ultra-low fee tier (0.05%) - For stable pairs with high volume
    public fun ultra_low_fee_config(): (u64, u64, u64) {
        (5, 100, 0) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// Standard fee tier (0.30%) - Most common for regular pairs
    public fun standard_fee_config(): (u64, u64, u64) {
        (30, 100, 0) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// High-volatility fee tier (1.00%) - For exotic/volatile pairs
    public fun high_volatility_fee_config(): (u64, u64, u64) {
        (100, 100, 50) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// Institutional fee tier (0.01%) - For large institutional trades
    public fun institutional_fee_config(): (u64, u64, u64) {
        (1, 100, 0) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// Creator fee pool configuration (0.30% + 0.50% creator)
    public fun creator_fee_config(): (u64, u64, u64) {
        (30, 100, 500) // fee_bps, protocol_fee_bps, creator_fee_bps (max 5%)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY SCENARIOS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Whale liquidity (1B tokens each) - Large institutional LP
    public fun whale_liquidity(): (u64, u64) {
        (1_000_000_000_000, 1_000_000_000_000) // 1 trillion each
    }
    
    /// Standard liquidity (1M tokens each) - Typical retail LP
    public fun retail_liquidity(): (u64, u64) {
        (1_000_000_000, 1_000_000_000) // 1 billion each
    }
    
    /// Micro liquidity (10K tokens each) - Small retail LP
    public fun micro_liquidity(): (u64, u64) {
        (10_000_000, 10_000_000) // 10 million each
    }
    
    /// Minimum liquidity (just above MINIMUM_LIQUIDITY threshold)
    public fun minimum_liquidity(): (u64, u64) {
        (10_000, 10_000) // 10K each (MINIMUM_LIQUIDITY = 1000)
    }
    
    /// Extreme imbalance (1:1000 ratio) - Testing edge cases
    public fun extreme_imbalance_liquidity(): (u64, u64) {
        (10_000_000_000, 10_000_000) // 10B : 10M (1000:1 ratio)
    }
    
    /// Balanced large liquidity (100M each) - For stress testing
    public fun balanced_large_liquidity(): (u64, u64) {
        (100_000_000_000, 100_000_000_000) // 100 billion each
    }
    
    /// Imbalanced 10:1 ratio
    public fun imbalanced_10_to_1(): (u64, u64) {
        (10_000_000_000, 1_000_000_000) // 10B : 1B
    }
    
    /// Imbalanced 1:10 ratio
    public fun imbalanced_1_to_10(): (u64, u64) {
        (1_000_000_000, 10_000_000_000) // 1B : 10B
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STABLESWAP CONFIGURATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Conservative StableSwap (low amp) - More like constant product
    public fun conservative_stable_config(): (u64, u64) {
        (5, 10) // fee_bps, amp
    }
    
    /// Balanced StableSwap (medium amp) - Standard stable pair
    public fun balanced_stable_config(): (u64, u64) {
        (5, 100) // fee_bps, amp
    }
    
    /// Aggressive StableSwap (high amp) - Very flat curve for tight pegs
    public fun aggressive_stable_config(): (u64, u64) {
        (5, 500) // fee_bps, amp
    }
    
    /// Maximum StableSwap (max amp) - Testing upper bounds
    public fun max_stable_config(): (u64, u64) {
        (5, 1000) // fee_bps, amp (MAX_AMP = 1000)
    }
    
    /// Minimum StableSwap (min amp) - Testing lower bounds
    public fun min_stable_config(): (u64, u64) {
        (5, 1) // fee_bps, amp (MIN_AMP = 1)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST USER ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Admin address - Protocol administrator
    public fun admin(): address { @0x1 }
    
    /// Whale address - Large liquidity provider
    public fun whale(): address { @0xWHALE }
    
    /// Retail address - Regular user/trader
    public fun retail(): address { @0xRETAIL }
    
    /// Arbitrageur address - MEV searcher/arbitrage bot
    public fun arbitrageur(): address { @0xARB }
    
    /// LP address - Dedicated liquidity provider
    public fun lp(): address { @0xLP }
    
    /// MEV searcher address - Front-running bot
    public fun mev_searcher(): address { @0xMEV }
    
    /// User1 - Generic test user 1
    public fun user1(): address { @0xUSER1 }
    
    /// User2 - Generic test user 2
    public fun user2(): address { @0xUSER2 }
    
    /// User3 - Generic test user 3
    public fun user3(): address { @0xUSER3 }
    
    /// Creator - Pool creator for creator fee tests
    public fun creator(): address { @0xCREATOR }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIME CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// One second in milliseconds
    public fun second(): u64 { 1_000 }
    
    /// One minute in milliseconds
    public fun minute(): u64 { 60_000 }
    
    /// One hour in milliseconds
    public fun hour(): u64 { 3_600_000 }
    
    /// One day in milliseconds
    public fun day(): u64 { 86_400_000 }
    
    /// One week in milliseconds
    public fun week(): u64 { 604_800_000 }
    
    /// Governance timelock duration (48 hours)
    public fun governance_timelock(): u64 { 172_800_000 }
    
    /// Proposal expiry duration (7 days)
    public fun proposal_expiry(): u64 { 604_800_000 }
    
    /// Far future deadline (u64::MAX)
    public fun far_future_deadline(): u64 { 18446744073709551615 }
    
    /// Near future deadline (1 hour from now)
    public fun near_future_deadline(current_time: u64): u64 {
        current_time + hour()
    }
    
    /// Past deadline (1 hour ago)
    public fun past_deadline(current_time: u64): u64 {
        if (current_time > hour()) {
            current_time - hour()
        } else {
            0
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GAS BENCHMARK TARGETS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Target gas for single swap operation
    public fun target_gas_swap(): u64 { 100_000 }
    
    /// Target gas for add liquidity (with NFT mint)
    public fun target_gas_add_liquidity(): u64 { 150_000 }
    
    /// Target gas for remove liquidity (with NFT burn)
    public fun target_gas_remove_liquidity(): u64 { 120_000 }
    
    /// Target gas for claim fees
    public fun target_gas_claim_fees(): u64 { 80_000 }
    
    /// Target gas for compound fees (claim + add liquidity)
    public fun target_gas_compound_fees(): u64 { 200_000 }
    
    /// Target gas for pool creation
    public fun target_gas_create_pool(): u64 { 100_000 }
    
    /// Target gas for governance proposal creation
    public fun target_gas_create_proposal(): u64 { 50_000 }
    
    /// Target gas for governance proposal execution
    public fun target_gas_execute_proposal(): u64 { 80_000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP AMOUNTS - Common test swap sizes
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Tiny swap (0.01% of 1B reserve)
    public fun tiny_swap(): u64 { 100_000 }
    
    /// Small swap (0.1% of 1B reserve)
    public fun small_swap(): u64 { 1_000_000 }
    
    /// Medium swap (1% of 1B reserve)
    public fun medium_swap(): u64 { 10_000_000 }
    
    /// Large swap (5% of 1B reserve)
    public fun large_swap(): u64 { 50_000_000 }
    
    /// Huge swap (10% of 1B reserve) - Near price impact limit
    public fun huge_swap(): u64 { 100_000_000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // SLIPPAGE TOLERANCES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Tight slippage tolerance (0.1%)
    public fun tight_slippage_bps(): u64 { 10 }
    
    /// Standard slippage tolerance (0.5%)
    public fun standard_slippage_bps(): u64 { 50 }
    
    /// Relaxed slippage tolerance (1%)
    public fun relaxed_slippage_bps(): u64 { 100 }
    
    /// High slippage tolerance (5%) - Default for regular pools
    public fun high_slippage_bps(): u64 { 500 }
    
    /// Stable pool slippage tolerance (2%) - Default for stable pools
    public fun stable_slippage_bps(): u64 { 200 }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE IMPACT LIMITS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Low price impact limit (1%)
    public fun low_price_impact_bps(): u64 { 100 }
    
    /// Medium price impact limit (5%)
    public fun medium_price_impact_bps(): u64 { 500 }
    
    /// High price impact limit (10%) - Default maximum
    public fun high_price_impact_bps(): u64 { 1000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRECISION CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Accumulator precision (1e12)
    public fun acc_precision(): u128 { 1_000_000_000_000 }
    
    /// Basis points denominator (10000)
    public fun bps_denominator(): u64 { 10_000 }
    
    /// Minimum liquidity burned on first deposit
    public fun minimum_liquidity(): u64 { 1_000 }
    
    /// Minimum compound amount threshold
    public fun min_compound_amount(): u64 { 1_000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE VALUES - For assertion comparisons
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Tight tolerance (1 unit) - For exact calculations
    public fun tight_tolerance(): u64 { 1 }
    
    /// Standard tolerance (10 units) - For most calculations
    public fun standard_tolerance(): u64 { 10 }
    
    /// Relaxed tolerance (100 units) - For complex calculations
    public fun relaxed_tolerance(): u64 { 100 }
    
    /// Loose tolerance (1000 units) - For very complex calculations
    public fun loose_tolerance(): u64 { 1_000 }
    
    /// Tight tolerance u128 (1 unit)
    public fun tight_tolerance_u128(): u128 { 1 }
    
    /// Standard tolerance u128 (10 units)
    public fun standard_tolerance_u128(): u128 { 10 }
    
    /// Relaxed tolerance u128 (100 units)
    public fun relaxed_tolerance_u128(): u128 { 100 }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST PARAMETERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Number of iterations for property-based tests
    public fun property_test_iterations(): u64 { 1_000 }
    
    /// Seed for random number generation
    public fun default_random_seed(): u64 { 12345 }
    
    /// Alternative seed for different test scenarios
    public fun alt_random_seed(): u64 { 67890 }
    
    /// Max random amount for property tests
    public fun max_random_amount(): u64 { 1_000_000_000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE VALUES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Near u64 max value (safe for multiplication)
    public fun near_u64_max(): u64 { 18446744073709551 } // u64::MAX / 1000
    
    /// Dust amount (minimal meaningful value)
    public fun dust_amount(): u64 { 1 }
    
    /// Zero amount (for error testing)
    public fun zero_amount(): u64 { 0 }
}
