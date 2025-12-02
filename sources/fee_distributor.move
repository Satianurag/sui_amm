/// Fee distribution and compounding functionality
///
/// This module provides utilities for claiming and compounding liquidity provider fees.
/// Compounding allows LPs to automatically reinvest their earned fees back into their
/// position, increasing their liquidity and future fee earnings.
///
/// # Fee Compounding
/// When fees are compounded, they are withdrawn from the position and immediately
/// re-added as liquidity to the same position. This increases the LP's share of the
/// pool and future fee earnings without requiring manual reinvestment.
///
/// # Dust Prevention
/// To prevent gas waste and dust accumulation, fees below MIN_COMPOUND_AMOUNT are
/// returned to the user rather than being compounded. This threshold is set to 1000
/// base units, which represents:
/// - 0.000001 tokens for 6-decimal tokens (like USDC)
/// - 0.000000001 tokens for 9-decimal tokens (like SUI)
module sui_amm::fee_distributor {
    use sui::coin;
    use sui::clock;
    use sui::event;
    
    use sui_amm::pool;
    use sui_amm::stable_pool;
    use sui_amm::position;

    /// Minimum fee amount required for compounding
    ///
    /// Fees below this threshold are returned to the user instead of being compounded
    /// to avoid wasting gas on dust amounts. Set to 1000 base units.
    const MIN_COMPOUND_AMOUNT: u64 = 1000;

    /// Emitted when fees are successfully compounded into a position
    ///
    /// Records the amounts compounded, liquidity added, and any refunds due to
    /// rounding or ratio constraints.
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

    /// Compound fees for a constant product pool position
    ///
    /// Withdraws pending fees and immediately re-adds them as liquidity to the same
    /// position, increasing the LP's share and future fee earnings. This is more
    /// gas-efficient than manually claiming and re-adding liquidity.
    ///
    /// # Dust Prevention
    /// Fees below MIN_COMPOUND_AMOUNT are returned instead of compounded to avoid
    /// wasting gas on tiny amounts. Users can accumulate fees and compound later
    /// when amounts are meaningful.
    ///
    /// # Ratio Requirements
    /// Adding liquidity requires both token amounts > 0 to maintain the pool ratio.
    /// If only one token has fees, both are returned as refunds.
    ///
    /// # Parameters
    /// - `pool`: The liquidity pool
    /// - `position`: The LP position to compound fees for
    /// - `min_liquidity`: Minimum liquidity to add (slippage protection)
    /// - `clock`: For deadline validation
    /// - `deadline`: Transaction deadline
    ///
    /// # Returns
    /// Tuple of (refund_a, refund_b) - any amounts that couldn't be compounded
    ///
    /// # Security
    /// Uses the pool's built-in double-claim protection to prevent fee exploits.
    public fun compound_fees<CoinA, CoinB>(
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // Withdraw fees with built-in double-claim protection
        let (fee_a, fee_b) = pool::withdraw_fees(pool, position, clock, deadline, ctx);
        
        let amount_a = coin::value(&fee_a);
        let amount_b = coin::value(&fee_b);
        
        // Handle zero fees - destroy zero coins and return empty coins
        if (amount_a == 0 && amount_b == 0) {
            coin::destroy_zero(fee_a);
            coin::destroy_zero(fee_b);
            return (coin::zero(ctx), coin::zero(ctx))
        };

        // Dust prevention: return fees if either amount is too small
        // Compounding tiny amounts wastes more gas than the value gained
        if (amount_a < MIN_COMPOUND_AMOUNT || amount_b < MIN_COMPOUND_AMOUNT) {
            return (fee_a, fee_b)
        };

        // Both amounts must be > 0 to add liquidity (pool ratio requirement)
        // Return fees as refunds if this condition isn't met
        if (amount_a == 0 || amount_b == 0) {
            return (fee_a, fee_b)
        };

        // Add withdrawn fees as liquidity to the same position
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

    /// Compound fees for a stable swap pool position
    ///
    /// Identical to compound_fees but for stable swap pools. Withdraws pending fees
    /// and immediately re-adds them as liquidity to increase the LP's position.
    ///
    /// # Dust Prevention
    /// Fees below MIN_COMPOUND_AMOUNT are returned instead of compounded.
    ///
    /// # Ratio Requirements
    /// Adding liquidity requires both token amounts > 0. If only one token has fees,
    /// both are returned as refunds.
    ///
    /// # Parameters
    /// - `pool`: The stable swap pool
    /// - `position`: The LP position to compound fees for
    /// - `min_liquidity`: Minimum liquidity to add (slippage protection)
    /// - `clock`: For deadline validation
    /// - `deadline`: Transaction deadline
    ///
    /// # Returns
    /// Tuple of (refund_a, refund_b) - any amounts that couldn't be compounded
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
        
        // Handle zero fees - destroy zero coins and return empty coins
        if (amount_a == 0 && amount_b == 0) {
            coin::destroy_zero(fee_a);
            coin::destroy_zero(fee_b);
            return (coin::zero(ctx), coin::zero(ctx))
        };

        // Dust prevention: return fees if either amount is too small
        if (amount_a < MIN_COMPOUND_AMOUNT || amount_b < MIN_COMPOUND_AMOUNT) {
            return (fee_a, fee_b)
        };

        // Both amounts must be > 0 to add liquidity (pool ratio requirement)
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

    /// Claim fees from a constant product pool position
    ///
    /// Withdraws pending fees without compounding them. Use this when you want
    /// to receive fees directly rather than reinvesting them.
    ///
    /// # Returns
    /// Tuple of (fee_a, fee_b) coins
    public fun claim_fees<CoinA, CoinB>(
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        pool::withdraw_fees(pool, position, clock, deadline, ctx)
    }

    /// Claim fees from a stable swap pool position
    ///
    /// Withdraws pending fees without compounding them. Use this when you want
    /// to receive fees directly rather than reinvesting them.
    ///
    /// # Returns
    /// Tuple of (fee_a, fee_b) coins
    public fun claim_fees_stable<CoinA, CoinB>(
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        stable_pool::withdraw_fees(pool, position, clock, deadline, ctx)
    }

    /// Get the minimum fee amount required for compounding
    ///
    /// Fees below this threshold should not be compounded as the gas cost
    /// exceeds the value gained. Returns 1000 base units.
    public fun min_compound_amount(): u64 {
        MIN_COMPOUND_AMOUNT
    }

    /// Check if fee amounts are worth compounding
    ///
    /// Returns true only if both amounts meet the minimum threshold. This helps
    /// users decide whether to compound or wait for fees to accumulate.
    ///
    /// # Parameters
    /// - `amount_a`: Fee amount for token A
    /// - `amount_b`: Fee amount for token B
    ///
    /// # Returns
    /// True if both amounts >= MIN_COMPOUND_AMOUNT
    public fun is_worth_compounding(amount_a: u64, amount_b: u64): bool {
        amount_a >= MIN_COMPOUND_AMOUNT && amount_b >= MIN_COMPOUND_AMOUNT
    }
}
