#[test_only]
module sui_amm::test_factory {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock;
    use std::type_name;
    
    use sui_amm::factory::{Self, PoolRegistry};
    use sui_amm::swap_history::{Self, StatisticsRegistry};
    use sui_amm::admin::{Self, AdminCap};
    use sui_amm::test_utils::{Self, USDC, USDT, DAI};
    use sui_amm::fixtures;
    use sui_amm::position::LPPosition;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Pool Creation with Fee Burning and Registry Update
    // Requirement 6.1: Pool creation burns fee and updates registry
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_pool_creation_with_fee_burning() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        // Initialize modules
        factory::test_init(ts::ctx(&mut scenario));
        swap_history::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        let mut stats_registry = ts::take_shared<StatisticsRegistry>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Get creation fee amount
        let creation_fee = factory::get_pool_creation_fee(&registry);
        let initial_pool_count = factory::get_pool_count(&registry);
        
        // Create pool with fee
        let fee_coin = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = factory::create_pool<USDC, USDT>(
            &mut registry,
            &mut stats_registry,
            30, // fee_percent
            0,  // creator_fee_percent
            coin_a,
            coin_b,
            fee_coin,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify pool was added to registry
        let new_pool_count = factory::get_pool_count(&registry);
        assert!(new_pool_count == initial_pool_count + 1, 0);
        
        // Verify pool can be found
        let pool_id_opt = factory::get_pool_id<USDC, USDT>(&registry, 30, false);
        assert!(option::is_some(&pool_id_opt), 1);
        
        // Clean up
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        transfer::public_transfer(position, admin);
        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(stats_registry);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Invalid Fee Tier Rejection
    // Requirement 6.2: EInvalidFeeTier error for invalid fee tiers
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = factory::EInvalidFeeTier)]
    fun test_invalid_fee_tier_rejection() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        factory::test_init(ts::ctx(&mut scenario));
        swap_history::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        let mut stats_registry = ts::take_shared<StatisticsRegistry>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let creation_fee = factory::get_pool_creation_fee(&registry);
        let fee_coin = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        // Try to create pool with invalid fee tier (999 is not in allowed tiers)
        let (position, refund_a, refund_b) = factory::create_pool<USDC, USDT>(
            &mut registry,
            &mut stats_registry,
            999, // Invalid fee tier
            0,
            coin_a,
            coin_b,
            fee_coin,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        transfer::public_transfer(position, admin);
        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(stats_registry);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Duplicate Pool Prevention
    // Requirement 6.3: EPoolAlreadyExists error for duplicate pools
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = factory::EPoolAlreadyExists)]
    fun test_duplicate_pool_prevention() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        factory::test_init(ts::ctx(&mut scenario));
        swap_history::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        let mut stats_registry = ts::take_shared<StatisticsRegistry>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let creation_fee = factory::get_pool_creation_fee(&registry);
        
        // Create first pool
        let fee_coin1 = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
        let coin_a1 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position1, refund_a1, refund_b1) = factory::create_pool<USDC, USDT>(
            &mut registry,
            &mut stats_registry,
            30,
            0,
            coin_a1,
            coin_b1,
            fee_coin1,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        transfer::public_transfer(position1, admin);
        
        // Try to create duplicate pool (same tokens, fee tier, type)
        let fee_coin2 = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
        let coin_a2 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position2, refund_a2, refund_b2) = factory::create_pool<USDC, USDT>(
            &mut registry,
            &mut stats_registry,
            30, // Same fee tier
            0,
            coin_a2,
            coin_b2,
            fee_coin2,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        transfer::public_transfer(position2, admin);
        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(stats_registry);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Max Global Pools Limit Enforcement
    // Requirement 6.4: EGlobalPoolLimitReached error when limit is reached
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = factory::EGlobalPoolLimitReached)]
    fun test_max_global_pools_limit() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        factory::test_init(ts::ctx(&mut scenario));
        swap_history::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        let mut stats_registry = ts::take_shared<StatisticsRegistry>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set max global pools to 1 for testing
        factory::set_max_global_pools(&admin_cap, &mut registry, 1);
        
        let creation_fee = factory::get_pool_creation_fee(&registry);
        
        // Create first pool (should succeed)
        let fee_coin1 = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
        let coin_a1 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position1, refund_a1, refund_b1) = factory::create_pool<USDC, USDT>(
            &mut registry,
            &mut stats_registry,
            30,
            0,
            coin_a1,
            coin_b1,
            fee_coin1,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        transfer::public_transfer(position1, admin);
        
        // Try to create second pool (should fail with EGlobalPoolLimitReached)
        let fee_coin2 = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
        let coin_a2 = test_utils::mint_coin<DAI>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position2, refund_a2, refund_b2) = factory::create_pool<DAI, USDC>(
            &mut registry,
            &mut stats_registry,
            30,
            0,
            coin_a2,
            coin_b2,
            fee_coin2,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        transfer::public_transfer(position2, admin);
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(stats_registry);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Get Pools for Pair Returns All Pools
    // Requirement 6.5: get_pools_for_pair() returns all pools for token pair
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_get_pools_for_pair() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        factory::test_init(ts::ctx(&mut scenario));
        swap_history::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        let mut stats_registry = ts::take_shared<StatisticsRegistry>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let creation_fee = factory::get_pool_creation_fee(&registry);
        
        // Create multiple pools for USDC/USDT pair with different fee tiers
        let fee_tiers = vector[5u64, 30u64, 100u64];
        let mut i = 0;
        let mut positions = vector::empty<LPPosition>();
        
        while (i < vector::length(&fee_tiers)) {
            let fee_tier = *vector::borrow(&fee_tiers, i);
            
            let fee_coin = coin::mint_for_testing<sui::sui::SUI>(creation_fee, ts::ctx(&mut scenario));
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
            let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_pool<USDC, USDT>(
                &mut registry,
                &mut stats_registry,
                fee_tier,
                0,
                coin_a,
                coin_b,
                fee_coin,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            vector::push_back(&mut positions, position);
            
            i = i + 1;
        };
        
        // Get all pools for USDC/USDT pair
        let pools = factory::get_pools_for_pair<USDC, USDT>(&registry);
        
        // Should have 3 pools (one for each fee tier)
        assert!(vector::length(&pools) == 3, 0);
        
        // Clean up
        while (!vector::is_empty(&positions)) {
            let position = vector::pop_back(&mut positions);
            transfer::public_transfer(position, admin);
        };
        vector::destroy_empty(positions);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
        ts::return_shared(stats_registry);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Pagination Correctness
    // Requirement 6.6: get_all_pools_paginated() pagination works correctly
    // Note: Using add_pool_for_testing helper for performance optimization
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_pagination_correctness() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        factory::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        
        // Use test helper to add pools for pagination testing (faster than full pool creation)
        let type_a = type_name::with_original_ids<USDC>();
        let type_b = type_name::with_original_ids<USDT>();
        let type_c = type_name::with_original_ids<DAI>();
        
        // Add 5 pools using the lightweight test helper
        // Pool 1: USDC/USDT with 5 bps
        factory::add_pool_for_testing(&mut registry, 5, false, type_a, type_b, 0, ts::ctx(&mut scenario));
        // Pool 2: USDC/USDT with 30 bps
        factory::add_pool_for_testing(&mut registry, 30, false, type_a, type_b, 0, ts::ctx(&mut scenario));
        // Pool 3: USDC/USDT with 100 bps
        factory::add_pool_for_testing(&mut registry, 100, false, type_a, type_b, 0, ts::ctx(&mut scenario));
        // Pool 4: DAI/USDC with 30 bps
        factory::add_pool_for_testing(&mut registry, 30, false, type_c, type_a, 0, ts::ctx(&mut scenario));
        // Pool 5: DAI/USDT with 30 bps
        factory::add_pool_for_testing(&mut registry, 30, false, type_c, type_b, 0, ts::ctx(&mut scenario));
        
        // Test pagination
        let page1 = factory::get_all_pools_paginated(&registry, 0, 2);
        assert!(vector::length(&page1) == 2, 0);
        
        let page2 = factory::get_all_pools_paginated(&registry, 2, 2);
        assert!(vector::length(&page2) == 2, 1);
        
        let page3 = factory::get_all_pools_paginated(&registry, 4, 2);
        assert!(vector::length(&page3) == 1, 2);
        
        // Test out of bounds
        let page4 = factory::get_all_pools_paginated(&registry, 10, 2);
        assert!(vector::length(&page4) == 0, 3);
        
        ts::return_shared(registry);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: MAX_POOLS_PER_TOKEN Limit Enforcement
    // Requirement 6.7: MAX_POOLS_PER_TOKEN (500) limit is enforced
    // Note: Using reduced limit (15) to stay within gas limits while still
    // validating the limit enforcement logic
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = factory::ETooManyPoolsPerToken)]
    fun test_max_pools_per_token_limit() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        factory::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut registry = ts::take_shared<PoolRegistry>(&scenario);
        
        // Use test helper to add pools up to the limit
        let type_a = type_name::with_original_ids<USDC>();
        let type_b = type_name::with_original_ids<USDT>();
        
        // Use reduced limit (15) to stay within gas limits while still
        // validating the limit enforcement logic works correctly
        let test_limit = 15u64;
        
        // Add pools up to the limit
        let mut i = 0;
        while (i < test_limit) {
            factory::add_pool_for_testing(
                &mut registry,
                30 + i, // Different fee tiers to avoid duplicates
                false,
                type_a,
                type_b,
                test_limit, // Use reduced limit for testing
                ts::ctx(&mut scenario)
            );
            i = i + 1;
        };
        
        // Try to add one more (should fail with ETooManyPoolsPerToken)
        factory::add_pool_for_testing(
            &mut registry,
            9999,
            false,
            type_a,
            type_b,
            test_limit,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        ts::return_shared(registry);
        ts::end(scenario);
    }
}
