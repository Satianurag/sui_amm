/// Main entry point module for the Sui AMM protocol
/// 
/// This module provides entry function wrappers for client applications to interact
/// with the AMM protocol. Entry functions can be called directly from transactions
/// without requiring intermediate Move calls.
/// 
/// # Overview
/// 
/// The sui_amm module serves as the public interface for:
/// - Auto-compounding position fees
/// - Refreshing position metadata
/// - Package initialization
/// 
/// # Entry Functions
/// 
/// Entry functions are special functions that can be called directly from transactions.
/// They are the primary way for client applications (wallets, dApps) to interact with
/// the protocol.
/// 
/// ## Available Entry Functions
/// 
/// ### auto_compound_fees_entry
/// Automatically reinvest accumulated fees back into a position:
/// ```move
/// sui_amm::auto_compound_fees_entry<CoinA, CoinB>(
///     &mut pool,
///     &mut position,
///     min_liquidity_increase,
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// ### refresh_position_metadata_entry
/// Update cached NFT metadata with current values:
/// ```move
/// sui_amm::refresh_position_metadata_entry<CoinA, CoinB>(
///     &pool,
///     &mut position,
///     &clock
/// );
/// ```
/// 
/// # Usage Examples
/// 
/// ## From TypeScript/JavaScript
/// ```typescript
/// // Auto-compound fees
/// const tx = new TransactionBlock();
/// tx.moveCall({
///   target: `${PACKAGE_ID}::sui_amm::auto_compound_fees_entry`,
///   typeArguments: [COIN_A_TYPE, COIN_B_TYPE],
///   arguments: [
///     tx.object(poolId),
///     tx.object(positionId),
///     tx.pure(minLiquidityIncrease),
///     tx.object(CLOCK_ID),
///     tx.pure(deadline),
///   ],
/// });
/// await signAndExecute(tx);
/// 
/// // Refresh metadata
/// const tx2 = new TransactionBlock();
/// tx2.moveCall({
///   target: `${PACKAGE_ID}::sui_amm::refresh_position_metadata_entry`,
///   typeArguments: [COIN_A_TYPE, COIN_B_TYPE],
///   arguments: [
///     tx2.object(poolId),
///     tx2.object(positionId),
///     tx2.object(CLOCK_ID),
///   ],
/// });
/// await signAndExecute(tx2);
/// ```
/// 
/// ## From Sui CLI
/// ```bash
/// # Auto-compound fees
/// sui client call \
///   --package $PACKAGE_ID \
///   --module sui_amm \
///   --function auto_compound_fees_entry \
///   --type-args $COIN_A $COIN_B \
///   --args $POOL_ID $POSITION_ID $MIN_LIQUIDITY $CLOCK_ID $DEADLINE \
///   --gas-budget 10000000
/// 
/// # Refresh metadata
/// sui client call \
///   --package $PACKAGE_ID \
///   --module sui_amm \
///   --function refresh_position_metadata_entry \
///   --type-args $COIN_A $COIN_B \
///   --args $POOL_ID $POSITION_ID $CLOCK_ID \
///   --gas-budget 5000000
/// ```
/// 
/// # Design Pattern: Entry Function Wrappers
/// 
/// Entry functions in this module are thin wrappers around the underlying pool functions.
/// This design provides several benefits:
/// 
/// 1. **Separation of Concerns**: Core logic in pool module, entry points here
/// 2. **Validation**: All validation happens in the underlying functions
/// 3. **Consistency**: Entry functions and direct calls produce identical results
/// 4. **Maintainability**: Changes to logic only need to happen in one place
/// 
/// # Error Handling
/// 
/// Entry functions propagate errors from the underlying pool functions:
/// - `EWrongPool`: Position doesn't belong to pool
/// - `EInsufficientFeesToCompound`: Fees below minimum threshold
/// - `EInsufficientOutput`: Slippage protection triggered
/// - `EPaused`: Pool is paused
/// - Deadline exceeded: Transaction deadline passed
/// 
/// # Gas Considerations
/// 
/// Entry functions have minimal overhead compared to direct calls:
/// - Auto-compound: ~0.01 SUI (varies with pool state)
/// - Refresh metadata: ~0.005 SUI (varies with SVG complexity)
/// 
/// For gas optimization:
/// - Batch multiple operations in a single transaction
/// - Only refresh metadata when necessary
/// - Use appropriate staleness thresholds
/// 
module sui_amm::sui_amm {
    use sui::package;
    use sui::clock;
    use sui_amm::pool;
    use sui_amm::position;
    // TxContext not needed - auto-imported

    /// OTW for the package
    public struct SUI_AMM has drop {}

    fun init(otw: SUI_AMM, ctx: &mut tx_context::TxContext) {
        let publisher = package::claim(otw, ctx);
        transfer::public_share_object(publisher);
    }

    /// Entry point wrapper for auto-compounding fees
    /// 
    /// Automatically reinvests accumulated fees back into the liquidity position.
    /// This is a convenience wrapper around pool::auto_compound_fees() that can be
    /// called directly from client applications.
    /// 
    /// # Parameters
    /// * `pool` - The liquidity pool (shared object)
    /// * `position` - The LP position to auto-compound (owned by sender)
    /// * `min_liquidity_increase` - Minimum liquidity shares to mint (slippage protection)
    /// * `clock` - Clock for deadline checking (shared object)
    /// * `deadline` - Transaction deadline timestamp in milliseconds
    /// * `ctx` - Transaction context
    /// 
    /// # Aborts
    /// * `EWrongPool` - If position doesn't belong to this pool
    /// * `EInsufficientFeesToCompound` - If fees are below minimum threshold
    /// * `EInsufficientOutput` - If liquidity increase is below min_liquidity_increase
    /// * `EPaused` - If pool is paused
    /// * Deadline exceeded - If current time > deadline
    entry fun auto_compound_fees_entry<CoinA, CoinB>(
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        min_liquidity_increase: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ) {
        // Delegate to pool module for actual implementation
        // All validation (pause status, deadline, ownership, thresholds) happens there
        let (_liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
            pool,
            position,
            min_liquidity_increase,
            clock,
            deadline,
            ctx
        );
        
        // Transfer any refund coins back to sender
        transfer::public_transfer(refund_a, tx_context::sender(ctx));
        transfer::public_transfer(refund_b, tx_context::sender(ctx));
    }

    /// Entry point wrapper for refreshing position metadata
    /// 
    /// Updates the cached NFT metadata with current position values from the pool.
    /// This is useful when the cached values have become stale after pool swaps.
    /// This is a convenience wrapper around pool::refresh_position_metadata() that
    /// can be called directly from client applications.
    /// 
    /// # Parameters
    /// * `pool` - The liquidity pool (shared object)
    /// * `position` - The LP position to refresh (owned by sender)
    /// * `clock` - Clock for timestamp tracking (shared object)
    /// 
    /// # Aborts
    /// * `EWrongPool` - If position doesn't belong to this pool
    entry fun refresh_position_metadata_entry<CoinA, CoinB>(
        pool: &pool::LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock
    ) {
        // Delegate to pool module for actual implementation
        // All validation (ownership, staleness checks) happens there
        pool::refresh_position_metadata(
            pool,
            position,
            clock
        );
    }
}


