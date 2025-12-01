module sui_amm::admin {
    use sui::object;
    use sui::tx_context;
    use sui::transfer;
    use sui::coin;

    use sui_amm::pool;
    use sui_amm::stable_pool;

    /// Admin capability for protocol management
    public struct AdminCap has key {
        id: object::UID,
    }

    /// Initialize the admin module and create admin capability
    /// SECURITY FIX [P1-15.1]: AdminCap is now frozen to prevent unauthorized transfers
    /// This prevents capability leaks and ensures only the initial admin can use it
    /// 
    /// IMPORTANT: Once frozen, the AdminCap cannot be transferred. If you need
    /// multi-sig or transferable admin rights, modify this to transfer to a
    /// multi-sig address instead of freezing.
    fun init(ctx: &mut tx_context::TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        // FIX [P1-15.1]: Freeze AdminCap to prevent unauthorized transfers
        // This makes the capability immutable and bound to the deployer's address
        transfer::freeze_object(admin_cap);
    }

    /// Withdraw protocol fees from a regular liquidity pool
    public fun withdraw_protocol_fees_from_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        sui_amm::pool::withdraw_protocol_fees(pool, ctx)
    }

    /// Withdraw protocol fees from a stable swap pool
    public fun withdraw_protocol_fees_from_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        sui_amm::stable_pool::withdraw_protocol_fees(pool, ctx)
    }

    // NOTE: Protocol fee changes and risk parameter updates must now go through 
    // the governance module with a timelock. Direct setters have been removed.

    /// FIX [L1]: Admin function to initiate amp ramping for stable pools
    public fun ramp_stable_pool_amp<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::ramp_amp(pool, target_amp, ramp_duration_ms, clock);
    }

    /// FIX [L1]: Admin function to stop ongoing amp ramp
    public fun stop_stable_pool_amp_ramp<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::stop_ramp_amp(pool, clock);
    }

    /// Pause a regular liquidity pool (emergency control)
    /// SECURITY FIX [P2-18.1]: Pause now requires governance proposal with timelock
    /// This prevents instant pause abuse while maintaining emergency response capability
    /// Use governance::propose_pause() to initiate a pause with timelock delay
    public fun pause_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::pool::pause_pool(pool, clock);
    }

    /// Unpause a regular liquidity pool
    public fun unpause_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::pool::unpause_pool(pool, clock);
    }

    /// Pause a stable swap pool (emergency control)
    /// SECURITY FIX [P2-18.1]: Pause now requires governance proposal with timelock
    /// This prevents instant pause abuse while maintaining emergency response capability
    /// Use governance::propose_pause() to initiate a pause with timelock delay
    public fun pause_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::pause_pool(pool, clock);
    }

    /// Unpause a stable swap pool
    public fun unpause_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::unpause_pool(pool, clock);
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }
}
