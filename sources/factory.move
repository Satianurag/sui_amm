/// Module: factory
/// Description: Central registry for creating and managing liquidity pools.
/// Handles pool creation (Standard and Stable), fee tier validation, and pool lookup.
/// 
/// SECURITY NOTE [S4]: Pool Creation Fee (Default 5 SUI, Governable)
/// This implementation requires a configurable pool creation fee to prevent DoS attacks via spam pool creation.
/// This is an INTENTIONAL DEVIATION from the PRD specification for security hardening.
/// Rationale: Without a creation barrier, attackers could create millions of pools to:
///   - Exhaust on-chain storage
///   - Degrade indexer performance
///   - Make pool discovery impractical
/// The fee is burned (sent to @0x0), providing economic deterrence without extracting value.
module sui_amm::factory {
    use sui::object;
    use sui::table;
    use sui::tx_context;
    use std::type_name;
    use std::option;
    use sui::event;
    use sui::vec_map;
    use sui::vec_set;
    use sui::clock;
    
    use sui_amm::pool;
    use sui_amm::stable_pool;
    use sui_amm::position;
    use sui_amm::swap_history;

    use sui_amm::admin;
    use sui::sui;
    use sui::coin;

    // Error codes
    const EPoolAlreadyExists: u64 = 0;
    const EInvalidFeeTier: u64 = 1;
    const EInvalidCreationFee: u64 = 2; // NEW: For DoS protection
    const ETooManyPools: u64 = 3; // FIX [P1]: For unbounded iteration protection
    const ETooManyPoolsPerToken: u64 = 4; // FIX [V4]: DoS protection for reverse lookup
    const EFeeTierTooHigh: u64 = 5; // FIX [V5]: Extensible fee tier validation
    const EGlobalPoolLimitReached: u64 = 6; // FIX [P2-17.2]: Global pool count limit

    // Constants
    // FIX [V1]: Default pool creation fee (governance-adjustable)
    const DEFAULT_POOL_CREATION_FEE: u64 = 5_000_000_000; // 5 SUI (reduced from 10 for better UX)
    const MIN_POOL_CREATION_FEE: u64 = 0; // Can be disabled via governance
    const MAX_POOL_CREATION_FEE: u64 = 100_000_000_000; // 100 SUI max
    
    const MAX_POOLS_UNBOUNDED: u64 = 100; // FIX [P1]: Limit for non-paginated get_all_pools
    
    // FIX [V4]: DoS protection - max pools per token
    const MAX_POOLS_PER_TOKEN: u64 = 500;
    
    // FIX [P2-17.2]: Global pool count limit to prevent registry bloat and DoS
    // This prevents unbounded growth that could degrade indexer performance
    // Set to 50,000 pools (reasonable for production AMM with multiple fee tiers)
    const DEFAULT_MAX_GLOBAL_POOLS: u64 = 50000;
    
    // FIX [V5]: Extensible fee tier validation (governance-adjustable)
    const DEFAULT_MAX_FEE_TIER_BPS: u64 = 10000; // 100% default, but can be increased

    // Standard fee tiers in basis points
    const FEE_TIER_LOW: u64 = 5;      // 0.05%
    const FEE_TIER_MEDIUM: u64 = 30;  // 0.30%
    const FEE_TIER_HIGH: u64 = 100;   // 1.00%

    // Protocol defaults (basis points out of the swap fee amount)
    const DEFAULT_PROTOCOL_FEE_BPS: u64 = 100; // 1%
    const DEFAULT_STABLE_PROTOCOL_FEE_BPS: u64 = 100; // 1%

    public struct PoolKey has copy, drop, store {
        type_a: type_name::TypeName,
        type_b: type_name::TypeName,
        fee_percent: u64,
        is_stable: bool,
    }

    // FIX [M1]: Enhanced event schema with creator and timestamp for indexers
    public struct PoolCreated has copy, drop {
        pool_id: object::ID,
        creator: address,  // NEW: For creator tracking
        type_a: type_name::TypeName,
        type_b: type_name::TypeName,
        fee_percent: u64,
        is_stable: bool,
        creation_fee_paid: u64,  // NEW: Transparency for fee tracking
        initial_liquidity_a: u64, // FIX [M1]: For indexer efficiency
        initial_liquidity_b: u64, // FIX [M1]: For indexer efficiency
        statistics_initialized: bool, // NEW: Confirm statistics initialization
    }

    public struct PoolRegistry has key {
        id: object::UID,
        pools: table::Table<PoolKey, object::ID>,
        pool_to_key: table::Table<object::ID, PoolKey>, // Reverse lookup
        pool_index: table::Table<u64, object::ID>, // Scalable registry of pool IDs
        pool_count: u64,
        // FIX [P2-17.1]: VecMap is optimal for small fee tier counts (typically 3-10 tiers)
        // VecMap has O(n) lookup but with n < 20, this is faster than Table's storage overhead
        // Migration path: If fee tiers exceed 20, convert to Table<u64, vector<ID>>
        pools_by_fee: vec_map::VecMap<u64, vector<object::ID>>, // Fee tier -> pool IDs
        // FIX V3: Dynamic fee tiers
        allowed_fee_tiers: vec_set::VecSet<u64>,
        // FIX M4: Reverse lookup for efficient indexing
        token_to_pools: table::Table<type_name::TypeName, vector<object::ID>>,
        // FIX [V1]: Governable pool creation fee
        pool_creation_fee: u64,
        // FIX [V5]: Governable max fee tier
        max_fee_tier_bps: u64,
        // FIX [P2-17.2]: Global pool count limit (governance-adjustable)
        max_global_pools: u64,
    }

    public struct FeeTierAdded has copy, drop {
        fee_tier: u64,
    }

    public struct FeeTierRemoved has copy, drop {
        fee_tier: u64,
    }

    fun init(ctx: &mut tx_context::TxContext) {
        let mut allowed_fee_tiers = vec_set::empty();
        vec_set::insert(&mut allowed_fee_tiers, FEE_TIER_LOW);
        vec_set::insert(&mut allowed_fee_tiers, FEE_TIER_MEDIUM);
        vec_set::insert(&mut allowed_fee_tiers, FEE_TIER_HIGH);

        transfer::share_object(PoolRegistry {
            id: object::new(ctx),
            pools: table::new(ctx),
            pool_to_key: table::new(ctx),
            pool_index: table::new(ctx),
            pool_count: 0,
            pools_by_fee: vec_map::empty(),
            allowed_fee_tiers,
            token_to_pools: table::new(ctx),
            pool_creation_fee: DEFAULT_POOL_CREATION_FEE,  // FIX [V1]
            max_fee_tier_bps: DEFAULT_MAX_FEE_TIER_BPS,    // FIX [V5]
            max_global_pools: DEFAULT_MAX_GLOBAL_POOLS,    // FIX [P2-17.2]
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }

    /// Validate that fee tier is allowed
    public fun is_valid_fee_tier(registry: &PoolRegistry, fee_percent: u64): bool {
        vec_set::contains(&registry.allowed_fee_tiers, &fee_percent)
    }

    /// Admin function to add a new fee tier
    /// FIX [V5]: Now uses governance-adjustable max instead of hard-coded 10000
    public fun add_fee_tier(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        fee_tier: u64
    ) {
        // FIX [V5]: Use dynamic max instead of hard-coded constant
        assert!(fee_tier <= registry.max_fee_tier_bps, EFeeTierTooHigh);
        
        if (!vec_set::contains(&registry.allowed_fee_tiers, &fee_tier)) {
            vec_set::insert(&mut registry.allowed_fee_tiers, fee_tier);
            event::emit(FeeTierAdded { fee_tier });
        };
    }

    /// Admin function to remove a fee tier
    public fun remove_fee_tier(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        fee_tier: u64
    ) {
        if (vec_set::contains(&registry.allowed_fee_tiers, &fee_tier)) {
            vec_set::remove(&mut registry.allowed_fee_tiers, &fee_tier);
            event::emit(FeeTierRemoved { fee_tier });
        };
    }

    /// Create a constant product AMM pool with initial liquidity.
    /// This atomic creation and liquidity addition is an improvement over the spec's 2-step process,
    /// preventing the creation of empty pools and ensuring immediate usability.
    /// FIX [V1]: Now uses governance-adjustable creation fee instead of hard-coded constant
    /// FIX [V4]: Adds DoS protection for token-to-pools mapping with MAX_POOLS_PER_TOKEN limit
    /// Returns (position, refund_a, refund_b) for composability in PTBs
    public fun create_pool<CoinA, CoinB>(
        registry: &mut PoolRegistry,
        statistics_registry: &mut swap_history::StatisticsRegistry,
        fee_percent: u64,
        creator_fee_percent: u64,
        coin_a: coin::Coin<CoinA>,
        coin_b: coin::Coin<CoinB>,
        creation_fee: coin::Coin<sui::SUI>, // FIX [V1]: Uses dynamic fee from registry
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ): (position::LPPosition, coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // FIX [P2-16.6]: Enforce minimum fee validation to prevent zero-fee pools
        // Zero-fee pools would provide no incentive for LPs and could be exploited
        // Minimum fee of 1 basis point (0.01%) ensures meaningful LP returns
        assert!(fee_percent >= pool::min_fee_bps(), EInvalidFeeTier);
        assert!(is_valid_fee_tier(registry, fee_percent), EInvalidFeeTier);
        
        // FIX [P2-17.2]: Enforce global pool count limit to prevent registry bloat
        assert!(registry.pool_count < registry.max_global_pools, EGlobalPoolLimitReached);
        
        // FIX [V1]: Use dynamic creation fee instead of constant
        let creation_fee_amount = registry.pool_creation_fee;
        assert!(coin::value(&creation_fee) >= creation_fee_amount, EInvalidCreationFee);
        
        // Burn creation fee (transfer to 0x0)
        transfer::public_transfer(creation_fee, @0x0);
        
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
        let mut pool = pool::create_pool<CoinA, CoinB>(
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

        // FIX [V4]: Update reverse lookup with DoS protection
        if (!table::contains(&registry.token_to_pools, type_a)) {
            table::add(&mut registry.token_to_pools, type_a, vector::empty());
        };
        let token_a_pools = table::borrow_mut(&mut registry.token_to_pools, type_a);
        assert!(vector::length(token_a_pools) < MAX_POOLS_PER_TOKEN, ETooManyPoolsPerToken);
        vector::push_back(token_a_pools, pool_id);

        if (!table::contains(&registry.token_to_pools, type_b)) {
            table::add(&mut registry.token_to_pools, type_b, vector::empty());
        };
        let token_b_pools = table::borrow_mut(&mut registry.token_to_pools, type_b);
        assert!(vector::length(token_b_pools) < MAX_POOLS_PER_TOKEN, ETooManyPoolsPerToken);
        vector::push_back(token_b_pools, pool_id);

        // Initialize pool statistics
        swap_history::init_pool_statistics(statistics_registry, pool_id, ctx);

        // FIX [M1]: Enhanced event with creator and creation fee paid
        event::emit(PoolCreated {
            pool_id,
            creator: tx_context::sender(ctx),
            type_a,
            type_b,
            fee_percent,
            is_stable: false,
            creation_fee_paid: creation_fee_amount,
            initial_liquidity_a: coin::value(&coin_a),
            initial_liquidity_b: coin::value(&coin_b),
            statistics_initialized: true,
        });


        // Add initial liquidity
        let deadline_ms = 18446744073709551615; // Max u64 value
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool, 
            coin_a, 
            coin_b, 
            1, // Min liquidity 1 to prevent zero liquidity positions
            clock,
            deadline_ms,
            ctx
        );

        pool::share(pool);
        
        // Return objects for composability
        (position, refund_a, refund_b)
    }

    /// Create a stable swap pool with initial liquidity.
    /// This atomic creation and liquidity addition is an improvement over the spec's 2-step process,
    /// preventing the creation of empty pools and ensuring immediate usability.
    /// FIX [V1]: Now uses governance-adjustable creation fee
    /// FIX [V4]: Adds DoS protection for reverse lookups
    /// Returns (position, refund_a, refund_b) for composability in PTBs
    public fun create_stable_pool<CoinA, CoinB>(
        registry: &mut PoolRegistry,
        statistics_registry: &mut swap_history::StatisticsRegistry,
        fee_percent: u64,
        creator_fee_percent: u64,
        amp: u64,
        coin_a: coin::Coin<CoinA>,
        coin_b: coin::Coin<CoinB>,
        creation_fee: coin::Coin<sui::SUI>, // FIX [V1]: Uses dynamic fee from registry
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ): (position::LPPosition, coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // FIX [P2-16.6]: Enforce minimum fee validation to prevent zero-fee pools
        // Zero-fee pools would provide no incentive for LPs and could be exploited
        // Minimum fee of 1 basis point (0.01%) ensures meaningful LP returns
        assert!(fee_percent >= stable_pool::min_fee_bps(), EInvalidFeeTier);
        assert!(is_valid_fee_tier(registry, fee_percent), EInvalidFeeTier);
        
        // FIX [P2-17.2]: Enforce global pool count limit to prevent registry bloat
        assert!(registry.pool_count < registry.max_global_pools, EGlobalPoolLimitReached);
        
        // FIX [V1]: Use dynamic creation fee
        let creation_fee_amount = registry.pool_creation_fee;
        assert!(coin::value(&creation_fee) >= creation_fee_amount, EInvalidCreationFee);
        
        // Burn creation fee
        transfer::public_transfer(creation_fee, @0x0);
        
        let type_a = type_name::with_original_ids<CoinA>();
        let type_b = type_name::with_original_ids<CoinB>();
        
        let key = PoolKey {
            type_a,
            type_b,
            fee_percent,
            is_stable: true,
        };

        assert!(!table::contains(&registry.pools, key), EPoolAlreadyExists);

        let mut pool = stable_pool::create_pool<CoinA, CoinB>(
            fee_percent,
            DEFAULT_STABLE_PROTOCOL_FEE_BPS,
            creator_fee_percent,
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

        // FIX [V4]: DoS protection for reverse lookup
        if (!table::contains(&registry.token_to_pools, type_a)) {
            table::add(&mut registry.token_to_pools, type_a, vector::empty());
        };
        let token_a_pools = table::borrow_mut(&mut registry.token_to_pools, type_a);
        assert!(vector::length(token_a_pools) < MAX_POOLS_PER_TOKEN, ETooManyPoolsPerToken);
        vector::push_back(token_a_pools, pool_id);

        if (!table::contains(&registry.token_to_pools, type_b)) {
            table::add(&mut registry.token_to_pools, type_b, vector::empty());
        };
        let token_b_pools = table::borrow_mut(&mut registry.token_to_pools, type_b);
        assert!(vector::length(token_b_pools) < MAX_POOLS_PER_TOKEN, ETooManyPoolsPerToken);
        vector::push_back(token_b_pools, pool_id);

        // Initialize pool statistics
        swap_history::init_pool_statistics(statistics_registry, pool_id, ctx);

        // FIX [M1]: Enhanced event
        event::emit(PoolCreated {
            pool_id,
            creator: tx_context::sender(ctx),
            type_a,
            type_b,
            fee_percent,
            is_stable: true,
            creation_fee_paid: creation_fee_amount,
            initial_liquidity_a: coin::value(&coin_a),
            initial_liquidity_b: coin::value(&coin_b),
            statistics_initialized: true,
        });

        // Add initial liquidity
        let deadline_ms = 18446744073709551615; // Max u64
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool, 
            coin_a, 
            coin_b, 
            1,
            clock,
            deadline_ms,
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
    ): option::Option<ID> {
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
    /// FIX [P1]: Limited to 100 pools max to prevent gas exhaustion.
    /// Use get_all_pools_paginated instead for larger registries.
    public fun get_all_pools(registry: &PoolRegistry): vector<ID> {
        assert!(registry.pool_count <= MAX_POOLS_UNBOUNDED, ETooManyPools);
        
        let mut result = vector::empty<ID>();
        let mut i = 0;
        while (i < registry.pool_count) {
            let id_ref = table::borrow(&registry.pool_index, i);
            vector::push_back(&mut result, *id_ref);
            i = i + 1;
        };
        result
    }

    /// FIX [P2-17.1]: Efficient pagination for pool registry
    /// This prevents gas exhaustion when querying large registries
    /// Recommended limit: 50-100 pools per query for optimal gas usage
    public fun get_all_pools_paginated(
        registry: &PoolRegistry, 
        start_index: u64, 
        limit: u64
    ): vector<ID> {
        let mut result = vector::empty<ID>();
        let count = registry.pool_count;
        if (start_index >= count) {
            return result
        };
        
        let mut end_index = start_index + limit;
        if (end_index > count) {
            end_index = count;
        };
        
        let mut i = start_index;
        while (i < end_index) {
            let id_ref = table::borrow(&registry.pool_index, i);
            vector::push_back(&mut result, *id_ref);
            i = i + 1;
        };
        result
    }

    /// FIX [P2-17.1]: Check if VecMap migration to Table is recommended
    /// Returns true if the number of fee tiers exceeds the optimal threshold
    /// VecMap is O(n) but efficient for n < 20; Table is better for larger collections
    public fun should_migrate_pools_by_fee(registry: &PoolRegistry): bool {
        vec_set::length(&registry.allowed_fee_tiers) > 20
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
    public fun get_pool_key(registry: &PoolRegistry, pool_id: object::ID): option::Option<PoolKey> {
        if (table::contains(&registry.pool_to_key, pool_id)) {
            option::some(*table::borrow(&registry.pool_to_key, pool_id))
        } else {
            option::none()
        }
    }

    /// Get all pools for a specific token pair (checking all allowed fee tiers + stable)
    public fun get_pools_for_pair<CoinA, CoinB>(registry: &PoolRegistry): vector<ID> {
        let mut pools = vector::empty<ID>();
        
        // Iterate through all allowed fee tiers
        let keys = vec_set::keys(&registry.allowed_fee_tiers);
        let mut i = 0;
        let mut len = vector::length(keys);
        
        while (i < len) {
            let fee = *vector::borrow(keys, i);
            
            // Check regular pool
            let id_reg = get_pool_id<CoinA, CoinB>(registry, fee, false);
            if (option::is_some(&id_reg)) {
                vector::push_back(&mut pools, *option::borrow(&id_reg));
            };
            
            // Check stable pool
            let id_stable = get_pool_id<CoinA, CoinB>(registry, fee, true);
            if (option::is_some(&id_stable)) {
                vector::push_back(&mut pools, *option::borrow(&id_stable));
            };
            
            i = i + 1;
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

    /// FIX M4: Get all pools containing a specific token
    public fun get_pools_for_token<CoinType>(registry: &PoolRegistry): vector<ID> {
        let type_name = type_name::with_original_ids<CoinType>();
        if (table::contains(&registry.token_to_pools, type_name)) {
            *table::borrow(&registry.token_to_pools, type_name)
        } else {
            vector::empty()
        }
    }

    // FIX [V1]: Governance functions for pool creation fee
    /// Admin function to set pool creation fee
    /// NOTE: Changed from friend to public for testability, but still protected by AdminCap
    public fun set_pool_creation_fee(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        new_fee: u64
    ) {
        assert!(new_fee >= MIN_POOL_CREATION_FEE && new_fee <= MAX_POOL_CREATION_FEE, EInvalidCreationFee);
        registry.pool_creation_fee = new_fee;
    }

    /// Get current pool creation fee
    public fun get_pool_creation_fee(registry: &PoolRegistry): u64 {
        registry.pool_creation_fee
    }

    // FIX [V5]: Governance functions for max fee tier
    /// Admin function to set max fee tier
    /// NOTE: Changed from friend to public for testability, but still protected by AdminCap
    public fun set_max_fee_tier_bps(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        new_max_bps: u64
    ) {
        // No upper limit - allow for future extensibility
        registry.max_fee_tier_bps = new_max_bps;
    }

    /// Get current max fee tier
    public fun get_max_fee_tier_bps(registry: &PoolRegistry): u64 {
        registry.max_fee_tier_bps  // FIX: Removed semicolon to return the value
    }

    // FIX [P2-17.2]: Governance functions for global pool limit
    /// Admin function to set maximum global pool count
    /// This prevents unbounded registry growth and protects against DoS
    public fun set_max_global_pools(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        new_max: u64
    ) {
        // Must be at least current pool count to avoid breaking existing pools
        assert!(new_max >= registry.pool_count, ETooManyPools);
        registry.max_global_pools = new_max;
    }

    /// Get current maximum global pool count
    public fun get_max_global_pools(registry: &PoolRegistry): u64 {
        registry.max_global_pools
    }

    /// Get remaining pool capacity before hitting global limit
    public fun get_remaining_pool_capacity(registry: &PoolRegistry): u64 {
        registry.max_global_pools - registry.pool_count
    }

    #[test_only]
    public fun add_pool_for_testing(
        registry: &mut PoolRegistry,
        fee_percent: u64,
        is_stable: bool,
        type_a: type_name::TypeName,
        type_b: type_name::TypeName,
        limit: u64,
        ctx: &mut tx_context::TxContext
    ) {
        let key = PoolKey {
            type_a,
            type_b,
            fee_percent,
            is_stable,
        };

        let max_pools = if (limit > 0) { limit } else { MAX_POOLS_PER_TOKEN };

        // Create a dummy ID for testing
        let pool_id = object::new(ctx);
        let id = object::uid_to_inner(&pool_id);
        object::delete(pool_id); // Clean up the UID

        table::add(&mut registry.pools, key, id);
        table::add(&mut registry.pool_to_key, id, key);
        table::add(&mut registry.pool_index, registry.pool_count, id);
        registry.pool_count = registry.pool_count + 1;
        
        // Skip pools_by_fee update for scalability testing to avoid O(N) vec_map costs
        // if (!vec_map::contains(&registry.pools_by_fee, &fee_percent)) {
        //     vec_map::insert(&mut registry.pools_by_fee, fee_percent, vector::empty());
        // };
        // let fee_pools = vec_map::get_mut(&mut registry.pools_by_fee, &fee_percent);
        // vector::push_back(fee_pools, id);

        if (!table::contains(&registry.token_to_pools, type_a)) {
            table::add(&mut registry.token_to_pools, type_a, vector::empty());
        };
        let token_a_pools = table::borrow_mut(&mut registry.token_to_pools, type_a);
        if (vector::length(token_a_pools) < max_pools) {
             vector::push_back(token_a_pools, id);
        } else {
            abort ETooManyPoolsPerToken
        };

        if (!table::contains(&registry.token_to_pools, type_b)) {
            table::add(&mut registry.token_to_pools, type_b, vector::empty());
        };
        let token_b_pools = table::borrow_mut(&mut registry.token_to_pools, type_b);
        if (vector::length(token_b_pools) < max_pools) {
             vector::push_back(token_b_pools, id);
        } else {
            abort ETooManyPoolsPerToken
        };
    }
}
