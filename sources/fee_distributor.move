module sui_amm::fee_distributor {
    use sui::coin;
    use sui::clock;
    use sui::tx_context;
    use sui::event;
    use sui::object;
    
    use sui_amm::pool;
    use sui_amm::stable_pool;
    use sui_amm::position;

    // FIX [P2-17.3]: Minimum fee threshold to prevent dust accumulation
    // Compounding fees below this threshold wastes gas and creates dust
    // Set to 1000 units (0.000001 for 6-decimal tokens, 0.000000001 for 9-decimal)
    const MIN_COMPOUND_AMOUNT: u64 = 1000;

    // Events
    public struct FeesCompounded has copy, drop {
        pool_id: object::ID,
        position_id: object::ID,
        user: address,
        fee_a_compounded: u64,
        fee_b_compounded: u64,
        liquidity_added: u64,
        refund_a: u64,
        refund_b: u64,
    }

    /// Claim pending fees and immediately re-add them as liquidity to compound returns.
    /// This increases the user's LP position size.
    /// Returns any refund amounts (dust) that couldn't be added.
    /// Note: If only one token has fees, returns both as refunds since increase_liquidity
    /// requires both amounts > 0 to maintain pool ratio.
    /// FIX [P2-17.3]: Enhanced with dust prevention - fees below MIN_COMPOUND_AMOUNT are returned
    public fun compound_fees<CoinA, CoinB>(
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // FIX [P2-16.3]: Compound fees with double-claiming protection
        // The withdraw_fees function already includes defense-in-depth validation
        // to prevent fee double-claiming exploits
        // 1. Withdraw fees (with built-in double-claim protection)
        let (fee_a, fee_b) = pool::withdraw_fees(pool, position, clock, deadline, ctx);
        
        let amount_a = coin::value(&fee_a);
        let amount_b = coin::value(&fee_b);
        
        // FIX [P2-17.3]: Zero-fee validation - return empty coins immediately
        if (amount_a == 0 && amount_b == 0) {
            coin::destroy_zero(fee_a);
            coin::destroy_zero(fee_b);
            return (coin::zero(ctx), coin::zero(ctx))
        };

        // FIX [P2-17.3]: Dust prevention - if fees are too small, return them instead of compounding
        // Compounding tiny amounts wastes gas and creates dust accumulation
        // Users can accumulate fees and compound later when amounts are meaningful
        if (amount_a < MIN_COMPOUND_AMOUNT || amount_b < MIN_COMPOUND_AMOUNT) {
            return (fee_a, fee_b)
        };

        // If either is zero, we can't add liquidity (requires both > 0)
        // Return the fees as refunds instead
        if (amount_a == 0 || amount_b == 0) {
            return (fee_a, fee_b)
        };

        // 2. Add liquidity with withdrawn fees to the SAME position
        let liquidity_before = position::liquidity(position);
        let (refund_a, refund_b) = pool::increase_liquidity(
            pool,
            position,
            fee_a,
            fee_b,
            min_liquidity,
            clock,
            deadline,
            ctx
        );
        let liquidity_after = position::liquidity(position);
        let liquidity_added = liquidity_after - liquidity_before;
        
        // Emit compound event with details
        event::emit(FeesCompounded {
            pool_id: position::pool_id(position),
            position_id: sui::object::id_from_address(sui::object::id_to_address(&position::pool_id(position))),
            user: tx_context::sender(ctx),
            fee_a_compounded: amount_a - coin::value(&refund_a),
            fee_b_compounded: amount_b - coin::value(&refund_b),
            liquidity_added,
            refund_a: coin::value(&refund_a),
            refund_b: coin::value(&refund_b),
        });
        
        (refund_a, refund_b)
    }

    /// Compound fees for stable pool
    /// Note: If only one token has fees, returns both as refunds since increase_liquidity
    /// requires both amounts > 0 to maintain pool ratio.
    /// FIX [P2-17.3]: Enhanced with dust prevention - fees below MIN_COMPOUND_AMOUNT are returned
    public fun compound_fees_stable<CoinA, CoinB>(
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        let (fee_a, fee_b) = stable_pool::withdraw_fees(pool, position, clock, deadline, ctx);
        
        let amount_a = coin::value(&fee_a);
        let amount_b = coin::value(&fee_b);
        
        // FIX [P2-17.3]: Zero-fee validation - return empty coins immediately
        if (amount_a == 0 && amount_b == 0) {
            coin::destroy_zero(fee_a);
            coin::destroy_zero(fee_b);
            return (coin::zero(ctx), coin::zero(ctx))
        };

        // FIX [P2-17.3]: Dust prevention - if fees are too small, return them instead of compounding
        // Compounding tiny amounts wastes gas and creates dust accumulation
        if (amount_a < MIN_COMPOUND_AMOUNT || amount_b < MIN_COMPOUND_AMOUNT) {
            return (fee_a, fee_b)
        };

        // If either is zero, we can't add liquidity (requires both > 0)
        // Return the fees as refunds instead
        if (amount_a == 0 || amount_b == 0) {
            return (fee_a, fee_b)
        };

        let liquidity_before = position::liquidity(position);
        let (refund_a, refund_b) = stable_pool::increase_liquidity(
            pool,
            position,
            fee_a,
            fee_b,
            min_liquidity,
            clock,
            deadline,
            ctx
        );
        let liquidity_after = position::liquidity(position);
        let liquidity_added = liquidity_after - liquidity_before;
        
        // Emit compound event with details
        event::emit(FeesCompounded {
            pool_id: position::pool_id(position),
            position_id: sui::object::id_from_address(sui::object::id_to_address(&position::pool_id(position))),
            user: tx_context::sender(ctx),
            fee_a_compounded: amount_a - coin::value(&refund_a),
            fee_b_compounded: amount_b - coin::value(&refund_b),
            liquidity_added,
            refund_a: coin::value(&refund_a),
            refund_b: coin::value(&refund_b),
        });
        
        (refund_a, refund_b)
    }

    /// Helper to claim fees (wrapper around pool::withdraw_fees)
    public fun claim_fees<CoinA, CoinB>(
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        pool::withdraw_fees(pool, position, clock, deadline, ctx)
    }

    /// Helper to claim fees for stable pool
    public fun claim_fees_stable<CoinA, CoinB>(
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        stable_pool::withdraw_fees(pool, position, clock, deadline, ctx)
    }

    // FIX [P2-17.3]: Helper functions for dust prevention
    
    /// Get the minimum compound amount threshold
    /// Fees below this amount should not be compounded to avoid gas waste
    public fun min_compound_amount(): u64 {
        MIN_COMPOUND_AMOUNT
    }

    /// Check if fee amounts are worth compounding
    /// Returns true if both amounts meet the minimum threshold
    public fun is_worth_compounding(amount_a: u64, amount_b: u64): bool {
        amount_a >= MIN_COMPOUND_AMOUNT && amount_b >= MIN_COMPOUND_AMOUNT
    }
}
