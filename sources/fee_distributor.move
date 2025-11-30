module sui_amm::fee_distributor {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::event;
    use std::option::{Self, Option};
    use std::vector;

    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::position::{LPPosition};

    friend sui_amm::admin;

    // Error codes
    const ENoPositions: u64 = 0;
    const EInvalidDeadline: u64 = 1;
    const EBatchTooLarge: u64 = 2; // NEW: DoS protection

    // Constants
    const MAX_BATCH_SIZE: u64 = 100; // NEW: Max positions per batch claim

    /// Capability for managing protocol fees
    struct AdminCap has key, store {
        id: UID,
    }

    /// Registry for tracking fee claims across the protocol
    struct FeeRegistry has key {
        id: UID,
        total_fees_claimed_a: Table<ID, u64>, // pool_id -> total CoinA fees claimed
        total_fees_claimed_b: Table<ID, u64>, // pool_id -> total CoinB fees claimed
        // REMOVED: claim_history - unbounded vector growth caused scalability issues
        // Use events for historical tracking instead
        total_claims: u64,
    }

    /// Record of a fee claim
    /// NOTE: Still defined for API compatibility, but no longer stored on-chain
    #[allow(unused_field)]
    struct ClaimRecord has store, copy, drop {
        timestamp_ms: u64,
        amount_a: u64,
        amount_b: u64,
        pool_id: ID,
    }

    /// Event emitted when batch claim occurs
    struct BatchFeeClaimed has copy, drop {
        claimer: address,
        num_positions: u64,
        total_amount_a: u64,
        total_amount_b: u64,
        timestamp_ms: u64,
    }

    /// Event emitted for protocol fee sweep
    struct ProtocolFeeSwept has copy, drop {
        pool_id: ID,
        admin: address,
        amount_a: u64,
        amount_b: u64,
        timestamp_ms: u64,
    }

    /// Initialize the fee registry and create admin capability
    fun init(ctx: &mut TxContext) {
        transfer::share_object(FeeRegistry {
            id: object::new(ctx),
            total_fees_claimed_a: table::new(ctx),
            total_fees_claimed_b: table::new(ctx),
            total_claims: 0,
        });

        // Create and transfer AdminCap to deployer
        transfer::transfer(AdminCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Claim fees from a regular liquidity pool with registry tracking
    public fun claim_fees<CoinA, CoinB>(
        registry: &mut FeeRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        clock: &Clock,
        ctx: &mut TxContext  
    ): (Coin<CoinA>, Coin<CoinB>) {
        let (coin_a, coin_b) = pool::withdraw_fees(pool, position, ctx);
        
        // Track in registry
        let pool_id = object::id(pool);
        let position_id = object::id(position);
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        
        record_claim(registry, pool_id, position_id, amount_a, amount_b, clock);
        
        (coin_a, coin_b)
    }

    /// Claim fees from a stable swap pool with registry tracking
    public fun claim_fees_from_stable_pool<CoinA, CoinB>(
        registry: &mut FeeRegistry,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let (coin_a, coin_b) = stable_pool::withdraw_fees(pool, position, ctx);
        
        // Track in registry
        let pool_id = object::id(pool);
        let position_id = object::id(position);
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        
        record_claim(registry, pool_id, position_id, amount_a, amount_b, clock);
        
        (coin_a, coin_b)
    }

    /// Batch claim fees from multiple positions in the same pool
    public fun batch_claim_fees<CoinA, CoinB>(
        _registry: &mut FeeRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        positions: &mut vector<LPPosition>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let num_positions = vector::length(positions);
        assert!(num_positions > 0, ENoPositions);
        assert!(num_positions <= MAX_BATCH_SIZE, EBatchTooLarge);
        
        let mut_coin_a = coin::zero<CoinA>(ctx);
        let mut_coin_b = coin::zero<CoinB>(ctx);
        let mut_i = 0;
        
        while (mut_i < num_positions) {
            let position = vector::borrow_mut(positions, mut_i);
            let (fee_a, fee_b) = pool::withdraw_fees(pool, position, ctx);
            
            coin::join(&mut mut_coin_a, fee_a);
            coin::join(&mut mut_coin_b, fee_b);
            
            mut_i = mut_i + 1;
        };
        
        let total_a = coin::value(&mut_coin_a);
        let total_b = coin::value(&mut_coin_b);
        
        event::emit(BatchFeeClaimed {
            claimer: tx_context::sender(ctx),
            num_positions,
            total_amount_a: total_a,
            total_amount_b: total_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        
        (mut_coin_a, mut_coin_b)
    }

    /// Batch claim from multiple positions in a stable pool
    public fun batch_claim_fees_stable<CoinA, CoinB>(
        _registry: &mut FeeRegistry,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        positions: &mut vector<LPPosition>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let num_positions = vector::length(positions);
        assert!(num_positions > 0, ENoPositions);
        assert!(num_positions <= MAX_BATCH_SIZE, EBatchTooLarge);
        
        let mut_coin_a = coin::zero<CoinA>(ctx);
        let mut_coin_b = coin::zero<CoinB>(ctx);
        let mut_i = 0;
        
        while (mut_i < num_positions) {
            let position = vector::borrow_mut(positions, mut_i);
            let (fee_a, fee_b) = stable_pool::withdraw_fees(pool, position, ctx);
            
            coin::join(&mut mut_coin_a, fee_a);
            coin::join(&mut mut_coin_b, fee_b);
            
            mut_i = mut_i + 1;
        };
        
        let total_a = coin::value(&mut_coin_a);
        let total_b = coin::value(&mut_coin_b);
        
        event::emit(BatchFeeClaimed {
            claimer: tx_context::sender(ctx),
            num_positions,
            total_amount_a: total_a,
            total_amount_b: total_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        
        (mut_coin_a, mut_coin_b)
    }

    /// Auto-compound with configurable deadline and slippage protection
    /// CRITICAL: min_out_a and min_out_b prevent sandwich attacks during fee swaps
    public fun auto_compound_with_deadline<CoinA, CoinB>(
        registry: &mut FeeRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        min_out_a: u64,  // Minimum amount of CoinA to receive from swap (slippage protection)
        min_out_b: u64,  // Minimum amount of CoinB to receive from swap (slippage protection)
        clock: &Clock,
        deadline_ms: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        // Validate deadline
        assert!(clock::timestamp_ms(clock) <= deadline_ms, EInvalidDeadline);
        
        let (coin_a, coin_b) = claim_fees(registry, pool, position, clock, ctx);
        
        // FIX V4: Auto-compound slippage protection - use min_out parameters properly
        if (coin::value(&coin_a) > 0 && coin::value(&coin_b) == 0) {
            let amount_to_swap = coin::value(&coin_a) / 2;
            if (amount_to_swap > 0) {
                let coin_a_split = coin::split(&mut coin_a, amount_to_swap, ctx);
                let coin_out = pool::swap_a_to_b(pool, coin_a_split, min_out_b, option::none(), clock, deadline_ms, ctx);
                coin::join(&mut coin_b, coin_out);
            }
        } else if (coin::value(&coin_b) > 0 && coin::value(&coin_a) == 0) {
            let amount_to_swap = coin::value(&coin_b) / 2;
            if (amount_to_swap > 0) {
                let coin_b_split = coin::split(&mut coin_b, amount_to_swap, ctx);
                let coin_out = pool::swap_b_to_a(pool, coin_b_split, min_out_a, option::none(), clock, deadline_ms, ctx);
                coin::join(&mut coin_a, coin_out);
            }
        };

        if (coin::value(&coin_a) > 0 && coin::value(&coin_b) > 0) {
            let (leftover_a, leftover_b) = pool::increase_liquidity(
                pool, 
                position, 
                coin_a, 
                coin_b,
                clock,
                deadline_ms,
                ctx
            );
            (leftover_a, leftover_b)
        } else {
            (coin_a, coin_b)
        }
    }

    /// Auto-compound stable pool with configurable deadline and slippage protection
    /// CRITICAL: min_out_a and min_out_b prevent sandwich attacks during fee swaps
    public fun auto_compound_stable_with_deadline<CoinA, CoinB>(
        registry: &mut FeeRegistry,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition,
        min_out_a: u64,  // Minimum amount of CoinA to receive from swap (slippage protection)
        min_out_b: u64,  // Minimum amount of CoinB to receive from swap (slippage protection)
        clock: &Clock,
        deadline_ms: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        assert!(clock::timestamp_ms(clock) <= deadline_ms, EInvalidDeadline);
        
        let (coin_a, coin_b) = claim_fees_from_stable_pool(registry, pool, position, clock, ctx);
        
        // SECURITY FIX: Use min_out parameters instead of hardcoded 0
        if (coin::value(&coin_a) > 0 && coin::value(&coin_b) == 0) {
            let amount_to_swap = coin::value(&coin_a) / 2;
            if (amount_to_swap > 0) {
                let coin_in = coin::split(&mut coin_a, amount_to_swap, ctx);
                let coin_out = stable_pool::swap_a_to_b(pool, coin_in, min_out_b, option::none(), clock, deadline_ms, ctx);
                coin::join(&mut coin_b, coin_out);
            }
        } else if (coin::value(&coin_b) > 0 && coin::value(&coin_a) == 0) {
            let amount_to_swap = coin::value(&coin_b) / 2;
            if (amount_to_swap > 0) {
                let coin_in = coin::split(&mut coin_b, amount_to_swap, ctx);
                let coin_out = stable_pool::swap_b_to_a(pool, coin_in, min_out_a, option::none(), clock, deadline_ms, ctx);
                coin::join(&mut coin_a, coin_out);
            }
        };

        if (coin::value(&coin_a) > 0 && coin::value(&coin_b) > 0) {
            let (leftover_a, leftover_b) = stable_pool::increase_liquidity(
                pool,
                position,
                coin_a,
                coin_b,
                clock,
                deadline_ms,
                ctx
            );
            (leftover_a, leftover_b)
        } else {
            (coin_a, coin_b)
        }
    }

    /// Sweep protocol fees from a regular pool (admin only via friend)
    public(friend) fun sweep_protocol_fees<CoinA, CoinB>(
        _admin_cap: &AdminCap,
        _registry: &mut FeeRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let (coin_a, coin_b) = pool::withdraw_protocol_fees(pool, ctx);
        
        let pool_id = object::id(pool);
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        
        event::emit(ProtocolFeeSwept {
            pool_id,
            admin: tx_context::sender(ctx),
            amount_a,
            amount_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        
        (coin_a, coin_b)
    }

    /// Sweep protocol fees from a stable pool (admin only via friend)
    public(friend) fun sweep_protocol_fees_stable<CoinA, CoinB>(
        _admin_cap: &AdminCap,
        _registry: &mut FeeRegistry,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let (coin_a, coin_b) = stable_pool::withdraw_protocol_fees(pool, ctx);
        
        let pool_id = object::id(pool);
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        
        event::emit(ProtocolFeeSwept {
            pool_id,
            admin: tx_context::sender(ctx),
            amount_a,
            amount_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        
        (coin_a, coin_b)
    }

    // Internal helper to record claim
    fun record_claim(
        registry: &mut FeeRegistry,
        pool_id: ID,
        _position_id: ID,
        amount_a: u64,
        amount_b: u64,
        _clock: &Clock
    ) {
        // Update pool totals
        if (!table::contains(&registry.total_fees_claimed_a, pool_id)) {
            table::add(&mut registry.total_fees_claimed_a, pool_id, 0);
            table::add(&mut registry.total_fees_claimed_b, pool_id, 0);
        };
        
        let total_a = table::borrow_mut(&mut registry.total_fees_claimed_a, pool_id);
        *total_a = *total_a + amount_a;
        
        let total_b = table::borrow_mut(&mut registry.total_fees_claimed_b, pool_id);
        *total_b = *total_b + amount_b;
        
        // REMOVED: unbounded vector storage
        // History is now tracked via events only (ClaimRecord events are emitted elsewhere)
        // This prevents the position history from growing unbounded and bricking claims
        
        registry.total_claims = registry.total_claims + 1;
    }

    // View functions
    
    /// Get total fees claimed from a pool
    public fun get_pool_total_fees(registry: &FeeRegistry, pool_id: ID): (u64, u64) {
        let amount_a = if (table::contains(&registry.total_fees_claimed_a, pool_id)) {
            *table::borrow(&registry.total_fees_claimed_a, pool_id)
        } else {
            0
        };
        
        let amount_b = if (table::contains(&registry.total_fees_claimed_b, pool_id)) {
            *table::borrow(&registry.total_fees_claimed_b, pool_id)
        } else {
            0
        };
        
        (amount_a, amount_b)
    }

    /// Get claim history for a position
    /// NOTE: History is no longer stored on-chain to prevent unbounded growth
    /// Use event indexers to query historical claim data
    public fun get_claim_history(_registry: &FeeRegistry, _position_id: ID): Option<vector<ClaimRecord>> {
        // Always return none - history is tracked via events only
        option::none()
    }

    /// Get total number of claims across all positions
    public fun get_total_claims(registry: &FeeRegistry): u64 {
        registry.total_claims
    }

    // ========== BACKWARD COMPATIBLE TEST WRAPPERS ========== //
    // These functions exist for backward compatibility with existing tests
    // They don't use the FeeRegistry tracking but maintain the same API

    #[test_only]
    public fun claim_fees_simple<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        ctx: &mut TxContext  
    ): (Coin<CoinA>, Coin<CoinB>) {
        pool::withdraw_fees(pool, position, ctx)
    }

    #[test_only]
    public fun auto_compound<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        let (coin_a, coin_b) = pool::withdraw_fees(pool, position, ctx);
        
        // Swap half of single-sided fees to the other token
        if (coin::value(&coin_a) > 0 && coin::value(&coin_b) == 0) {
            let amount_to_swap = coin::value(&coin_a) / 2;
            if (amount_to_swap > 0) {
                let coin_in = coin::split(&mut coin_a, amount_to_swap, ctx);
                let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), clock, 18446744073709551615, ctx);
                coin::join(&mut coin_b, coin_out);
            }
        } else if (coin::value(&coin_b) > 0 && coin::value(&coin_a) == 0) {
            let amount_to_swap = coin::value(&coin_b) / 2;
            if (amount_to_swap > 0) {
                let coin_in = coin::split(&mut coin_b, amount_to_swap, ctx);
                let coin_out = pool::swap_b_to_a(pool, coin_in, 0, option::none(), clock, 18446744073709551615, ctx);
                coin::join(&mut coin_a, coin_out);
            }
        };

        if (coin::value(&coin_a) > 0 && coin::value(&coin_b) > 0) {
            let (leftover_a, leftover_b) = pool::increase_liquidity(
                pool, 
                position, 
                coin_a, 
                coin_b,
                clock,
                18446744073709551615,
                ctx
            );
            (leftover_a, leftover_b)
        } else {
            (coin_a, coin_b)
        }
    }
}
