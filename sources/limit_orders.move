/// Limit order functionality for the AMM
///
/// This module implements limit orders that execute automatically when target prices are reached.
/// Orders are stored on-chain and can be executed by anyone when conditions are met, creating
/// a decentralized order matching system.
///
/// # Order Types
/// - A->B orders: Sell token A to buy token B when price is favorable
/// - B->A orders: Sell token B to buy token A when price is favorable
///
/// # Price Semantics
/// target_price represents the MAXIMUM amount of input token the user is willing to pay per
/// 1 unit of output token (scaled by 1e9). Orders execute when the current market price is
/// at or better than this limit.
///
/// # Execution Model
/// - Orders are permissionlessly executable by anyone when conditions are met
/// - Executors pay gas but receive no direct reward (incentivized by arbitrage opportunities)
/// - Output tokens are sent directly to the order owner, not the executor
/// - Orders automatically expire after their deadline to prevent stale orders
module sui_amm::limit_orders {
    use sui::table;
    use sui::coin;
    use sui::balance;
    use sui::event;
    use sui::clock;
    
    use sui_amm::pool::{Self, LiquidityPool};

    /// Order has expired and can no longer be executed
    const EOrderExpired: u64 = 0;
    /// Target price is invalid (must be > 0)
    const EInvalidPrice: u64 = 1;
    /// Caller is not authorized to perform this action
    const EUnauthorized: u64 = 2;
    /// Current market price does not meet the order's target price
    const EPriceNotMet: u64 = 3;
    /// Insufficient balance to create order
    const EInsufficientBalance: u64 = 4;
    /// Expected output is less than minimum required amount
    const EInsufficientOutput: u64 = 5;

    /// A limit order that executes when the target price is reached
    ///
    /// Orders hold deposited tokens and execute automatically when market conditions
    /// meet the specified price target. The order owner receives the output tokens
    /// upon execution.
    ///
    /// # Fields
    /// - `owner`: Address that created the order and will receive output tokens
    /// - `pool_id`: The liquidity pool this order targets
    /// - `pool_type`: Pool variant (0 = constant product, 1 = stable swap)
    /// - `is_a_to_b`: Swap direction (true = A->B, false = B->A)
    /// - `deposit`: Input tokens held by the order
    /// - `target_price`: Maximum price willing to pay (scaled by 1e9, amount_in per 1 amount_out)
    /// - `min_amount_out`: Minimum output tokens required (slippage protection)
    /// - `expiry`: Timestamp after which order cannot be executed
    /// - `created_at`: Order creation timestamp for tracking
    public struct LimitOrder<phantom CoinIn, phantom CoinOut> has key, store {
        id: object::UID,
        owner: address,
        pool_id: object::ID,
        pool_type: u8,
        is_a_to_b: bool,
        deposit: balance::Balance<CoinIn>,
        target_price: u64,
        min_amount_out: u64,
        expiry: u64,
        created_at: u64,
    }

    /// Global registry tracking all active limit orders
    ///
    /// Maintains multiple indexes to enable efficient order lookup by different criteria.
    /// This allows users to query their orders, pools to find relevant orders, and the
    /// system to track overall order activity.
    ///
    /// # Indexes
    /// - `active_orders`: Maps order ID to owner for ownership verification
    /// - `user_orders`: Maps user address to their order IDs for portfolio queries
    /// - `pool_orders`: Maps pool ID to order IDs for pool-specific order matching
    /// - `total_orders`: Cumulative count of all orders created (never decrements)
    public struct OrderRegistry has key {
        id: object::UID,
        active_orders: table::Table<ID, address>,
        user_orders: table::Table<address, vector<ID>>,
        pool_orders: table::Table<ID, vector<ID>>,
        total_orders: u64,
    }

    /// Emitted when a new limit order is created
    public struct OrderCreated has copy, drop {
        order_id: object::ID,
        owner: address,
        pool_id: object::ID,
        is_a_to_b: bool,
        amount_in: u64,
        target_price: u64,
        expiry: u64,
    }

    /// Emitted when a limit order is successfully executed
    ///
    /// Records both the executor (who paid gas) and owner (who receives output).
    /// The execution_price shows the actual price achieved, which may be better
    /// than the target_price.
    public struct OrderExecuted has copy, drop {
        order_id: object::ID,
        owner: address,
        executor: address,
        amount_in: u64,
        amount_out: u64,
        execution_price: u64,
    }

    /// Emitted when an order is cancelled by its owner
    public struct OrderCancelled has copy, drop {
        order_id: object::ID,
        owner: address,
    }

    fun init(ctx: &mut tx_context::TxContext) {
        transfer::share_object(OrderRegistry {
            id: object::new(ctx),
            active_orders: table::new(ctx),
            user_orders: table::new(ctx),
            pool_orders: table::new(ctx),
            total_orders: 0,
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }

    /// Create a limit order for a constant product pool
    ///
    /// Deposits input tokens and creates an order that will execute when the market
    /// price reaches the target price. The order can be executed by anyone once
    /// conditions are met.
    ///
    /// # Parameters
    /// - `registry`: Global order registry for tracking
    /// - `pool_id`: Target pool for this order
    /// - `is_a_to_b`: Swap direction (true = sell A for B, false = sell B for A)
    /// - `coin_in`: Input tokens to deposit
    /// - `target_price`: Maximum price willing to pay (scaled by 1e9)
    /// - `min_amount_out`: Minimum output required for slippage protection
    /// - `clock`: For timestamp validation
    /// - `expiry`: Deadline timestamp after which order cannot execute
    ///
    /// # Returns
    /// The ID of the created order
    ///
    /// # Aborts
    /// - `EInsufficientBalance`: If coin_in amount is 0
    /// - `EInvalidPrice`: If target_price is 0
    /// - `EOrderExpired`: If expiry is not in the future
    public fun create_limit_order<CoinIn, CoinOut>(
        registry: &mut OrderRegistry,
        pool_id: object::ID,
        is_a_to_b: bool,
        coin_in: coin::Coin<CoinIn>,
        target_price: u64,
        min_amount_out: u64,
        clock: &clock::Clock,
        expiry: u64,
        ctx: &mut tx_context::TxContext
    ): ID {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EInsufficientBalance);
        assert!(target_price > 0, EInvalidPrice);
        assert!(expiry > clock::timestamp_ms(clock), EOrderExpired);

        let order = LimitOrder<CoinIn, CoinOut> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            pool_id,
            pool_type: 0,
            is_a_to_b,
            deposit: coin::into_balance(coin_in),
            target_price,
            min_amount_out,
            expiry,
            created_at: clock::timestamp_ms(clock),
        };

        let order_id = object::id(&order);
        let owner = tx_context::sender(ctx);

        // Register order in all indexes for efficient lookup
        table::add(&mut registry.active_orders, order_id, owner);
        
        // Add to user's order list (create list if first order)
        if (!table::contains(&registry.user_orders, owner)) {
            table::add(&mut registry.user_orders, owner, vector::empty());
        };
        let user_list = table::borrow_mut(&mut registry.user_orders, owner);
        vector::push_back(user_list, order_id);

        // Add to pool's order list (create list if first order for this pool)
        if (!table::contains(&registry.pool_orders, pool_id)) {
            table::add(&mut registry.pool_orders, pool_id, vector::empty());
        };
        let pool_list = table::borrow_mut(&mut registry.pool_orders, pool_id);
        vector::push_back(pool_list, order_id);

        registry.total_orders = registry.total_orders + 1;

        event::emit(OrderCreated {
            order_id,
            owner,
            pool_id,
            is_a_to_b,
            amount_in,
            target_price,
            expiry,
        });

        transfer::share_object(order);
        order_id
    }

    /// Execute a limit order that swaps A to B
    ///
    /// This function can be called by anyone when the order's price conditions are met.
    /// The executor pays gas but the output tokens go to the order owner. This creates
    /// a permissionless order matching system.
    ///
    /// # Price Matching Logic
    /// For A->B swaps (selling A to buy B):
    /// - target_price = MAXIMUM amount of A user is willing to pay per 1 B (scaled by 1e9)
    /// - current_price = reserve_a / reserve_b = how much A needed for 1 B at current spot rate
    /// - Execution condition: current_price <= target_price (user gets favorable or equal rate)
    ///
    /// Example: User sets target_price = 1.05e9 (willing to pay up to 1.05 A per B)
    ///          Current price = 1.0e9 (1 A per B at spot)
    ///          Since 1.0 <= 1.05, order executes (user pays less than maximum)
    ///
    /// This implements a "sell limit order" - sell A when the price of B is favorable.
    ///
    /// # Parameters
    /// - `registry`: Order registry to update
    /// - `pool`: Target liquidity pool
    /// - `order`: The order to execute (consumed)
    /// - `clock`: For deadline validation
    ///
    /// # Aborts
    /// - `EPriceNotMet`: If order doesn't match pool or price conditions not met
    /// - `EOrderExpired`: If current time exceeds order expiry
    /// - `EInsufficientOutput`: If expected output is below minimum
    public fun execute_limit_order_a_to_b<CoinA, CoinB>(
        registry: &mut OrderRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        order: LimitOrder<CoinA, CoinB>,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ) {
        // Validate order matches this pool and direction
        assert!(order.pool_id == object::id(pool), EPriceNotMet);
        assert!(order.pool_type == 0, EPriceNotMet);
        assert!(order.is_a_to_b == true, EPriceNotMet);
        
        // Verify order has not expired
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= order.expiry, EOrderExpired);

        // Check if current market price meets the order's target price
        let (reserve_a, reserve_b) = (pool::get_reserves(pool));
        
        // Calculate current spot price: how much A is needed per 1 B
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128) as u64);
        
        // Execute only when current price is at or better than user's limit
        // (user pays less than or equal to their maximum acceptable price)
        assert!(current_price <= order.target_price, EPriceNotMet);

        let order_id = object::id(&order);
        let owner = order.owner;
        let pool_id = order.pool_id;

        // Unpack order
        let LimitOrder { 
            id, 
            owner: _,
            pool_id: _,
            pool_type: _,
            is_a_to_b: _,
            deposit,
            min_amount_out,
            target_price: _,
            expiry: _,
            created_at: _,
        } = order;

        let amount_in = balance::value(&deposit);
        let coin_in = coin::from_balance(deposit, ctx);

        // Revalidate slippage protection at execution time
        // Pool state may have changed since order creation, so we recalculate
        // the expected output and verify it still meets the minimum requirement
        let fee_percent = pool::get_fee_percent(pool);
        let fee_amount = (amount_in * fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        let expected_output = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        // Abort if expected output no longer meets minimum (protects against sandwich attacks)
        assert!(expected_output >= min_amount_out, EInsufficientOutput);

        // Execute the swap with a short deadline to prevent execution delays
        let deadline = current_time + 60000;
        let coin_out = pool::swap_a_to_b(
            pool, 
            coin_in, 
            min_amount_out,
            option::none(), 
            clock, 
            deadline, 
            ctx
        );

        let amount_out = coin::value(&coin_out);
        let execution_price = ((amount_in as u128) * 1_000_000_000 / (amount_out as u128) as u64);

        // Send output tokens to order owner, not the executor
        // This ensures the order creator receives their tokens regardless of who executes
        transfer::public_transfer(coin_out, owner);

        // Remove order from all registry indexes
        table::remove(&mut registry.active_orders, order_id);
        
        // Remove from user's order list
        let user_list = table::borrow_mut(&mut registry.user_orders, owner);
        let (found, idx) = vector::index_of(user_list, &order_id);
        if (found) {
            vector::remove(user_list, idx);
        };

        // Remove from pool's order list
        let pool_list = table::borrow_mut(&mut registry.pool_orders, pool_id);
        let (found2, idx2) = vector::index_of(pool_list, &order_id);
        if (found2) {
            vector::remove(pool_list, idx2);
        };

        event::emit(OrderExecuted {
            order_id,
            owner,
            executor: tx_context::sender(ctx),
            amount_in,
            amount_out,
            execution_price,
        });

        object::delete(id);
    }

    /// Execute a limit order that swaps B to A
    ///
    /// This function can be called by anyone when the order's price conditions are met.
    /// The executor pays gas but the output tokens go to the order owner.
    ///
    /// # Price Matching Logic
    /// For B->A swaps (selling B to buy A):
    /// - target_price = MAXIMUM amount of B user is willing to pay per 1 A (scaled by 1e9)
    /// - current_price = reserve_b / reserve_a = how much B needed for 1 A at current spot rate
    /// - Execution condition: current_price <= target_price (user gets favorable or equal rate)
    ///
    /// Example: User sets target_price = 0.95e9 (willing to pay up to 0.95 B per A)
    ///          Current price = 0.9e9 (0.9 B per A at spot)
    ///          Since 0.9 <= 0.95, order executes (user pays less than maximum)
    ///
    /// This implements a "sell limit order" - sell B when the price of A is favorable.
    ///
    /// # Parameters
    /// - `registry`: Order registry to update
    /// - `pool`: Target liquidity pool
    /// - `order`: The order to execute (consumed)
    /// - `clock`: For deadline validation
    ///
    /// # Aborts
    /// - `EPriceNotMet`: If order doesn't match pool or price conditions not met
    /// - `EOrderExpired`: If current time exceeds order expiry
    /// - `EInsufficientOutput`: If expected output is below minimum
    public fun execute_limit_order_b_to_a<CoinA, CoinB>(
        registry: &mut OrderRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        order: LimitOrder<CoinB, CoinA>,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ) {
        // Validate order matches this pool and direction
        assert!(order.pool_id == object::id(pool), EPriceNotMet);
        assert!(order.pool_type == 0, EPriceNotMet);
        assert!(order.is_a_to_b == false, EPriceNotMet);
        
        // Verify order has not expired
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= order.expiry, EOrderExpired);

        // Check if current market price meets the order's target price
        let (reserve_a, reserve_b) = (pool::get_reserves(pool));
        
        // Calculate current spot price: how much B is needed per 1 A
        let current_price = ((reserve_b as u128) * 1_000_000_000 / (reserve_a as u128) as u64);
        
        // Execute only when current price is at or better than user's limit
        // (user pays less than or equal to their maximum acceptable price)
        assert!(current_price <= order.target_price, EPriceNotMet);

        let order_id = object::id(&order);
        let owner = order.owner;
        let pool_id = order.pool_id;

        // Unpack order
        let LimitOrder { 
            id, 
            owner: _,
            pool_id: _,
            pool_type: _,
            is_a_to_b: _,
            deposit,
            min_amount_out,
            target_price: _,
            expiry: _,
            created_at: _,
        } = order;

        let amount_in = balance::value(&deposit);
        let coin_in = coin::from_balance(deposit, ctx);

        // Revalidate slippage protection at execution time
        // Pool state may have changed since order creation, so we recalculate
        // the expected output and verify it still meets the minimum requirement
        let fee_percent = pool::get_fee_percent(pool);
        let fee_amount = (amount_in * fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        let expected_output = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        // Abort if expected output no longer meets minimum (protects against sandwich attacks)
        assert!(expected_output >= min_amount_out, EInsufficientOutput);

        // Execute the swap with a short deadline to prevent execution delays
        let deadline = current_time + 60000;
        let coin_out = pool::swap_b_to_a(
            pool, 
            coin_in, 
            min_amount_out,
            option::none(), 
            clock, 
            deadline, 
            ctx
        );

        let amount_out = coin::value(&coin_out);
        let execution_price = ((amount_in as u128) * 1_000_000_000 / (amount_out as u128) as u64);

        // Send output tokens to order owner, not the executor
        // This ensures the order creator receives their tokens regardless of who executes
        transfer::public_transfer(coin_out, owner);

        // Remove order from all registry indexes
        table::remove(&mut registry.active_orders, order_id);
        
        // Remove from user's order list
        let user_list = table::borrow_mut(&mut registry.user_orders, owner);
        let (found, idx) = vector::index_of(user_list, &order_id);
        if (found) {
            vector::remove(user_list, idx);
        };

        // Remove from pool's order list
        let pool_list = table::borrow_mut(&mut registry.pool_orders, pool_id);
        let (found2, idx2) = vector::index_of(pool_list, &order_id);
        if (found2) {
            vector::remove(pool_list, idx2);
        };

        event::emit(OrderExecuted {
            order_id,
            owner,
            executor: tx_context::sender(ctx),
            amount_in,
            amount_out,
            execution_price,
        });

        object::delete(id);
    }

    /// Cancel a limit order and return deposited tokens
    ///
    /// Only the order owner can cancel their order. This allows users to retrieve
    /// their deposited tokens if market conditions change or they no longer want
    /// the order to execute.
    ///
    /// # Parameters
    /// - `registry`: Order registry to update
    /// - `order`: The order to cancel (consumed)
    ///
    /// # Returns
    /// The deposited input tokens
    ///
    /// # Aborts
    /// - `EUnauthorized`: If caller is not the order owner
    public fun cancel_limit_order<CoinIn, CoinOut>(
        registry: &mut OrderRegistry,
        order: LimitOrder<CoinIn, CoinOut>,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<CoinIn> {
        assert!(order.owner == tx_context::sender(ctx), EUnauthorized);

        let order_id = object::id(&order);
        
        // Remove order from all registry indexes
        table::remove(&mut registry.active_orders, order_id);
        
        let user_list = table::borrow_mut(&mut registry.user_orders, order.owner);
        let (found, idx) = vector::index_of(user_list, &order_id);
        if (found) {
            vector::remove(user_list, idx);
        };

        let pool_list = table::borrow_mut(&mut registry.pool_orders, order.pool_id);
        let (found2, idx2) = vector::index_of(pool_list, &order_id);
        if (found2) {
            vector::remove(pool_list, idx2);
        };

        event::emit(OrderCancelled {
            order_id,
            owner: order.owner,
        });

        // Unpack order and return deposited tokens to owner
        let LimitOrder { 
            id, 
            owner: _,
            pool_id: _,
            pool_type: _,
            is_a_to_b: _,
            deposit,
            target_price: _,
            min_amount_out: _,
            expiry: _,
            created_at: _,
        } = order;
        object::delete(id);

        coin::from_balance(deposit, ctx)
    }

    /// Get all order IDs for a specific user
    ///
    /// Returns an empty vector if the user has no orders.
    public fun get_user_orders(registry: &OrderRegistry, user: address): vector<ID> {
        if (table::contains(&registry.user_orders, user)) {
            *table::borrow(&registry.user_orders, user)
        } else {
            vector::empty()
        }
    }

    /// Get all order IDs for a specific pool
    ///
    /// Returns an empty vector if the pool has no orders.
    public fun get_pool_orders(registry: &OrderRegistry, pool_id: object::ID): vector<ID> {
        if (table::contains(&registry.pool_orders, pool_id)) {
            *table::borrow(&registry.pool_orders, pool_id)
        } else {
            vector::empty()
        }
    }

    /// Get the total number of orders ever created
    ///
    /// This is a cumulative count that never decreases, even when orders are
    /// executed or cancelled. Useful for tracking overall system activity.
    public fun total_orders(registry: &OrderRegistry): u64 {
        registry.total_orders
    }
}
