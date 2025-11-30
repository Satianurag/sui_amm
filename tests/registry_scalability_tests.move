/// Test suite for registry scalability and DoS protection
/// Tests V2 (MAX_POOLS_UNBOUNDED), P1 (scalability), V4 (token-to-pools DoS), S2 (vector bloat)
#[test_only]
module sui_amm::registry_scalability_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use std::vector;
    use sui_amm::factory::{Self, PoolRegistry};
    use sui_amm::admin;

    // Test coins
    struct COINA has drop {}
    struct COINB has drop {}
    struct COINC has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xCAFE;

    fun setup_test(): Scenario {
        let scenario = ts::begin(ADMIN);
       {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };
        scenario
    }


    /// FIX [V2, P1]: Test that get_all_pools() aborts when pool count exceeds MAX_POOLS_UNBOUNDED (100)
    #[test]
    #[expected_failure(abort_code = sui_amm::factory::ETooManyPools)]
    fun test_get_all_pools_fails_above_limit() {
        let scenario = setup_test();
        
        // Create 101 pools (above the MAX_POOLS_UNBOUNDED limit of 100)
        // Create 101 pools (above the MAX_POOLS_UNBOUNDED limit of 100)
        // Create 101 pools (above the MAX_POOLS_UNBOUNDED limit of 100)
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            
            let i = 0;
            while (i < 101) {
                // Use test helper to avoid expensive pool creation
                factory::add_pool_for_testing(
                    &mut registry,
                    i + 10,
                    false,
                    std::type_name::with_defining_ids<COINA>(),
                    std::type_name::with_defining_ids<COINB>(),
                    0, // Default limit
                    ctx
                );
                i = i + 1;
            };
            
            ts::return_shared(registry);
        };

        // This should abort with ETooManyPools
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let _ = factory::get_all_pools(&registry); // Should fail
            ts::return_shared(registry);
        };
        
        ts::end(scenario);
    }

    /// FIX [V2, P1]: Test that pagination works correctly for large registries
    #[test]
    fun test_pagination_with_many_pools() {
        let scenario = setup_test();
        
        // Create 150 pools
        // Create 150 pools
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            
            let i = 0;
            while (i < 150) {
                factory::add_pool_for_testing(
                    &mut registry,
                    i + 10,
                    false,
                    std::type_name::with_defining_ids<COINA>(),
                    std::type_name::with_defining_ids<COINB>(),
                    0, // Default limit
                    ctx
                );
                i = i + 1;
            };
            
            ts::return_shared(registry);
        };

        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            
            // Test pagination
            let first_page = factory::get_all_pools_paginated(&registry, 0, 50);
            assert!(vector::length(&first_page) == 50, 0);
            
            let second_page = factory::get_all_pools_paginated(&registry, 50, 50);
            assert!(vector::length(&second_page) == 50, 1);
            
            let third_page = factory::get_all_pools_paginated(&registry, 100, 100);
            assert!(vector::length(&third_page) == 50, 2); // Only 50 remaining
            
            ts::return_shared(registry);
        };
        
        ts::end(scenario);
    }

    /// FIX [V4, S2]: Test DoS protection - token cannot be in more than MAX_POOLS_PER_TOKEN (500) pools
    #[test]
    #[expected_failure(abort_code = sui_amm::factory::ETooManyPoolsPerToken)]
    fun test_dos_protection_max_pools_per_token() {
        let scenario = setup_test();
        
        // Create 501 pools all containing COINA (should fail at 501st)
        // Create 501 pools all containing COINA (should fail at 501st)
        // Create 51 pools all containing COINA (should fail at 51st)
        let i = 0;
        while (i <= 50) {
            ts::next_tx(&mut scenario, USER);
            {
                let registry = ts::take_shared<PoolRegistry>(&scenario);
                let ctx = ts::ctx(&mut scenario);
                
                if (i % 2 == 0) {
                    factory::add_pool_for_testing(
                        &mut registry,
                        i + 10,
                        false,
                        std::type_name::with_defining_ids<COINA>(),
                        std::type_name::with_defining_ids<COINB>(),
                        50, // Test limit
                        ctx
                    );
                } else {
                    factory::add_pool_for_testing(
                        &mut registry,
                        i + 10,
                        false,
                        std::type_name::with_defining_ids<COINA>(),
                        std::type_name::with_defining_ids<COINC>(),
                        50, // Test limit
                        ctx
                    );
                };
                
                ts::return_shared(registry);
            };
            i = i + 1;
        };
        
        ts::end(scenario);
    }

    /// FIX [L2]: Test pagination edge cases
    #[test]
    fun test_pagination_edge_cases() {
        let scenario = setup_test();
        
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            
            // Test empty registry
            let empty_result = factory::get_all_pools_paginated(&registry, 0, 10);
            assert!(vector::length(&empty_result) == 0, 0);
            
            // Test start_index beyond count
            let beyond_result = factory::get_all_pools_paginated(&registry, 100, 10);
            assert!(vector::length(&beyond_result) == 0, 1);
            
            ts::return_shared(registry);
        };
        
        ts::end(scenario);
    }

    /// FIX [V1]: Test governable pool creation fee
    #[test]
    fun test_governable_pool_creation_fee() {
        let scenario = setup_test();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<admin::AdminCap>(&scenario);
            
            // Check default fee
            let default_fee = factory::get_pool_creation_fee(&registry);
            assert!(default_fee == 5_000_000_000, 0); // 5 SUI
            
            // Set to 0 (free pool creation)
            factory::set_pool_creation_fee(&admin_cap, &mut registry, 0);
            assert!(factory::get_pool_creation_fee(&registry) == 0, 1);
            
            // Set to max
            factory::set_pool_creation_fee(&admin_cap, &mut registry, 100_000_000_000);
            assert!(factory::get_pool_creation_fee(&registry) == 100_000_000_000, 2);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };
        
        ts::end(scenario);
    }

    /// FIX [V5]: Test governable max fee tier
    #[test]
    fun test_governable_max_fee_tier() {
        let scenario = setup_test();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<admin::AdminCap>(&scenario);
            
            // Check default
            let default_max = factory::get_max_fee_tier_bps(&registry);
            assert!(default_max == 10000, 0); // 100%
            
            // Allow fees >100% for special pools
            factory::set_max_fee_tier_bps(&admin_cap, &mut registry, 50000); // 500%
            assert!(factory::get_max_fee_tier_bps(&registry) == 50000, 1);
            
            // Add a custom 200% fee tier
            factory::add_fee_tier(&admin_cap, &mut registry, 20000);
            assert!(factory::is_valid_fee_tier(&registry, 20000), 2);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };
        
        ts::end(scenario);
    }
}
