module sui_amm::limit_orders {
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use std::option::{Self};
    use std::vector;
    
    use sui_amm::pool::{Self, LiquidityPool};

    // Error codes
    const EOrderExpired: u64 = 0;
    const EInvalidPrice: u64 = 1;
    const EUnauthorized: u64 = 2;
    const EPriceNotMet: u64 = 3;
    const EInsufficientBalance: u64 = 4;

    /// A limit order that executes when target price is reached
    struct LimitOrder<phantom CoinIn, phantom CoinOut> has key, store {
        id: UID,
        owner: address,
        pool_id: ID,
        pool_type: u8, // 0 = regular, 1 = stable
        is_a_to_b: bool,
        deposit: Balance<CoinIn>,
        target_price: u64,  // Scaled by 1e9 (amount_in per 1 amount_out)
        min_amount_out: u64,
        expiry: u64, // timestamp_ms
        created_at: u64,
    }

    /// Registry for all active limit orders
    struct OrderRegistry has key {
        id: UID,
        active_orders: Table<ID, address>, // order_id -> owner
        user_orders: Table<address, vector<ID>>, // owner -> order_ids
        pool_orders: Table<ID, vector<ID>>, // pool_id -> order_ids
        total_orders: u64,
    }

    // Events
    struct OrderCreated has copy, drop {
        order_id: ID,
        owner: address,
        pool_id: ID,
        is_a_to_b: bool,
        amount_in: u64,
        target_price: u64,
        expiry: u64,
    }

    struct OrderExecuted has copy, drop {
        order_id: ID,
        executor: address,
        amount_in: u64,
        amount_out: u64,
        execution_price: u64,
    }

    struct OrderCancelled has copy, drop {
        order_id: ID,
        owner: address,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(OrderRegistry {
            id: object::new(ctx),
            active_orders: table::new(ctx),
            user_orders: table::new(ctx),
            pool_orders: table::new(ctx),
            total_orders: 0,
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Create a limit order for regular pool
    public fun create_limit_order<CoinIn, CoinOut>(
        registry: &mut OrderRegistry,
        pool_id: ID,
        coin_in: Coin<CoinIn>,
        target_price: u64,
        min_amount_out: u64,
        clock: &Clock,
        expiry: u64,
        ctx: &mut TxContext
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
            is_a_to_b: true, // determined by generic types
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
            is_a_to_b: true,
            amount_in,
            target_price,
            expiry,
        });

        transfer::share_object(order);
        order_id
    }

    ///Execute a limit order (anyone can call if conditions met)
    public fun execute_limit_order<CoinA, CoinB>(
        registry: &mut OrderRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        order: LimitOrder<CoinA, CoinB>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<CoinB> {
        // Validate order is for this pool
        assert!(order.pool_id == object::id(pool), EPriceNotMet);
        assert!(order.pool_type == 0, EPriceNotMet);
        
        // Check expiry
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= order.expiry, EOrderExpired);

        // Check if target price is met
        let (reserve_a, reserve_b) = pool::get_reserves(pool);
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128) as u64);
        
        // For buy orders: current_price <= target_price (better or equal)
        assert!(current_price <= order.target_price, EPriceNotMet);

        // Unpack order first to extract deposit
        let LimitOrder { 
            id, 
            owner,
            pool_id,
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

        // Unregister order
        let order_id = object::id_from_address(owner);  // Use owner address for ID
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
            executor: tx_context::sender(ctx),
            amount_in,
            amount_out,
            execution_price,
        });

        // Delete the order's UID
        object::delete(id);

        coin_out
    }

    /// Cancel limit order (owner only)
    public fun cancel_limit_order<CoinIn, CoinOut>(
        registry: &mut OrderRegistry,
        order: LimitOrder<CoinIn, CoinOut>,
        ctx: &mut TxContext
    ): Coin<CoinIn> {
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

    public fun get_pool_orders(registry: &OrderRegistry, pool_id: ID): vector<ID> {
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
