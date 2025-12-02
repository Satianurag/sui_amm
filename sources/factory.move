/// Central registry for creating and managing liquidity pools
///
/// The factory manages pool creation, fee tier configuration, and pool discovery.
/// It maintains indexes for efficient lookup by token pair, fee tier, and individual tokens.
///
/// # Pool Creation Fee
/// Requires a configurable creation fee (default 5 SUI) to prevent DoS attacks.
/// Without this barrier, attackers could spam pool creation to:
/// - Exhaust on-chain storage
/// - Degrade indexer performance
/// - Make pool discovery impractical
///
/// The fee is burned (sent to @0x0) rather than collected, providing economic
/// deterrence without extracting value from users.
///
/// # Supported Pool Types
/// - Standard pools: Constant product (x*y=k) for volatile pairs
/// - Stable pools: StableSwap invariant for stable pairs
///
/// # Indexing
/// Pools are indexed by:
/// - Token pair + fee tier + pool type (primary lookup)
/// - Fee tier (for discovering all pools with a specific fee)
/// - Individual tokens (for discovering all pools containing a token)
/// - Sequential ID (for enumeration)
module sui_amm::factory {
    use sui::table;
    use std::type_name;
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
    const EInvalidCreationFee: u64 = 2;
    const ETooManyPools: u64 = 3;
    const ETooManyPoolsPerToken: u64 = 4;
    const EFeeTierTooHigh: u64 = 5;
    const EGlobalPoolLimitReached: u64 = 6;

    /// Pool creation fee configuration
    const DEFAULT_POOL_CREATION_FEE: u64 = 5_000_000_000;
    const MIN_POOL_CREATION_FEE: u64 = 0;
    const MAX_POOL_CREATION_FEE: u64 = 100_000_000_000;
    
    /// DoS protection limits
    const MAX_POOLS_UNBOUNDED: u64 = 100;
    const MAX_POOLS_PER_TOKEN: u64 = 500;
    const DEFAULT_MAX_GLOBAL_POOLS: u64 = 50000;
    
    /// Fee tier validation
    const DEFAULT_MAX_FEE_TIER_BPS: u64 = 10000;

    /// Standard fee tiers in basis points
    const FEE_TIER_LOW: u64 = 5;
    const FEE_TIER_MEDIUM: u64 = 30;
    const FEE_TIER_HIGH: u64 = 100;

    /// Protocol fee defaults (percentage of swap fees)
    const DEFAULT_PROTOCOL_FEE_BPS: u64 = 100;
    const DEFAULT_STABLE_PROTOCOL_FEE_BPS: u64 = 100;

    public struct PoolKey has copy, drop, store {
        type_a: type_name::TypeName,
        type_b: type_name::TypeName,
        fee_percent: u64,
        is_stable: bool,
    }

    /// Pool creation event
    ///
    /// Emitted when a new pool is created. Includes comprehensive data for indexers.
    public struct PoolCreated has copy, drop {
        pool_id: object::ID,
        creator: address,
        type_a: type_name::TypeName,
        type_b: type_name::TypeName,
        fee_percent: u64,
        is_stable: bool,
        creation_fee_paid: u64,
        initial_liquidity_a: u64,
        initial_liquidity_b: u64,
        statistics_initialized: bool,
    }

    /// Pool registry state
    ///
    /// Maintains multiple indexes for efficient pool discovery:
    /// - Primary: token pair + fee + type -> pool ID
    /// - By fee tier: fee -> list of pool IDs
    /// - By token: token -> list of pool IDs containing that token
    /// - Sequential: index -> pool ID (for enumeration)
    ///
    /// # Data Structure Choices
    /// - `pools_by_fee` uses VecMap (O(n) lookup) instead of Table because fee tier
    ///   counts are typically small (< 20). VecMap is faster than Table for small n.
    /// - If fee tiers exceed 20, consider migrating to Table<u64, vector<ID>>
    public struct PoolRegistry has key {
        id: object::UID,
        pools: table::Table<PoolKey, object::ID>,
        pool_to_key: table::Table<object::ID, PoolKey>,
        pool_index: table::Table<u64, object::ID>,
        pool_count: u64,
        pools_by_fee: vec_map::VecMap<u64, vector<object::ID>>,
        allowed_fee_tiers: vec_set::VecSet<u64>,
        token_to_pools: table::Table<type_name::TypeName, vector<object::ID>>,
        pool_creation_fee: u64,
        max_fee_tier_bps: u64,
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
            max_global_pools: DEFAULT_MAX_GLOBAL_POOLS,    // Default maximum number of pools to prevent DoS
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }

    /// Check if a fee tier is allowed
    ///
    /// # Returns
    /// - true if the fee tier is in the allowed set
    public fun is_valid_fee_tier(registry: &PoolRegistry, fee_percent: u64): bool {
        vec_set::contains(&registry.allowed_fee_tiers, &fee_percent)
    }

    /// Add a new fee tier (admin only)
    ///
    /// Allows pools to be created with this fee tier. The fee tier must not exceed
    /// the maximum configured in the registry.
    ///
    /// # Parameters
    /// - `fee_tier`: Fee in basis points (e.g., 30 = 0.30%)
    ///
    /// # Aborts
    /// - `EFeeTierTooHigh`: If fee_tier exceeds max_fee_tier_bps
    public fun add_fee_tier(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        fee_tier: u64
    ) {
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

    /// Create a constant product pool with initial liquidity
    ///
    /// Atomically creates a pool and adds initial liquidity. This prevents empty pools
    /// and ensures the pool is immediately usable.
    ///
    /// # DoS Protection
    /// - Requires creation fee (burned to @0x0)
    /// - Enforces global pool count limit
    /// - Limits pools per token to prevent index bloat
    /// - Requires minimum fee tier
    ///
    /// # Parameters
    /// - `fee_percent`: Swap fee in basis points
    /// - `creator_fee_percent`: Creator fee as percentage of swap fees
    /// - `creation_fee`: SUI coin for creation fee (burned)
    ///
    /// # Returns
    /// - LP position NFT
    /// - Refund of unused CoinA
    /// - Refund of unused CoinB
    ///
    /// # Aborts
    /// - `EInvalidFeeTier`: If fee tier not allowed or below minimum
    /// - `EGlobalPoolLimitReached`: If max pools reached
    /// - `EInvalidCreationFee`: If creation fee insufficient
    /// - `EPoolAlreadyExists`: If pool with same parameters exists
    /// - `ETooManyPoolsPerToken`: If token already in too many pools
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
        // Validate fee tier
        assert!(fee_percent >= pool::min_fee_bps(), EInvalidFeeTier);
        assert!(is_valid_fee_tier(registry, fee_percent), EInvalidFeeTier);
        
        // Enforce global pool limit
        assert!(registry.pool_count < registry.max_global_pools, EGlobalPoolLimitReached);
        
        // Validate and burn creation fee
        let creation_fee_amount = registry.pool_creation_fee;
        assert!(coin::value(&creation_fee) >= creation_fee_amount, EInvalidCreationFee);
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

        // Create pool with default protocol fee
        let mut pool = pool::create_pool<CoinA, CoinB>(
            fee_percent,
            DEFAULT_PROTOCOL_FEE_BPS,
            creator_fee_percent,
            ctx
        );
        let pool_id = object::id(&pool);
        
        // Add to primary index
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

        // Add to token indexes with DoS protection
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
        let deadline_ms = 18446744073709551615;
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool, 
            coin_a, 
            coin_b, 
            1,
            clock,
            deadline_ms,
            ctx
        );

        pool::share(pool);
        
        (position, refund_a, refund_b)
    }

    /// Create a StableSwap pool with initial liquidity
    ///
    /// Similar to create_pool but creates a StableSwap pool optimized for stable pairs.
    /// Requires an amplification coefficient (amp) parameter.
    ///
    /// # Parameters
    /// - `amp`: Amplification coefficient (controls curve flatness)
    ///
    /// # Returns
    /// - LP position NFT
    /// - Refund of unused CoinA
    /// - Refund of unused CoinB
    ///
    /// See create_pool for full parameter and error documentation.
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
        // Validate fee tier
        assert!(fee_percent >= stable_pool::min_fee_bps(), EInvalidFeeTier);
        assert!(is_valid_fee_tier(registry, fee_percent), EInvalidFeeTier);
        
        // Enforce global pool limit
        assert!(registry.pool_count < registry.max_global_pools, EGlobalPoolLimitReached);
        
        // Validate and burn creation fee
        let creation_fee_amount = registry.pool_creation_fee;
        assert!(coin::value(&creation_fee) >= creation_fee_amount, EInvalidCreationFee);
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
        let deadline_ms = 18446744073709551615;
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

    /// Get all pool IDs (limited to prevent gas exhaustion)
    ///
    /// Returns all pool IDs up to MAX_POOLS_UNBOUNDED (100).
    /// For larger registries, use get_all_pools_paginated instead.
    ///
    /// # Aborts
    /// - `ETooManyPools`: If pool count exceeds 100
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

    /// Get pool IDs with pagination
    ///
    /// Prevents gas exhaustion for large registries by returning pools in batches.
    /// Recommended limit: 50-100 pools per query for optimal gas usage.
    ///
    /// # Parameters
    /// - `start_index`: Starting index (0-based)
    /// - `limit`: Maximum number of pools to return
    ///
    /// # Returns
    /// - Vector of pool IDs from start_index to min(start_index + limit, pool_count)
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

    /// Check if pools_by_fee should migrate from VecMap to Table
    ///
    /// VecMap has O(n) lookup but is efficient for small n (< 20).
    /// Table has O(1) lookup but higher storage overhead.
    ///
    /// # Returns
    /// - true if fee tier count exceeds 20 (migration recommended)
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
        let len = vector::length(keys);
        
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

    /// Set pool creation fee (admin only)
    ///
    /// # Parameters
    /// - `new_fee`: Fee in MIST (1 SUI = 1e9 MIST)
    ///
    /// # Aborts
    /// - `EInvalidCreationFee`: If fee outside valid range [0, 100 SUI]
    public fun set_pool_creation_fee(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        new_fee: u64
    ) {
        assert!(new_fee >= MIN_POOL_CREATION_FEE && new_fee <= MAX_POOL_CREATION_FEE, EInvalidCreationFee);
        registry.pool_creation_fee = new_fee;
    }

    /// Get current pool creation fee
    ///
    /// # Returns
    /// - Fee in MIST
    public fun get_pool_creation_fee(registry: &PoolRegistry): u64 {
        registry.pool_creation_fee
    }

    /// Set maximum fee tier (admin only)
    ///
    /// Allows for future extensibility if higher fee tiers are needed.
    ///
    /// # Parameters
    /// - `new_max_bps`: Maximum fee in basis points
    public fun set_max_fee_tier_bps(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        new_max_bps: u64
    ) {
        registry.max_fee_tier_bps = new_max_bps;
    }

    /// Get current maximum fee tier
    ///
    /// # Returns
    /// - Maximum fee in basis points
    public fun get_max_fee_tier_bps(registry: &PoolRegistry): u64 {
        registry.max_fee_tier_bps
    }

    /// Set maximum global pool count (admin only)
    ///
    /// Prevents unbounded registry growth and protects against DoS.
    ///
    /// # Parameters
    /// - `new_max`: New maximum pool count
    ///
    /// # Aborts
    /// - `ETooManyPools`: If new_max < current pool count
    public fun set_max_global_pools(
        _admin: &admin::AdminCap,
        registry: &mut PoolRegistry,
        new_max: u64
    ) {
        assert!(new_max >= registry.pool_count, ETooManyPools);
        registry.max_global_pools = new_max;
    }

    /// Get maximum global pool count
    public fun get_max_global_pools(registry: &PoolRegistry): u64 {
        registry.max_global_pools
    }

    /// Get remaining pool capacity
    ///
    /// # Returns
    /// - Number of pools that can be created before hitting limit
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
