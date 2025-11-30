module sui_amm::fee_distributor {
    use sui::coin::{Self, Coin};
    use sui::clock::{Clock};
    use sui::tx_context::{TxContext};
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::position::{LPPosition};

    /// Claim pending fees and immediately re-add them as liquidity to compound returns.
    /// This increases the user's LP position size.
    /// Returns any refund amounts (dust) that couldn't be added.
    /// Note: If only one token has fees, returns both as refunds since increase_liquidity
    /// requires both amounts > 0 to maintain pool ratio.
    public fun compound_fees<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        min_liquidity: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        // 1. Withdraw fees
        let (fee_a, fee_b) = pool::withdraw_fees(pool, position, clock, deadline, ctx);
        
        let amount_a = coin::value(&fee_a);
        let amount_b = coin::value(&fee_b);
        
        // If both are zero, return empty coins
        if (amount_a == 0 && amount_b == 0) {
            coin::destroy_zero(fee_a);
            coin::destroy_zero(fee_b);
            return (coin::zero(ctx), coin::zero(ctx))
        };

        // If either is zero, we can't add liquidity (requires both > 0)
        // Return the fees as refunds instead
        if (amount_a == 0 || amount_b == 0) {
            return (fee_a, fee_b)
        };

        // 2. Add liquidity with withdrawn fees to the SAME position
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
        
        (refund_a, refund_b)
    }

    /// Compound fees for stable pool
    /// Note: If only one token has fees, returns both as refunds since increase_liquidity
    /// requires both amounts > 0 to maintain pool ratio.
    public fun compound_fees_stable<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition,
        min_liquidity: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let (fee_a, fee_b) = stable_pool::withdraw_fees(pool, position, clock, deadline, ctx);
        
        let amount_a = coin::value(&fee_a);
        let amount_b = coin::value(&fee_b);
        
        // If both are zero, return empty coins
        if (amount_a == 0 && amount_b == 0) {
            coin::destroy_zero(fee_a);
            coin::destroy_zero(fee_b);
            return (coin::zero(ctx), coin::zero(ctx))
        };

        // If either is zero, we can't add liquidity (requires both > 0)
        // Return the fees as refunds instead
        if (amount_a == 0 || amount_b == 0) {
            return (fee_a, fee_b)
        };

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
        
        (refund_a, refund_b)
    }

    /// Helper to claim fees (wrapper around pool::withdraw_fees)
    public fun claim_fees<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        pool::withdraw_fees(pool, position, clock, deadline, ctx)
    }

    /// Helper to claim fees for stable pool
    public fun claim_fees_stable<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        stable_pool::withdraw_fees(pool, position, clock, deadline, ctx)
    }
}
