module sui_amm::factory {
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use std::type_name::{Self, TypeName};
    use std::option::{Self, Option};
    use std::vector;
    use sui::event;
    use sui::vec_map::{Self, VecMap};
    
    use sui_amm::pool;
    use sui_amm::stable_pool;
    use sui_amm::position;

    // Error codes
    const EPoolAlreadyExists: u64 = 0;
    const EInvalidFeeTier: u64 = 1;

    // Standard fee tiers in basis points
    const FEE_TIER_LOW: u64 = 5;      // 0.05%
    const FEE_TIER_MEDIUM: u64 = 30;  // 0.30%
    const FEE_TIER_HIGH: u64 = 100;   // 1.00%

    // Protocol defaults (basis points out of the swap fee amount)
    const DEFAULT_PROTOCOL_FEE_BPS: u64 = 100; // 1%
    const DEFAULT_STABLE_PROTOCOL_FEE_BPS: u64 = 100; // 1%

    struct PoolKey has copy, drop, store {
        type_a: TypeName,
        type_b: TypeName,
        fee_percent: u64,
        is_stable: bool,
    }

    struct PoolCreated has copy, drop {
        pool_id: ID,
        type_a: TypeName,
        type_b: TypeName,
        fee_percent: u64,
        is_stable: bool,
    }

    struct PoolRegistry has key {
        id: UID,
        pools: Table<PoolKey, ID>,
        pool_to_key: Table<ID, PoolKey>, // Reverse lookup
        pool_index: Table<u64, ID>, // Scalable registry of pool IDs
        pool_count: u64,
        pools_by_fee: VecMap<u64, vector<ID>>, // Fee tier -> pool IDs
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(PoolRegistry {
            id: object::new(ctx),
            pools: table::new(ctx),
            pool_to_key: table::new(ctx),
            pool_index: table::new(ctx),
            pool_count: 0,
            pools_by_fee: vec_map::empty(),
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Validate that fee tier is one of the standard tiers
    public fun is_valid_fee_tier(fee_percent: u64): bool {
        fee_percent == FEE_TIER_LOW || 
        fee_percent == FEE_TIER_MEDIUM || 
        fee_percent == FEE_TIER_HIGH
    }

    /// Create a constant product AMM pool with initial liquidity
    /// Returns (position, refund_a, refund_b) for composability in PTBs
    public fun create_pool<CoinA, CoinB>(
        registry: &mut PoolRegistry,
        fee_percent: u64,
        creator_fee_percent: u64,
        coin_a: sui::coin::Coin<CoinA>,
        coin_b: sui::coin::Coin<CoinB>,
        ctx: &mut TxContext
    ): (position::LPPosition, sui::coin::Coin<CoinA>, sui::coin::Coin<CoinB>) {
        assert!(is_valid_fee_tier(fee_percent), EInvalidFeeTier);
        
        let type_a = type_name::with_original_ids<CoinA>();
        let type_b = type_name::with_original_ids<CoinB>();
        
        let key = PoolKey {
            type_a,
            type_b,
            fee_percent,
            is_stable: false,
        };

        assert!(!table::contains(&registry.pools, key), EPoolAlreadyExists);

        // Configure protocol fee via immutable defaults to prevent griefing attacks
        let pool = pool::create_pool<CoinA, CoinB>(
            fee_percent,
            DEFAULT_PROTOCOL_FEE_BPS,
            creator_fee_percent,
            ctx
        );
        let pool_id = object::id(&pool);
        
        // Add pool to registry
        table::add(&mut registry.pools, key, pool_id);
        table::add(&mut registry.pool_to_key, pool_id, key);
        table::add(&mut registry.pool_index, registry.pool_count, pool_id);
        registry.pool_count = registry.pool_count + 1;
        
        // Add to fee tier index
        if (!vec_map::contains(&registry.pools_by_fee, &fee_percent)) {
            vec_map::insert(&mut registry.pools_by_fee, fee_percent, vector::empty());
        };
        let fee_pools = vec_map::get_mut(&mut registry.pools_by_fee, &fee_percent);
        vector::push_back(fee_pools, pool_id);

        event::emit(PoolCreated {
            pool_id,
            type_a,
            type_b,
            fee_percent,
            is_stable: false,
        });

        // Add initial liquidity
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool, 
            coin_a, 
            coin_b, 
            1, // Min liquidity 1 to prevent zero liquidity positions
            ctx
        );

        pool::share(pool);
        
        // Return objects for composability
        (position, refund_a, refund_b)
    }

    /// Create a stable swap pool with initial liquidity
    /// Returns (position, refund_a, refund_b) for composability in PTBs
    public fun create_stable_pool<CoinA, CoinB>(
        registry: &mut PoolRegistry,
        fee_percent: u64,
        amp: u64,
        coin_a: sui::coin::Coin<CoinA>,
        coin_b: sui::coin::Coin<CoinB>,
        ctx: &mut TxContext
    ): (position::LPPosition, sui::coin::Coin<CoinA>, sui::coin::Coin<CoinB>) {
        assert!(is_valid_fee_tier(fee_percent), EInvalidFeeTier);
        
        let type_a = type_name::with_original_ids<CoinA>();
        let type_b = type_name::with_original_ids<CoinB>();
        
        let key = PoolKey {
            type_a,
            type_b,
            fee_percent,
            is_stable: true,
        };

        assert!(!table::contains(&registry.pools, key), EPoolAlreadyExists);

        let pool = stable_pool::create_pool<CoinA, CoinB>(
            fee_percent,
            DEFAULT_STABLE_PROTOCOL_FEE_BPS,
            amp,
            ctx
        );
        let pool_id = object::id(&pool);
        
        table::add(&mut registry.pools, key, pool_id);
        table::add(&mut registry.pool_to_key, pool_id, key);
        table::add(&mut registry.pool_index, registry.pool_count, pool_id);
        registry.pool_count = registry.pool_count + 1;
        
        // Add to fee tier index
        if (!vec_map::contains(&registry.pools_by_fee, &fee_percent)) {
            vec_map::insert(&mut registry.pools_by_fee, fee_percent, vector::empty());
        };
        let fee_pools = vec_map::get_mut(&mut registry.pools_by_fee, &fee_percent);
        vector::push_back(fee_pools, pool_id);

        event::emit(PoolCreated {
            pool_id,
            type_a,
            type_b,
            fee_percent,
            is_stable: true,
        });

        // Add initial liquidity
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool, 
            coin_a, 
            coin_b, 
            1, 
            ctx
        );

        stable_pool::share(pool);
        
        // Return objects for composability
        (position, refund_a, refund_b)
    }

    /// Get pool ID for a specific token pair and fee tier
    public fun get_pool_id<CoinA, CoinB>(
        registry: &PoolRegistry,
        fee_percent: u64,
        is_stable: bool
    ): Option<ID> {
        let key = PoolKey {
            type_a: type_name::with_original_ids<CoinA>(),
            type_b: type_name::with_original_ids<CoinB>(),
            fee_percent,
            is_stable
        };

        if (table::contains(&registry.pools, key)) {
            option::some(*table::borrow(&registry.pools, key))
        } else {
            option::none()
        }
    }

    /// Get total number of pools
    public fun get_pool_count(registry: &PoolRegistry): u64 {
        registry.pool_count
    }

    /// Get all pool IDs (O(n) snapshot assembled on demand)
    public fun get_all_pools(registry: &PoolRegistry): vector<ID> {
        let result = vector::empty<ID>();
        let i = 0;
        while (i < registry.pool_count) {
            let id_ref = table::borrow(&registry.pool_index, i);
            vector::push_back(&mut result, *id_ref);
            i = i + 1;
        };
        result
    }

    /// Get pools for a specific fee tier
    public fun get_pools_by_fee_tier(registry: &PoolRegistry, fee_percent: u64): vector<ID> {
        if (vec_map::contains(&registry.pools_by_fee, &fee_percent)) {
            *vec_map::get(&registry.pools_by_fee, &fee_percent)
        } else {
            vector::empty()
        }
    }

    /// Reverse lookup: Get pool key from pool ID
    public fun get_pool_key(registry: &PoolRegistry, pool_id: ID): Option<PoolKey> {
        if (table::contains(&registry.pool_to_key, pool_id)) {
            option::some(*table::borrow(&registry.pool_to_key, pool_id))
        } else {
            option::none()
        }
    }

    /// Get all pools for a specific token pair (checking all standard fee tiers + stable)
    public fun get_pools_for_pair<CoinA, CoinB>(registry: &PoolRegistry): vector<ID> {
        let pools = vector::empty<ID>();
        
        // Check low fee
        let id_low = get_pool_id<CoinA, CoinB>(registry, FEE_TIER_LOW, false);
        if (option::is_some(&id_low)) {
            vector::push_back(&mut pools, *option::borrow(&id_low));
        };
        let id_low_stable = get_pool_id<CoinA, CoinB>(registry, FEE_TIER_LOW, true);
        if (option::is_some(&id_low_stable)) {
            vector::push_back(&mut pools, *option::borrow(&id_low_stable));
        };

        // Check medium fee
        let id_med = get_pool_id<CoinA, CoinB>(registry, FEE_TIER_MEDIUM, false);
        if (option::is_some(&id_med)) {
            vector::push_back(&mut pools, *option::borrow(&id_med));
        };
        let id_med_stable = get_pool_id<CoinA, CoinB>(registry, FEE_TIER_MEDIUM, true);
        if (option::is_some(&id_med_stable)) {
            vector::push_back(&mut pools, *option::borrow(&id_med_stable));
        };

        // Check high fee
        let id_high = get_pool_id<CoinA, CoinB>(registry, FEE_TIER_HIGH, false);
        if (option::is_some(&id_high)) {
            vector::push_back(&mut pools, *option::borrow(&id_high));
        };
        let id_high_stable = get_pool_id<CoinA, CoinB>(registry, FEE_TIER_HIGH, true);
        if (option::is_some(&id_high_stable)) {
            vector::push_back(&mut pools, *option::borrow(&id_high_stable));
        };
        
        pools
    }

    // Getter functions for standard fee tiers
    public fun fee_tier_low(): u64 { FEE_TIER_LOW }
    public fun fee_tier_medium(): u64 { FEE_TIER_MEDIUM }
    public fun fee_tier_high(): u64 { FEE_TIER_HIGH }

    /// Get total number of pools in registry
    public fun pool_count(registry: &PoolRegistry): u64 {
        registry.pool_count
    }

    /// Get all pool IDs (for enumeration)
    public fun all_pool_ids(registry: &PoolRegistry): vector<ID> {
        get_all_pools(registry)
    }
}
