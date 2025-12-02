/// On-chain swap history tracking and statistics
///
/// This module provides comprehensive swap tracking at both the user and pool level.
/// Users can maintain their own swap history (last 100 swaps) while pools track
/// aggregate statistics including total volume, fees collected, and 24-hour metrics.
///
/// The design uses owned objects for user history (privacy) and shared objects for
/// pool statistics (public visibility).
module sui_amm::swap_history {
    use sui::table;
    use sui::clock;

    // Error codes
    const EUnauthorized: u64 = 1;

    // History size limits to prevent unbounded growth
    const MAX_HISTORY_PER_USER: u64 = 100;
    const MAX_POOL_RECENT_SWAPS: u64 = 50;

    /// Individual swap record capturing all relevant swap details
    ///
    /// Stores immutable data about a single swap transaction including amounts,
    /// fees, price impact, and timestamp. The copy+drop abilities allow efficient
    /// storage and retrieval.
    public struct SwapRecord has store, copy, drop {
        pool_id: object::ID,
        is_a_to_b: bool,
        amount_in: u64,
        amount_out: u64,
        fee_paid: u64,
        price_impact_bps: u64,
        timestamp_ms: u64,
    }

    /// User's personal swap history
    ///
    /// Owned object that tracks a user's recent swaps (up to MAX_HISTORY_PER_USER)
    /// along with cumulative statistics. Older swaps are automatically removed when
    /// the limit is reached, but cumulative stats are preserved.
    public struct UserSwapHistory has key, store {
        id: object::UID,
        owner: address,
        swaps: vector<SwapRecord>,
        total_swaps: u64,
        total_volume_in: u128,  // Cumulative input volume
        total_fees_paid: u128,  // Cumulative fees paid
    }

    /// Pool-level swap statistics
    ///
    /// Shared object tracking aggregate statistics for a specific pool including
    /// total volume, fees collected, and rolling 24-hour metrics. Recent swaps
    /// are kept for analysis but older ones are removed to prevent unbounded growth.
    public struct PoolStatistics has key {
        id: object::UID,
        pool_id: object::ID,
        recent_swaps: vector<SwapRecord>,
        total_swaps: u64,
        total_volume_a: u128,
        total_volume_b: u128,
        total_fees_a: u128,
        total_fees_b: u128,
        // Rolling 24-hour statistics (simplified: reset if gap > 24h)
        volume_24h_a: u64,
        volume_24h_b: u64,
        swaps_24h: u64,
        last_swap_timestamp: u64,
    }

    /// Global registry mapping pools to their statistics objects
    ///
    /// Shared object that maintains a lookup table from pool IDs to their
    /// corresponding PoolStatistics object IDs. This allows finding a pool's
    /// statistics without knowing the object ID in advance.
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

    /// Create a new user swap history object
    ///
    /// Initializes an empty history with zero cumulative statistics.
    /// The created object is owned by the transaction sender.
    ///
    /// # Returns
    /// New UserSwapHistory object ready to track swaps
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

    /// Create user history and transfer to a specific recipient
    ///
    /// Convenience function for creating history objects for other users.
    public fun create_and_transfer_history(recipient: address, ctx: &mut tx_context::TxContext) {
        let history = create_user_history(ctx);
        transfer::transfer(history, recipient);
    }

    /// Initialize statistics tracking for a new pool
    ///
    /// Creates a PoolStatistics object and registers it in the global registry.
    /// Should be called once when a pool is created. Idempotent - does nothing
    /// if statistics already exist for the pool.
    ///
    /// # Parameters
    /// - `registry`: The global statistics registry
    /// - `pool_id`: ID of the pool to initialize statistics for
    /// - `ctx`: Transaction context
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

    /// Record a swap in the user's personal history
    ///
    /// Adds a new swap record to the user's history, automatically removing the
    /// oldest record if the maximum capacity is reached. Updates cumulative
    /// statistics regardless of history size.
    ///
    /// # Parameters
    /// - `history`: The user's swap history object
    /// - `pool_id`: ID of the pool where the swap occurred
    /// - `is_a_to_b`: Direction of swap (true = A→B, false = B→A)
    /// - `amount_in`: Input amount
    /// - `amount_out`: Output amount received
    /// - `fee_paid`: Fee amount paid
    /// - `price_impact_bps`: Price impact in basis points
    /// - `clock`: Clock for timestamp
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

        // Maintain fixed-size history by removing oldest entry when at capacity
        if (vector::length(&history.swaps) >= MAX_HISTORY_PER_USER) {
            vector::remove(&mut history.swaps, 0);
        };

        vector::push_back(&mut history.swaps, record);
        
        // Update cumulative statistics (never reset)
        history.total_swaps = history.total_swaps + 1;
        history.total_volume_in = history.total_volume_in + (amount_in as u128);
        history.total_fees_paid = history.total_fees_paid + (fee_paid as u128);
    }

    /// Record a swap in pool statistics (package-internal interface)
    ///
    /// Unified function for pool modules to record swaps. This is the preferred
    /// interface for pool integration as it provides a stable API.
    ///
    /// Note: PoolStatistics must be passed directly as it's a shared object.
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

    /// Record a swap in pool statistics with full details
    ///
    /// Updates both recent swap history and aggregate statistics. Maintains
    /// a rolling 24-hour window for short-term metrics (simplified implementation
    /// that resets if more than 24 hours pass between swaps).
    ///
    /// # Parameters
    /// - `stats`: The pool's statistics object
    /// - `is_a_to_b`: Direction of swap (true = A→B, false = B→A)
    /// - `amount_in`: Input amount
    /// - `amount_out`: Output amount received
    /// - `fee_paid`: Fee amount paid
    /// - `price_impact_bps`: Price impact in basis points
    /// - `clock`: Clock for timestamp
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

        // Maintain fixed-size recent history
        if (vector::length(&stats.recent_swaps) >= MAX_POOL_RECENT_SWAPS) {
            vector::remove(&mut stats.recent_swaps, 0);
        };

        vector::push_back(&mut stats.recent_swaps, record);
        stats.total_swaps = stats.total_swaps + 1;

        // Update cumulative volume and fee statistics by direction
        if (is_a_to_b) {
            stats.total_volume_a = stats.total_volume_a + (amount_in as u128);
            stats.total_fees_a = stats.total_fees_a + (fee_paid as u128);
        } else {
            stats.total_volume_b = stats.total_volume_b + (amount_in as u128);
            stats.total_fees_b = stats.total_fees_b + (fee_paid as u128);
        };

        // Update 24-hour rolling statistics
        // Simplified approach: reset if more than 24 hours have passed since last swap
        // A more sophisticated implementation would use a sliding window
        let day_ms = 86_400_000u64;
        if (timestamp > stats.last_swap_timestamp + day_ms) {
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
    // These functions provide read-only access to history and statistics

    /// Get reference to user's complete swap history
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

    /// Get a paginated slice of user's swap history
    ///
    /// Useful for displaying history in chunks without loading all records.
    ///
    /// # Parameters
    /// - `history`: The user's swap history
    /// - `start`: Starting index (0-based)
    /// - `limit`: Maximum number of records to return
    ///
    /// # Returns
    /// Vector of swap records from [start, start+limit), or fewer if end is reached
    public fun get_user_swaps_paginated(
        history: &UserSwapHistory,
        start: u64,
        limit: u64
    ): vector<SwapRecord> {
        let mut result = vector::empty<SwapRecord>();
        let len = vector::length(&history.swaps);
        
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

    /// Clear user's swap history while preserving cumulative statistics
    ///
    /// Removes all swap records but keeps total counts, volume, and fees.
    /// Only the owner can clear their own history.
    ///
    /// # Aborts
    /// - `EUnauthorized`: If caller is not the history owner
    public fun clear_user_history(
        history: &mut UserSwapHistory,
        ctx: &mut TxContext
    ) {
        assert!(history.owner == tx_context::sender(ctx), EUnauthorized);
        history.swaps = vector::empty();
        // Cumulative statistics (total_swaps, total_volume_in, total_fees_paid) are preserved
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
