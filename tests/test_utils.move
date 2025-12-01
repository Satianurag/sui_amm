#[test_only]
module sui_amm::test_utils {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self as ts};

    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self, LPPosition};
    
    // ═══════════════════════════════════════════════════════════════════════════
    // TEST TOKEN TYPES
    // ═══════════════════════════════════════════════════════════════════════════
    
    public struct USDC has drop {}
    public struct USDT has drop {}
    public struct DAI has drop {}
    public struct BTC has drop {}
    public struct ETH has drop {}
    public struct SUI has drop {}
    public struct WETH has drop {}
    
    // Test address constants
    const ADMIN: address = @0xAD;
    const USER_A: address = @0xA;
    const USER_B: address = @0xB;
    const USER_C: address = @0xC;
    
    // Test amount constants
    const INITIAL_BALANCE: u64 = 1_000_000_000_000; // 1000 tokens with 9 decimals
    const SMALL_AMOUNT: u64 = 1_000;
    const LARGE_AMOUNT: u64 = 1_000_000_000_000_000; // 1M tokens
    
    // Test fee tier constants (in basis points)
    const FEE_LOW: u64 = 5;      // 0.05%
    const FEE_MEDIUM: u64 = 30;  // 0.30%
    const FEE_HIGH: u64 = 100;   // 1.00%
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SNAPSHOT STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    public struct PoolSnapshot has copy, drop, store {
        reserve_a: u64,
        reserve_b: u64,
        total_liquidity: u64,
        fee_a: u64,
        fee_b: u64,
        protocol_fee_a: u64,
        protocol_fee_b: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
        k_invariant: u128,
        timestamp_ms: u64,
    }
    
    public struct StablePoolSnapshot has copy, drop, store {
        reserve_a: u64,
        reserve_b: u64,
        total_liquidity: u64,
        d_invariant: u64,
        current_amp: u64,
        timestamp_ms: u64,
    }
    
    public struct PositionSnapshot has copy, drop, store {
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        cached_value_a: u64,
        cached_value_b: u64,
        pending_fee_a: u64,
        pending_fee_b: u64,
    }
    
    // Getter functions for test addresses
    public fun admin(): address { ADMIN }
    public fun user_a(): address { USER_A }
    public fun user_b(): address { USER_B }
    public fun user_c(): address { USER_C }
    
    // Getter functions for test amounts
    public fun initial_balance(): u64 { INITIAL_BALANCE }
    public fun small_amount(): u64 { SMALL_AMOUNT }
    public fun large_amount(): u64 { LARGE_AMOUNT }
    
    // Getter functions for test fee tiers
    public fun fee_low(): u64 { FEE_LOW }
    public fun fee_medium(): u64 { FEE_MEDIUM }
    public fun fee_high(): u64 { FEE_HIGH }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // COIN MINTING HELPERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    public fun mint_coin<T: drop>(amount: u64, ctx: &mut TxContext): Coin<T> {
        coin::mint_for_testing<T>(amount, ctx)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CLOCK UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════
    
    public fun advance_clock(clock: &mut Clock, delta_ms: u64) {
        clock::increment_for_testing(clock, delta_ms);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SNAPSHOT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    public fun snapshot_stable_pool<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        clock: &Clock
    ): StablePoolSnapshot {
        let (reserve_a, reserve_b) = stable_pool::get_reserves(pool);
        StablePoolSnapshot {
            reserve_a,
            reserve_b,
            total_liquidity: stable_pool::get_total_liquidity(pool),
            d_invariant: stable_pool::get_d(pool),
            current_amp: stable_pool::get_current_amp(pool, clock),
            timestamp_ms: clock::timestamp_ms(clock),
        }
    }
    
    public fun snapshot_pool<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        clock: &Clock
    ): PoolSnapshot {
        let (reserve_a, reserve_b) = pool::get_reserves(pool);
        let (fee_a, fee_b) = pool::get_fees(pool);
        let (protocol_fee_a, protocol_fee_b) = pool::get_protocol_fees(pool);
        let (acc_fee_per_share_a, acc_fee_per_share_b) = pool::get_acc_fee_per_share(pool);
        PoolSnapshot {
            reserve_a,
            reserve_b,
            total_liquidity: pool::get_total_liquidity(pool),
            fee_a,
            fee_b,
            protocol_fee_a,
            protocol_fee_b,
            acc_fee_per_share_a,
            acc_fee_per_share_b,
            k_invariant: pool::get_k(pool),
            timestamp_ms: clock::timestamp_ms(clock),
        }
    }
    
    public fun snapshot_position(position: &LPPosition): PositionSnapshot {
        PositionSnapshot {
            liquidity: position::liquidity(position),
            fee_debt_a: position::fee_debt_a(position),
            fee_debt_b: position::fee_debt_b(position),
            cached_value_a: position::cached_value_a(position),
            cached_value_b: position::cached_value_b(position),
            pending_fee_a: 0, // Will be calculated separately
            pending_fee_b: 0,
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SNAPSHOT GETTERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    // Pool snapshot getters
    public fun get_snapshot_reserves(snapshot: &PoolSnapshot): (u64, u64) {
        (snapshot.reserve_a, snapshot.reserve_b)
    }
    
    public fun get_snapshot_liquidity(snapshot: &PoolSnapshot): u64 {
        snapshot.total_liquidity
    }
    
    public fun get_snapshot_fees(snapshot: &PoolSnapshot): (u64, u64) {
        (snapshot.fee_a, snapshot.fee_b)
    }
    
    public fun get_snapshot_protocol_fees(snapshot: &PoolSnapshot): (u64, u64) {
        (snapshot.protocol_fee_a, snapshot.protocol_fee_b)
    }
    
    public fun get_snapshot_acc_fees(snapshot: &PoolSnapshot): (u128, u128) {
        (snapshot.acc_fee_per_share_a, snapshot.acc_fee_per_share_b)
    }
    
    public fun get_snapshot_k(snapshot: &PoolSnapshot): u128 {
        snapshot.k_invariant
    }
    
    // Stable pool snapshot getters
    public fun get_stable_snapshot_reserves(snapshot: &StablePoolSnapshot): (u64, u64) {
        (snapshot.reserve_a, snapshot.reserve_b)
    }
    
    public fun get_stable_snapshot_d(snapshot: &StablePoolSnapshot): u64 {
        snapshot.d_invariant
    }
    
    public fun get_stable_snapshot_amp(snapshot: &StablePoolSnapshot): u64 {
        snapshot.current_amp
    }
    
    public fun get_stable_snapshot_liquidity(snapshot: &StablePoolSnapshot): u64 {
        snapshot.total_liquidity
    }
    
    // Position snapshot getters
    public fun get_position_snapshot_liquidity(snapshot: &PositionSnapshot): u64 {
        snapshot.liquidity
    }
    
    public fun get_position_snapshot_fee_debts(snapshot: &PositionSnapshot): (u128, u128) {
        (snapshot.fee_debt_a, snapshot.fee_debt_b)
    }
    
    public fun get_position_snapshot_cached_values(snapshot: &PositionSnapshot): (u64, u64) {
        (snapshot.cached_value_a, snapshot.cached_value_b)
    }
    
    public fun get_position_snapshot_pending_fees(snapshot: &PositionSnapshot): (u64, u64) {
        (snapshot.pending_fee_a, snapshot.pending_fee_b)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RANDOM NUMBER GENERATION
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Linear congruential generator for deterministic pseudo-random numbers
    public fun lcg_random(seed: u64, iteration: u64): u64 {
        let a: u128 = 6364136223846793005;
        let c: u128 = 1442695040888963407;
        let m: u128 = 18446744073709551616; // 2^64
        (((seed as u128) * a + c + (iteration as u128)) % m) as u64
    }
    
    /// Generate random amount within safe bounds
    public fun random_amount(seed: u64, iteration: u64, max: u64): u64 {
        if (max == 0) return 1;
        (lcg_random(seed, iteration) % max) + 1
    }
    
    /// Generate random swap that won't exceed price impact limits
    public fun random_safe_swap_amount(seed: u64, iteration: u64, reserve: u64): u64 {
        let max_swap = reserve / 20; // Max 5% of reserve
        if (max_swap == 0) return 1;
        random_amount(seed, iteration, max_swap)
    }
    
    /// Generate random liquidity amounts
    public fun random_liquidity_amounts(seed: u64, iteration: u64, max: u64): (u64, u64) {
        let amount_a = random_amount(seed, iteration, max);
        let amount_b = random_amount(seed, iteration + 1, max);
        (amount_a, amount_b)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // TIME UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Far future deadline (u64::MAX)
    public fun far_future(): u64 { 18446744073709551615 }
    
    /// Create clock at specific timestamp
    public fun create_clock_at(timestamp_ms: u64, ctx: &mut TxContext): Clock {
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, timestamp_ms);
        clock
    }
    
    /// Set clock to specific timestamp
    public fun set_clock_to(clock: &mut Clock, timestamp_ms: u64) {
        clock::set_for_testing(clock, timestamp_ms);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // K-INVARIANT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Get K invariant from pool snapshot
    public fun get_k_invariant(snapshot: &PoolSnapshot): u128 {
        snapshot.k_invariant
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // POOL CREATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Create initialized pool with initial liquidity
    public fun create_initialized_pool<CoinA: drop, CoinB: drop>(
        fee_bps: u64,
        protocol_fee_bps: u64,
        creator_fee_bps: u64,
        initial_a: u64,
        initial_b: u64,
        _creator: address,
        ctx: &mut TxContext
    ): (object::ID, LPPosition) {
        let clock = clock::create_for_testing(ctx);
        let mut pool = pool::create_pool_for_testing<CoinA, CoinB>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            ctx
        );
        
        let coin_a = mint_coin<CoinA>(initial_a, ctx);
        let coin_b = mint_coin<CoinB>(initial_b, ctx);
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            far_future(),
            ctx
        );
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        let pool_id = object::id(&pool);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        
        (pool_id, position)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY HELPERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Add liquidity helper
    public fun add_liquidity_helper<CoinA: drop, CoinB: drop>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        amount_a: u64,
        amount_b: u64,
        _min_liquidity: u64,
        _min_a: u64,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): LPPosition {
        let coin_a = mint_coin<CoinA>(amount_a, ctx);
        let coin_b = mint_coin<CoinB>(amount_b, ctx);
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
            pool,
            coin_a,
            coin_b,
            1,
            clock,
            deadline,
            ctx
        );
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        position
    }

    /// Create initialized stable pool helper
    public fun create_initialized_stable_pool<CoinA: drop, CoinB: drop>(
        amp: u64,
        fee_bps: u64,
        protocol_fee_bps: u64,
        creator_fee_bps: u64,
        initial_a: u64,
        initial_b: u64,
        _owner: address,
        ctx: &mut TxContext
    ): (object::ID, LPPosition) {
        let clock = clock::create_for_testing(ctx);
        
        let mut pool = sui_amm::stable_pool::create_pool<CoinA, CoinB>(
            amp,
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            ctx
        );
        
        let pool_id = object::id(&pool);
        
        let coin_a = mint_coin<CoinA>(initial_a, ctx);
        let coin_b = mint_coin<CoinB>(initial_b, ctx);
        
        let (position, refund_a, refund_b) = sui_amm::stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            far_future(),
            ctx
        );
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        clock::destroy_for_testing(clock);
        
        ts::return_shared(pool);
        
        (pool_id, position)
    }
    
    /// Remove liquidity helper (partial removal)
    public fun remove_liquidity_helper<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        amount: u64,
        _min_a: u64,
        _min_b: u64,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        pool::remove_liquidity_partial(
            pool,
            position,
            amount,
            1,
            1,
            clock,
            deadline,
            ctx
        )
    }
    
    /// Remove liquidity full helper
    public fun remove_liquidity_full_helper<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: LPPosition,
        _min_a: u64,
        _min_b: u64,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        pool::remove_liquidity(
            pool,
            position,
            1,
            1,
            clock,
            deadline,
            ctx
        )
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP HELPERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Swap A to B helper
    public fun swap_a_to_b_helper<CoinA: drop, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
        min_out: u64,
        _max_price: u64,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<CoinB> {
        let coin_in = mint_coin<CoinA>(amount_in, ctx);
        let max_price_val = if (_max_price > 0) { _max_price } else { 18446744073709551615 };
        pool::swap_a_to_b(
            pool,
            coin_in,
            min_out,
            option::some(max_price_val),
            clock,
            deadline,
            ctx
        )
    }
    
    /// Swap B to A helper
    public fun swap_b_to_a_helper<CoinA, CoinB: drop>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
        min_out: u64,
        _max_price: u64,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<CoinA> {
        let coin_in = mint_coin<CoinB>(amount_in, ctx);
        let max_price_val = if (_max_price > 0) { _max_price } else { 18446744073709551615 };
        pool::swap_b_to_a(
            pool,
            coin_in,
            min_out,
            option::some(max_price_val),
            clock,
            deadline,
            ctx
        )
    }

}