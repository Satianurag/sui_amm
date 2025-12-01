/// Module: swap_history
/// Description: On-chain swap history tracking for users.
/// This satisfies PRD requirement: "View swap history and statistics"
module sui_amm::swap_history {
    use sui::object;
    use sui::tx_context;
    use sui::transfer;
    use sui::table;
    use sui::clock;

    // Friend declarations for pool modules to call record functions

    // Error codes
    const EUnauthorized: u64 = 1;

    // Constants
    const MAX_HISTORY_PER_USER: u64 = 100; // Keep last 100 swaps per user
    const MAX_POOL_RECENT_SWAPS: u64 = 50; // Keep last 50 swaps per pool for statistics

    /// Individual swap record
    public struct SwapRecord has store, copy, drop {
        pool_id: object::ID,
        is_a_to_b: bool,
        amount_in: u64,
        amount_out: u64,
        fee_paid: u64,
        price_impact_bps: u64,
        timestamp_ms: u64,
    }

    /// User's swap history - owned by user
    public struct UserSwapHistory has key, store {
        id: object::UID,
        owner: address,
        swaps: vector<SwapRecord>,
        total_swaps: u64,
        total_volume_in: u128,  // Cumulative input volume
        total_fees_paid: u128,  // Cumulative fees paid
    }

    /// Pool statistics - shared object per pool
    public struct PoolStatistics has key {
        id: object::UID,
        pool_id: object::ID,
        recent_swaps: vector<SwapRecord>,
        total_swaps: u64,
        total_volume_a: u128,
        total_volume_b: u128,
        total_fees_a: u128,
        total_fees_b: u128,
        // 24h rolling stats (updated on each swap)
        volume_24h_a: u64,
        volume_24h_b: u64,
        swaps_24h: u64,
        last_swap_timestamp: u64,
    }

    /// Global registry for pool statistics
    public struct StatisticsRegistry has key {
        id: object::UID,
        pool_stats: table::Table<ID, ID>, // pool_id -> PoolStatistics object ID
    }

    fun init(ctx: &mut tx_context::TxContext) {
        transfer::share_object(StatisticsRegistry {
            id: object::new(ctx),
            pool_stats: table::new(ctx),
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }

    /// Create user swap history object
    public fun create_user_history(ctx: &mut tx_context::TxContext): UserSwapHistory {
        UserSwapHistory {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            swaps: vector::empty(),
            total_swaps: 0,
            total_volume_in: 0,
            total_fees_paid: 0,
        }
    }

    /// Create and transfer user history to sender
    public fun create_and_transfer_history(ctx: &mut tx_context::TxContext) {
        let history = create_user_history(ctx);
        transfer::transfer(history, tx_context::sender(ctx));
    }

    /// Initialize pool statistics (called when pool is created)
    public fun init_pool_statistics(
        registry: &mut StatisticsRegistry,
        pool_id: object::ID,
        ctx: &mut tx_context::TxContext
    ) {
        if (table::contains(&registry.pool_stats, pool_id)) {
            return // Already initialized
        };

        let stats = PoolStatistics {
            id: object::new(ctx),
            pool_id,
            recent_swaps: vector::empty(),
            total_swaps: 0,
            total_volume_a: 0,
            total_volume_b: 0,
            total_fees_a: 0,
            total_fees_b: 0,
            volume_24h_a: 0,
            volume_24h_b: 0,
            swaps_24h: 0,
            last_swap_timestamp: 0,
        };

        let stats_id = object::id(&stats);
        table::add(&mut registry.pool_stats, pool_id, stats_id);
        transfer::share_object(stats);
    }

    /// Record a swap in user history
    public fun record_user_swap(
        history: &mut UserSwapHistory,
        pool_id: object::ID,
        is_a_to_b: bool,
        amount_in: u64,
        amount_out: u64,
        fee_paid: u64,
        price_impact_bps: u64,
        clock: &clock::Clock,
    ) {
        let record = SwapRecord {
            pool_id,
            is_a_to_b,
            amount_in,
            amount_out,
            fee_paid,
            price_impact_bps,
            timestamp_ms: clock::timestamp_ms(clock),
        };

        // Remove oldest if at capacity
        if (vector::length(&history.swaps) >= MAX_HISTORY_PER_USER) {
            vector::remove(&mut history.swaps, 0);
        };

        vector::push_back(&mut history.swaps, record);
        history.total_swaps = history.total_swaps + 1;
        history.total_volume_in = history.total_volume_in + (amount_in as u128);
        history.total_fees_paid = history.total_fees_paid + (fee_paid as u128);
    }

    /// Record a swap in pool statistics (unified function for pool integration)
    /// This is called automatically by pool swap functions
    /// Note: PoolStatistics must be passed directly as it's a shared object
    public(package) fun record_swap(
        stats: &mut PoolStatistics,
        is_a_to_b: bool,
        amount_in: u64,
        amount_out: u64,
        fee_paid: u64,
        price_impact_bps: u64,
        clock: &clock::Clock,
    ) {
        record_pool_swap(stats, is_a_to_b, amount_in, amount_out, fee_paid, price_impact_bps, clock);
    }

    /// Record a swap in pool statistics
    public fun record_pool_swap(
        stats: &mut PoolStatistics,
        is_a_to_b: bool,
        amount_in: u64,
        amount_out: u64,
        fee_paid: u64,
        price_impact_bps: u64,
        clock: &clock::Clock,
    ) {
        let timestamp = clock::timestamp_ms(clock);
        
        let record = SwapRecord {
            pool_id: stats.pool_id,
            is_a_to_b,
            amount_in,
            amount_out,
            fee_paid,
            price_impact_bps,
            timestamp_ms: timestamp,
        };

        // Remove oldest if at capacity
        if (vector::length(&stats.recent_swaps) >= MAX_POOL_RECENT_SWAPS) {
            vector::remove(&mut stats.recent_swaps, 0);
        };

        vector::push_back(&mut stats.recent_swaps, record);
        stats.total_swaps = stats.total_swaps + 1;

        // Update volume stats
        if (is_a_to_b) {
            stats.total_volume_a = stats.total_volume_a + (amount_in as u128);
            stats.total_fees_a = stats.total_fees_a + (fee_paid as u128);
        } else {
            stats.total_volume_b = stats.total_volume_b + (amount_in as u128);
            stats.total_fees_b = stats.total_fees_b + (fee_paid as u128);
        };

        // Update 24h rolling stats (simplified - reset if gap > 24h)
        let day_ms = 86_400_000u64;
        if (timestamp > stats.last_swap_timestamp + day_ms) {
            // Reset 24h stats
            stats.volume_24h_a = 0;
            stats.volume_24h_b = 0;
            stats.swaps_24h = 0;
        };

        if (is_a_to_b) {
            stats.volume_24h_a = stats.volume_24h_a + amount_in;
        } else {
            stats.volume_24h_b = stats.volume_24h_b + amount_in;
        };
        stats.swaps_24h = stats.swaps_24h + 1;
        stats.last_swap_timestamp = timestamp;
    }

    // ============ View Functions ============

    /// Get user's swap history
    public fun get_user_swaps(history: &UserSwapHistory): &vector<SwapRecord> {
        &history.swaps
    }

    /// Get user's total swap count
    public fun get_user_total_swaps(history: &UserSwapHistory): u64 {
        history.total_swaps
    }

    /// Get user's total volume
    public fun get_user_total_volume(history: &UserSwapHistory): u128 {
        history.total_volume_in
    }

    /// Get user's total fees paid
    public fun get_user_total_fees(history: &UserSwapHistory): u128 {
        history.total_fees_paid
    }

    /// Get pool's recent swaps
    public fun get_pool_recent_swaps(stats: &PoolStatistics): &vector<SwapRecord> {
        &stats.recent_swaps
    }

    /// Get pool's total swap count
    public fun get_pool_total_swaps(stats: &PoolStatistics): u64 {
        stats.total_swaps
    }

    /// Get pool's total volume (A, B)
    public fun get_pool_total_volume(stats: &PoolStatistics): (u128, u128) {
        (stats.total_volume_a, stats.total_volume_b)
    }

    /// Get pool's total fees collected (A, B)
    public fun get_pool_total_fees(stats: &PoolStatistics): (u128, u128) {
        (stats.total_fees_a, stats.total_fees_b)
    }

    /// Get pool's 24h stats
    public fun get_pool_24h_stats(stats: &PoolStatistics): (u64, u64, u64) {
        (stats.volume_24h_a, stats.volume_24h_b, stats.swaps_24h)
    }

    /// Get swap record details
    public fun get_swap_record_details(record: &SwapRecord): (ID, bool, u64, u64, u64, u64, u64) {
        (
            record.pool_id,
            record.is_a_to_b,
            record.amount_in,
            record.amount_out,
            record.fee_paid,
            record.price_impact_bps,
            record.timestamp_ms
        )
    }

    /// Get paginated user swaps
    public fun get_user_swaps_paginated(
        history: &UserSwapHistory,
        start: u64,
        limit: u64
    ): vector<SwapRecord> {
        let mut result = vector::empty<SwapRecord>();
        let mut len = vector::length(&history.swaps);
        
        if (start >= len) {
            return result
        };

        let mut end = start + limit;
        if (end > len) {
            end = len;
        };

        let mut i = start;
        while (i < end) {
            vector::push_back(&mut result, *vector::borrow(&history.swaps, i));
            i = i + 1;
        };

        result
    }

    /// Clear user history (owner only)
    public fun clear_user_history(
        history: &mut UserSwapHistory,
        ctx: &TxContext
    ) {
        assert!(history.owner == tx_context::sender(ctx), EUnauthorized);
        history.swaps = vector::empty();
        // Keep cumulative stats
    }

    #[test_only]
    public fun destroy_user_history_for_testing(history: UserSwapHistory) {
        let UserSwapHistory {
            id,
            owner: _,
            swaps: _,
            total_swaps: _,
            total_volume_in: _,
            total_fees_paid: _,
        } = history;
        object::delete(id);
    }
}
