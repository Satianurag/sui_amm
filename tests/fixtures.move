/// Test fixtures module providing standardized test data configurations
/// Includes fee tiers, liquidity scenarios, user addresses, time constants,
/// and tolerance values for consistent testing across the AMM test suite
#[test_only]
module sui_amm::fixtures {
    // ═══════════════════════════════════════════════════════════════════════════
    // FEE TIER CONFIGURATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Ultra-low fee tier (0.05%) for stable pairs with high volume
    /// Returns (fee_bps, protocol_fee_bps, creator_fee_bps)
    /// Used for stablecoin pairs where tight spreads are expected
    public fun ultra_low_fee_config(): (u64, u64, u64) {
        (5, 100, 0) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// Standard fee tier (0.30%) for most regular trading pairs
    /// Returns (fee_bps, protocol_fee_bps, creator_fee_bps)
    /// Default configuration for typical token pairs
    public fun standard_fee_config(): (u64, u64, u64) {
        (30, 100, 0) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// High-volatility fee tier (1.00%) for exotic or volatile pairs
    /// Returns (fee_bps, protocol_fee_bps, creator_fee_bps)
    /// Includes creator fee to compensate for higher risk
    public fun high_volatility_fee_config(): (u64, u64, u64) {
        (100, 100, 50) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// Institutional fee tier (0.01%) for large institutional trades
    /// Returns (fee_bps, protocol_fee_bps, creator_fee_bps)
    /// Minimal fees for high-volume professional traders
    public fun institutional_fee_config(): (u64, u64, u64) {
        (1, 100, 0) // fee_bps, protocol_fee_bps, creator_fee_bps
    }
    
    /// Creator fee pool configuration (0.30% swap + 0.50% creator fee)
    /// Returns (fee_bps, protocol_fee_bps, creator_fee_bps)
    /// Used to test creator fee distribution mechanics
    public fun creator_fee_config(): (u64, u64, u64) {
        (30, 100, 500) // fee_bps, protocol_fee_bps, creator_fee_bps (max 5%)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY SCENARIOS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Whale liquidity (1 trillion tokens each) for large institutional LP testing
    /// Returns (amount_a, amount_b) representing massive liquidity provision
    /// Used to test pool behavior with very large reserves
    public fun whale_liquidity(): (u64, u64) {
        (1_000_000_000_000, 1_000_000_000_000) // 1 trillion each
    }
    
    /// Standard retail liquidity (1 billion tokens each) for typical LP testing
    /// Returns (amount_a, amount_b) representing normal user liquidity provision
    /// Most common scenario for regular pool operations
    public fun retail_liquidity(): (u64, u64) {
        (1_000_000_000, 1_000_000_000) // 1 billion each
    }
    
    /// Micro liquidity (10 million tokens each) for small retail LP testing
    /// Returns (amount_a, amount_b) representing minimal viable liquidity
    /// Used to test pool behavior with small reserves
    public fun micro_liquidity(): (u64, u64) {
        (10_000_000, 10_000_000) // 10 million each
    }
    
    /// Minimum viable liquidity just above MINIMUM_LIQUIDITY threshold
    /// Returns (amount_a, amount_b) at the lower bound of acceptable liquidity
    /// Used to test edge cases near minimum liquidity requirements
    public fun minimum_liquidity(): (u64, u64) {
        (10_000, 10_000) // 10K each (MINIMUM_LIQUIDITY = 1000)
    }
    
    /// Extreme price imbalance (1:1000 ratio) for edge case testing
    /// Returns (amount_a, amount_b) with severe imbalance
    /// Tests pool behavior under extreme price conditions
    public fun extreme_imbalance_liquidity(): (u64, u64) {
        (10_000_000_000, 10_000_000) // 10B : 10M (1000:1 ratio)
    }
    
    /// Balanced large liquidity (100 billion each) for stress testing
    /// Returns (amount_a, amount_b) with high balanced reserves
    /// Used to verify pool handles large balanced operations correctly
    public fun balanced_large_liquidity(): (u64, u64) {
        (100_000_000_000, 100_000_000_000) // 100 billion each
    }
    
    /// Moderate imbalance with 10:1 ratio
    /// Returns (amount_a, amount_b) with token A having 10x more liquidity
    /// Tests pool behavior with moderate price skew
    public fun imbalanced_10_to_1(): (u64, u64) {
        (10_000_000_000, 1_000_000_000) // 10B : 1B
    }
    
    /// Moderate imbalance with 1:10 ratio
    /// Returns (amount_a, amount_b) with token B having 10x more liquidity
    /// Tests pool behavior with opposite price skew
    public fun imbalanced_1_to_10(): (u64, u64) {
        (1_000_000_000, 10_000_000_000) // 1B : 10B
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STABLESWAP CONFIGURATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Conservative StableSwap with low amplification (amp=10)
    /// Returns (fee_bps, amp) with curve closer to constant product
    /// Used for loosely pegged assets or testing transition behavior
    public fun conservative_stable_config(): (u64, u64) {
        (5, 10) // fee_bps, amp
    }
    
    /// Balanced StableSwap with medium amplification (amp=100)
    /// Returns (fee_bps, amp) for standard stablecoin pairs
    /// Default configuration for typical stable pair testing
    public fun balanced_stable_config(): (u64, u64) {
        (5, 100) // fee_bps, amp
    }
    
    /// Aggressive StableSwap with high amplification (amp=500)
    /// Returns (fee_bps, amp) for very flat curve near 1:1 peg
    /// Used for tightly pegged assets like wrapped tokens
    public fun aggressive_stable_config(): (u64, u64) {
        (5, 500) // fee_bps, amp
    }
    
    /// Maximum StableSwap amplification (amp=1000) for upper bound testing
    /// Returns (fee_bps, amp) at maximum allowed amplification
    /// Tests extreme flat curve behavior and numerical stability
    public fun max_stable_config(): (u64, u64) {
        (5, 1000) // fee_bps, amp (MAX_AMP = 1000)
    }
    
    /// Minimum StableSwap amplification (amp=1) for lower bound testing
    /// Returns (fee_bps, amp) at minimum allowed amplification
    /// Effectively behaves like constant product pool
    public fun min_stable_config(): (u64, u64) {
        (5, 1) // fee_bps, amp (MIN_AMP = 1)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST USER ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Protocol administrator address for governance and admin operations
    public fun admin(): address { @0x1 }
    
    /// Large institutional liquidity provider address for whale scenarios
    public fun whale(): address { @0x100 }
    
    /// Regular retail user address for typical trading scenarios
    public fun retail(): address { @0x101 }
    
    /// Arbitrageur address for MEV and arbitrage testing scenarios
    public fun arbitrageur(): address { @0x102 }
    
    /// Dedicated liquidity provider address for LP-specific tests
    public fun lp(): address { @0x103 }
    
    /// MEV searcher address for front-running and sandwich attack tests
    public fun mev_searcher(): address { @0x104 }
    
    /// Generic test user 1 for multi-user interaction tests
    public fun user1(): address { @0x105 }
    
    /// Generic test user 2 for multi-user interaction tests
    public fun user2(): address { @0x106 }
    
    /// Generic test user 3 for multi-user interaction tests
    public fun user3(): address { @0x107 }
    
    /// Pool creator address for testing creator fee distribution
    public fun creator(): address { @0x108 }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIME CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// One second in milliseconds for time-based calculations
    public fun second(): u64 { 1_000 }
    
    /// One minute in milliseconds for time-based calculations
    public fun minute(): u64 { 60_000 }
    
    /// One hour in milliseconds for deadline and timelock tests
    public fun hour(): u64 { 3_600_000 }
    
    /// One day in milliseconds for multi-day scenario tests
    public fun day(): u64 { 86_400_000 }
    
    /// One week in milliseconds for long-term scenario tests
    public fun week(): u64 { 604_800_000 }
    
    /// Governance timelock duration (48 hours) for proposal execution delay
    /// Ensures sufficient time for community review before changes take effect
    public fun governance_timelock(): u64 { 172_800_000 }
    
    /// Proposal expiry duration (7 days) for voting window
    /// Proposals must be executed within this timeframe after passing
    public fun proposal_expiry(): u64 { 604_800_000 }
    
    /// Maximum u64 value for deadlines that should never expire
    /// Used to bypass deadline checks when testing other functionality
    public fun far_future_deadline(): u64 { 18446744073709551615 }
    
    /// Calculate deadline 1 hour in the future from current time
    /// Used for testing normal deadline scenarios
    public fun near_future_deadline(current_time: u64): u64 {
        current_time + hour()
    }
    
    /// Calculate deadline 1 hour in the past from current time
    /// Used for testing expired deadline error handling
    /// Returns 0 if current_time is less than 1 hour to avoid underflow
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
    
    /// Tiny swap (0.01% of 1B reserve) for minimal price impact testing
    public fun tiny_swap(): u64 { 100_000 }
    
    /// Small swap (0.1% of 1B reserve) for low price impact testing
    public fun small_swap(): u64 { 1_000_000 }
    
    /// Medium swap (1% of 1B reserve) for moderate price impact testing
    public fun medium_swap(): u64 { 10_000_000 }
    
    /// Large swap (5% of 1B reserve) for significant price impact testing
    public fun large_swap(): u64 { 50_000_000 }
    
    /// Huge swap (10% of 1B reserve) near price impact limits
    /// Tests pool behavior under extreme swap conditions
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
    public fun minimum_liquidity_amount(): u64 { 1_000 }
    
    /// Minimum compound amount threshold
    public fun min_compound_amount(): u64 { 1_000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE VALUES - For assertion comparisons
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Tight tolerance (1 unit) for exact calculations with minimal rounding
    /// Used when precision is critical and rounding errors should be negligible
    public fun tight_tolerance(): u64 { 1 }
    
    /// Standard tolerance (10 units) for most calculations with normal rounding
    /// Default tolerance for typical arithmetic operations
    public fun standard_tolerance(): u64 { 10 }
    
    /// Relaxed tolerance (100 units) for complex multi-step calculations
    /// Used when multiple operations accumulate rounding errors
    public fun relaxed_tolerance(): u64 { 100 }
    
    /// Loose tolerance (1000 units) for very complex calculations
    /// Used for operations with significant accumulated rounding or approximations
    public fun loose_tolerance(): u64 { 1_000 }
    
    /// Tight tolerance for u128 calculations with minimal rounding
    public fun tight_tolerance_u128(): u128 { 1 }
    
    /// Standard tolerance for u128 calculations with normal rounding
    public fun standard_tolerance_u128(): u128 { 10 }
    
    /// Relaxed tolerance for u128 complex calculations
    public fun relaxed_tolerance_u128(): u128 { 100 }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST PARAMETERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Number of iterations for property-based tests
    /// Each property test runs this many times with different random inputs
    public fun property_test_iterations(): u64 { 1 }
    
    /// Default seed for deterministic random number generation
    /// Ensures reproducible test results across runs
    public fun default_random_seed(): u64 { 12345 }
    
    /// Alternative seed for testing different random sequences
    /// Used to verify properties hold across multiple random distributions
    public fun alt_random_seed(): u64 { 67890 }
    
    /// Maximum random amount (1 billion) for property test value generation
    /// Keeps test values within reasonable bounds while covering wide range
    public fun max_random_amount(): u64 { 1_000_000_000 }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE VALUES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Near u64 maximum value (u64::MAX / 1000) safe for multiplication
    /// Used to test overflow protection without triggering actual overflow
    public fun near_u64_max(): u64 { 18446744073709551 } // u64::MAX / 1000
    
    /// Dust amount (1 unit) representing minimal meaningful value
    /// Used to test handling of very small amounts
    public fun dust_amount(): u64 { 1 }
    
    /// Zero amount for testing error handling of invalid inputs
    /// Most operations should reject zero amounts
    public fun zero_amount(): u64 { 0 }
}
