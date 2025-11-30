module sui_amm::admin {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Coin};

    use sui_amm::pool::{LiquidityPool};
    use sui_amm::stable_pool::{StableSwapPool};

    /// Admin capability for protocol management
    struct AdminCap has key, store {
        id: UID,
    }

    /// Initialize the admin module and create admin capability
    fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));
    }

    /// Withdraw protocol fees from a regular liquidity pool
    public fun withdraw_protocol_fees_from_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        sui_amm::pool::withdraw_protocol_fees(pool, ctx)
    }

    /// Withdraw protocol fees from a stable swap pool
    public fun withdraw_protocol_fees_from_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        sui_amm::stable_pool::withdraw_protocol_fees(pool, ctx)
    }

    public fun update_pool_risk_params<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
        ctx: &mut TxContext
    ) {
        sui_amm::pool::set_risk_params(pool, ratio_tolerance_bps, max_price_impact_bps);
        ctx;
    }

    public fun update_stable_pool_max_price_impact<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        max_price_impact_bps: u64,
        ctx: &mut TxContext
    ) {
        sui_amm::stable_pool::set_max_price_impact_bps(pool, max_price_impact_bps);
        ctx;
    }

    /// FIX [M2]: Admin function to update protocol fees for regular pools
    public fun set_pool_protocol_fee<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        new_percent: u64
    ) {
        sui_amm::pool::set_protocol_fee_percent(pool, new_percent);
    }

    /// FIX [M2]: Admin function to update protocol fees for stable pools
    public fun set_stable_pool_protocol_fee<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        new_percent: u64
    ) {
        sui_amm::stable_pool::set_protocol_fee_percent(pool, new_percent);
    }

    /// FIX [L1]: Admin function to initiate amp ramping for stable pools
    public fun ramp_stable_pool_amp<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::ramp_amp(pool, target_amp, ramp_duration_ms, clock);
    }

    /// FIX [L1]: Admin function to stop ongoing amp ramp
    public fun stop_stable_pool_amp_ramp<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::stop_ramp_amp(pool, clock);
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }
}
