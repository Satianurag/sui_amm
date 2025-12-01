#[test_only]
module sui_amm::swap_history_tests {
    use sui::test_scenario::{Self};
    use sui::clock::{Self};
    use sui::object;
    
    use sui_amm::swap_history::{Self, UserSwapHistory, PoolStatistics, StatisticsRegistry};

    #[test]
    fun test_create_user_history() {
        let user = @0xA;
        let scenario_val = test_scenario::begin(user);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, user);
        {
            let ctx = test_scenario::ctx(scenario);
            let history = swap_history::create_user_history(ctx);
            
            assert!(swap_history::get_user_total_swaps(&history) == 0, 0);
            assert!(swap_history::get_user_total_volume(&history) == 0, 1);
            assert!(swap_history::get_user_total_fees(&history) == 0, 2);
            
            swap_history::destroy_user_history_for_testing(history);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_record_user_swap() {
        let user = @0xA;
        let scenario_val = test_scenario::begin(user);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, user);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let history = swap_history::create_user_history(ctx);
            
            // Create a dummy pool ID
            let pool_uid = object::new(ctx);
            let pool_id = object::uid_to_inner(&pool_uid);
            object::delete(pool_uid);
            
            // Record a swap
            swap_history::record_user_swap(
                &mut history,
                pool_id,
                true,  // is_a_to_b
                1000,  // amount_in
                990,   // amount_out
                10,    // fee_paid
                50,    // price_impact_bps
                &clock
            );
            
            assert!(swap_history::get_user_total_swaps(&history) == 1, 0);
            assert!(swap_history::get_user_total_volume(&history) == 1000, 1);
            assert!(swap_history::get_user_total_fees(&history) == 10, 2);
            
            // Record another swap
            swap_history::record_user_swap(
                &mut history,
                pool_id,
                false, // is_a_to_b
                2000,  // amount_in
                1980,  // amount_out
                20,    // fee_paid
                30,    // price_impact_bps
                &clock
            );
            
            assert!(swap_history::get_user_total_swaps(&history) == 2, 3);
            assert!(swap_history::get_user_total_volume(&history) == 3000, 4);
            assert!(swap_history::get_user_total_fees(&history) == 30, 5);
            
            clock::destroy_for_testing(clock);
            swap_history::destroy_user_history_for_testing(history);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_user_history_pagination() {
        let user = @0xA;
        let scenario_val = test_scenario::begin(user);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, user);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let history = swap_history::create_user_history(ctx);
            
            let pool_uid = object::new(ctx);
            let pool_id = object::uid_to_inner(&pool_uid);
            object::delete(pool_uid);
            
            // Record 10 swaps
            let i = 0;
            while (i < 10) {
                swap_history::record_user_swap(
                    &mut history,
                    pool_id,
                    true,
                    100 + i,
                    99 + i,
                    1,
                    10,
                    &clock
                );
                i = i + 1;
            };
            
            // Get paginated results
            let page1 = swap_history::get_user_swaps_paginated(&history, 0, 5);
            assert!(std::vector::length(&page1) == 5, 0);
            
            let page2 = swap_history::get_user_swaps_paginated(&history, 5, 5);
            assert!(std::vector::length(&page2) == 5, 1);
            
            let page3 = swap_history::get_user_swaps_paginated(&history, 10, 5);
            assert!(std::vector::length(&page3) == 0, 2);
            
            clock::destroy_for_testing(clock);
            swap_history::destroy_user_history_for_testing(history);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_pool_statistics_init() {
        let admin = @0xA;
        let scenario_val = test_scenario::begin(admin);
        let scenario = &mut scenario_val;
        
        // Initialize registry
        test_scenario::next_tx(scenario, admin);
        {
            let ctx = test_scenario::ctx(scenario);
            swap_history::test_init(ctx);
        };
        
        // Initialize pool statistics
        test_scenario::next_tx(scenario, admin);
        {
            let registry = test_scenario::take_shared<StatisticsRegistry>(scenario);
            let ctx = test_scenario::ctx(scenario);
            
            let pool_uid = object::new(ctx);
            let pool_id = object::uid_to_inner(&pool_uid);
            object::delete(pool_uid);
            
            swap_history::init_pool_statistics(&mut registry, pool_id, ctx);
            
            test_scenario::return_shared(registry);
        };
        
        // Verify pool statistics was created
        test_scenario::next_tx(scenario, admin);
        {
            let stats = test_scenario::take_shared<PoolStatistics>(scenario);
            
            assert!(swap_history::get_pool_total_swaps(&stats) == 0, 0);
            let (vol_a, vol_b) = swap_history::get_pool_total_volume(&stats);
            assert!(vol_a == 0 && vol_b == 0, 1);
            
            test_scenario::return_shared(stats);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_pool_statistics_recording() {
        let admin = @0xA;
        let scenario_val = test_scenario::begin(admin);
        let scenario = &mut scenario_val;
        
        // Initialize registry
        test_scenario::next_tx(scenario, admin);
        {
            let ctx = test_scenario::ctx(scenario);
            swap_history::test_init(ctx);
        };
        
        // Initialize pool statistics
        test_scenario::next_tx(scenario, admin);
        {
            let registry = test_scenario::take_shared<StatisticsRegistry>(scenario);
            let ctx = test_scenario::ctx(scenario);
            
            let pool_uid = object::new(ctx);
            let pool_id = object::uid_to_inner(&pool_uid);
            object::delete(pool_uid);
            
            swap_history::init_pool_statistics(&mut registry, pool_id, ctx);
            
            test_scenario::return_shared(registry);
        };
        
        // Record swaps
        test_scenario::next_tx(scenario, admin);
        {
            let stats = test_scenario::take_shared<PoolStatistics>(scenario);
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            // Record A->B swap
            swap_history::record_pool_swap(
                &mut stats,
                true,  // is_a_to_b
                1000,  // amount_in
                990,   // amount_out
                10,    // fee_paid
                50,    // price_impact_bps
                &clock
            );
            
            // Record B->A swap
            swap_history::record_pool_swap(
                &mut stats,
                false, // is_a_to_b
                2000,  // amount_in
                1980,  // amount_out
                20,    // fee_paid
                30,    // price_impact_bps
                &clock
            );
            
            assert!(swap_history::get_pool_total_swaps(&stats) == 2, 0);
            
            let (vol_a, vol_b) = swap_history::get_pool_total_volume(&stats);
            assert!(vol_a == 1000, 1);
            assert!(vol_b == 2000, 2);
            
            let (fee_a, fee_b) = swap_history::get_pool_total_fees(&stats);
            assert!(fee_a == 10, 3);
            assert!(fee_b == 20, 4);
            
            let (vol_24h_a, vol_24h_b, swaps_24h) = swap_history::get_pool_24h_stats(&stats);
            assert!(vol_24h_a == 1000, 5);
            assert!(vol_24h_b == 2000, 6);
            assert!(swaps_24h == 2, 7);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(stats);
        };
        
        test_scenario::end(scenario_val);
    }
}
