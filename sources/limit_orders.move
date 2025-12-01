module sui_amm::limit_orders {
    use sui::object;
    use sui::table;
    use sui::coin;
    use sui::balance;
    use sui::tx_context;
    use sui::transfer;
    use sui::event;
    use sui::clock;
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};

    // Error codes
    const EOrderExpired: u64 = 0;
    const EInvalidPrice: u64 = 1;
    const EUnauthorized: u64 = 2;
    const EPriceNotMet: u64 = 3;
    const EInsufficientBalance: u64 = 4;
    const EInsufficientOutput: u64 = 5;

    /// A limit order that executes when target price is reached
    public struct LimitOrder<phantom CoinIn, phantom CoinOut> has key, store {
        id: object::UID,
        owner: address,
        pool_id: object::ID,
        pool_type: u8, // 0 = regular, 1 = stable
        is_a_to_b: bool,
        deposit: balance::Balance<CoinIn>,
        target_price: u64,  // Scaled by 1e9 (amount_in per 1 amount_out)
        min_amount_out: u64,
        expiry: u64, // timestamp_ms
        created_at: u64,
    }

    /// Registry for all active limit orders
    public struct OrderRegistry has key {
        id: object::UID,
        active_orders: table::Table<ID, address>, // order_id -> owner
        user_orders: table::Table<address, vector<ID>>, // owner -> order_ids
        pool_orders: table::Table<ID, vector<ID>>, // pool_id -> order_ids
        total_orders: u64,
    }

    // Events
    public struct OrderCreated has copy, drop {
        order_id: object::ID,
        owner: address,
        pool_id: object::ID,
        is_a_to_b: bool,
        amount_in: u64,
        target_price: u64,
        expiry: u64,
    }

    public struct OrderExecuted has copy, drop {
        order_id: object::ID,
        owner: address,
        executor: address,
        amount_in: u64,
        amount_out: u64,
        execution_price: u64,
    }

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

    /// Create a limit order for regular pool
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
            pool_type: 0, // regular
            is_a_to_b,
            deposit: coin::into_balance(coin_in),
            target_price,
            min_amount_out,
            expiry,
            created_at: clock::timestamp_ms(clock),
        };

        let order_id = object::id(&order);
        let owner = tx_context::sender(ctx);

        // Register order
        table::add(&mut registry.active_orders, order_id, owner);
        
        if (!table::contains(&registry.user_orders, owner)) {
            table::add(&mut registry.user_orders, owner, vector::empty());
        };
        let user_list = table::borrow_mut(&mut registry.user_orders, owner);
        vector::push_back(user_list, order_id);

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

    /// Execute a limit order A to B (anyone can call if conditions met)
    public fun execute_limit_order_a_to_b<CoinA, CoinB>(
        registry: &mut OrderRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        order: LimitOrder<CoinA, CoinB>,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ) {
        // Validate order is for this pool
        assert!(order.pool_id == object::id(pool), EPriceNotMet);
        assert!(order.pool_type == 0, EPriceNotMet);
        assert!(order.is_a_to_b == true, EPriceNotMet);
        
        // Check expiry
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= order.expiry, EOrderExpired);

        // Check if target price is met
        let (reserve_a, reserve_b) = (pool::get_reserves(pool));
        // FIX [V1]: Clarified price semantics for limit orders
        // 
        // For A->B swap (selling A to buy B):
        // - target_price = MAXIMUM amount of A user is willing to pay per 1 B (scaled by 1e9)
        // - current_price = reserve_a / reserve_b = how much A needed for 1 B at spot
        // - Execute when: current_price <= target_price (user gets favorable or equal rate)
        //
        // Example: User sets target_price = 1.05e9 (willing to pay up to 1.05 A per B)
        //          Current price = 1.0e9 (1 A per B)
        //          1.0 <= 1.05 → Execute (user pays less than max)
        //
        // This is a "sell limit order" - sell A when price of B is low enough
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128) as u64);
        
        // Execute when current rate is at or better than user's limit
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

        // Slippage revalidation: Calculate expected output at execution time
        let fee_percent = pool::get_fee_percent(pool);
        let fee_amount = (amount_in * fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        let expected_output = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        // Validate that expected output meets minimum requirement
        assert!(expected_output >= min_amount_out, EInsufficientOutput);

        // Execute swap
        let deadline = current_time + 60000; // 60 second deadline
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

        // Transfer output to order owner (not executor)
        transfer::public_transfer(coin_out, owner);

        // Unregister order
        table::remove(&mut registry.active_orders, order_id);
        
        // Remove from user orders
        let user_list = table::borrow_mut(&mut registry.user_orders, owner);
        let (found, idx) = vector::index_of(user_list, &order_id);
        if (found) {
            vector::remove(user_list, idx);
        };

        // Remove from pool orders
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

        // Delete the order's UID
        object::delete(id);
    }

    /// Execute a limit order B to A (anyone can call if conditions met)
    public fun execute_limit_order_b_to_a<CoinA, CoinB>(
        registry: &mut OrderRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        order: LimitOrder<CoinB, CoinA>,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ) {
        // Validate order is for this pool
        assert!(order.pool_id == object::id(pool), EPriceNotMet);
        assert!(order.pool_type == 0, EPriceNotMet);
        assert!(order.is_a_to_b == false, EPriceNotMet);
        
        // Check expiry
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= order.expiry, EOrderExpired);

        // Check if target price is met
        let (reserve_a, reserve_b) = (pool::get_reserves(pool));
        
        // FIX [V1]: Clarified price semantics for limit orders
        //
        // For B->A swap (selling B to buy A):
        // - target_price = MAXIMUM amount of B user is willing to pay per 1 A (scaled by 1e9)
        // - current_price = reserve_b / reserve_a = how much B needed for 1 A at spot
        // - Execute when: current_price <= target_price (user gets favorable or equal rate)
        //
        // Example: User sets target_price = 0.95e9 (willing to pay up to 0.95 B per A)
        //          Current price = 0.9e9 (0.9 B per A)
        //          0.9 <= 0.95 → Execute (user pays less than max)
        //
        // This is a "sell limit order" - sell B when price of A is low enough
        let current_price = ((reserve_b as u128) * 1_000_000_000 / (reserve_a as u128) as u64);
        
        // Execute when current rate is at or better than user's limit
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

        // Slippage revalidation: Calculate expected output at execution time
        let fee_percent = pool::get_fee_percent(pool);
        let fee_amount = (amount_in * fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        let expected_output = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        // Validate that expected output meets minimum requirement
        assert!(expected_output >= min_amount_out, EInsufficientOutput);

        // Execute swap
        let deadline = current_time + 60000; // 60 second deadline
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

        // Transfer output to order owner (not executor)
        transfer::public_transfer(coin_out, owner);

        // Unregister order
        table::remove(&mut registry.active_orders, order_id);
        
        // Remove from user orders
        let user_list = table::borrow_mut(&mut registry.user_orders, owner);
        let (found, idx) = vector::index_of(user_list, &order_id);
        if (found) {
            vector::remove(user_list, idx);
        };

        // Remove from pool orders
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

        // Delete the order's UID
        object::delete(id);
    }

    /// Cancel limit order (owner only)
    public fun cancel_limit_order<CoinIn, CoinOut>(
        registry: &mut OrderRegistry,
        order: LimitOrder<CoinIn, CoinOut>,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<CoinIn> {
        assert!(order.owner == tx_context::sender(ctx), EUnauthorized);

        let order_id = object::id(&order);
        
        // Unregister order
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

        // Return deposited coins
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

    // View functions
    public fun get_user_orders(registry: &OrderRegistry, user: address): vector<ID> {
        if (table::contains(&registry.user_orders, user)) {
            *table::borrow(&registry.user_orders, user)
        } else {
            vector::empty()
        }
    }

    public fun get_pool_orders(registry: &OrderRegistry, pool_id: object::ID): vector<ID> {
        if (table::contains(&registry.pool_orders, pool_id)) {
            *table::borrow(&registry.pool_orders, pool_id)
        } else {
            vector::empty()
        }
    }

    public fun total_orders(registry: &OrderRegistry): u64 {
        registry.total_orders
    }
}
