#[test_only]
module sui_amm::test_workflows {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self};
    use sui_amm::swap_history::{Self, StatisticsRegistry};
    use sui_amm::user_preferences::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Complete Liquidity Lifecycle
    // Requirements: 9.1 - Test complete liquidity lifecycle
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_complete_liquidity_lifecycle() {
        let admin = fixtures::admin();
        let user1 = fixtures::user1();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize swap history registry
        swap_history::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Step 1: Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, initial_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify initial position was created
        assert!(position::liquidity(&initial_position) > 0, 0);
        
        test_scenario::next_tx(&mut scenario, user1);
        
        // Step 2: User1 adds liquidity
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        let (add_a, add_b) = fixtures::micro_liquidity();
        let mut user1_position = test_utils::add_liquidity_helper(
            &mut pool,
            add_a,
            add_b,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify user1 position
        assert!(position::liquidity(&user1_position) > 0, 1);
        let user1_liquidity = position::liquidity(&user1_position);
        
        // Step 3: Execute swaps to generate fees
        let snapshot_before_swaps = test_utils::snapshot_pool(&pool, &clock);
        
        let swap_amount = fixtures::small_swap();
        let coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        let snapshot_after_swaps = test_utils::snapshot_pool(&pool, &clock);
        
        // Verify K-invariant maintained
        assertions::assert_k_invariant_maintained(
            &snapshot_before_swaps,
            &snapshot_after_swaps,
            fixtures::standard_tolerance_u128()
        );
        
        // Verify fees accumulated
        let (acc_before_a, _) = test_utils::get_snapshot_acc_fees(&snapshot_before_swaps);
        let (acc_after_a, _) = test_utils::get_snapshot_acc_fees(&snapshot_after_swaps);
        assert!(acc_after_a > acc_before_a, 2);
        
        // Step 4: Claim fees
        let (fee_a, fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut user1_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify fees were claimed
        let fee_a_amount = coin::value<BTC>(&fee_a);
        let fee_b_amount = coin::value<USDC>(&fee_b);
        assert!(fee_a_amount > 0 || fee_b_amount > 0, 3);
        
        coin::burn_for_testing<BTC>(fee_a);
        coin::burn_for_testing<USDC>(fee_b);
        
        // Step 5: Remove partial liquidity
        let partial_liquidity = user1_liquidity / 2;
        let (coin_a_partial, coin_b_partial) = test_utils::remove_liquidity_helper(
            &mut pool,
            &mut user1_position,
            partial_liquidity,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify tokens returned
        assert!(coin::value(&coin_a_partial) > 0, 4);
        assert!(coin::value(&coin_b_partial) > 0, 5);
        
        coin::burn_for_testing(coin_a_partial);
        coin::burn_for_testing(coin_b_partial);
        
        // Verify position still exists with reduced liquidity
        assert!(position::liquidity(&user1_position) > 0, 6);
        assert!(position::liquidity(&user1_position) < user1_liquidity, 7);
        
        // Step 6: Remove remaining liquidity
        let remaining_liquidity = position::liquidity(&user1_position);
        let (coin_a_final, coin_b_final) = test_utils::remove_liquidity_helper(
            &mut pool,
            &mut user1_position,
            remaining_liquidity,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify tokens returned
        assert!(coin::value(&coin_a_final) > 0, 8);
        assert!(coin::value(&coin_b_final) > 0, 9);
        
        coin::burn_for_testing(coin_a_final);
        coin::burn_for_testing(coin_b_final);
        
        // Step 7: Verify NFT can be destroyed (liquidity is zero)
        assert!(position::liquidity(&user1_position) == 0, 10);
        position::destroy_for_testing(user1_position);
        
        // Cleanup
        test_scenario::return_shared(pool);
        position::destroy_for_testing(initial_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Concurrent A→B and B→A Swaps with K Maintenance
    // Requirements: 9.3 - Test concurrent swaps with K maintenance
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_concurrent_swaps_k_maintenance() {
        let admin = fixtures::admin();
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Create pool with balanced liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::balanced_large_liquidity();
        
        let (pool_id, initial_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, admin);
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        // Capture initial K
        let snapshot_initial = test_utils::snapshot_pool(&pool, &clock);
        let k_initial = test_utils::get_k_invariant(&snapshot_initial);
        
        // Execute multiple A→B swaps
        let swap_amount = fixtures::medium_swap();
        let mut i = 0;
        while (i < 5) {
            let coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                test_utils::far_future(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Capture K after A→B swaps
        let snapshot_after_a_to_b = test_utils::snapshot_pool(&pool, &clock);
        let k_after_a_to_b = test_utils::get_k_invariant(&snapshot_after_a_to_b);
        
        // Verify K maintained or increased
        assert!(k_after_a_to_b >= k_initial, 0);
        
        // Execute multiple B→A swaps
        let mut j = 0;
        while (j < 5) {
            let coin_out = test_utils::swap_b_to_a_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                test_utils::far_future(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            j = j + 1;
        };
        
        // Capture final K
        let snapshot_final = test_utils::snapshot_pool(&pool, &clock);
        let k_final = test_utils::get_k_invariant(&snapshot_final);
        
        // Verify K maintained or increased after all swaps
        assert!(k_final >= k_initial, 1);
        
        // Verify K increased from fees
        assert!(k_final > k_initial, 2);
        
        // Cleanup
        test_scenario::return_shared(pool);
        position::destroy_for_testing(initial_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Swap History Recording
    // Requirements: 9.6 - Test swap history recording
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_swap_history_recording() {
        let admin = fixtures::admin();
        let user1 = fixtures::user1();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize swap history registry
        swap_history::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, initial_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, user1);
        
        // Create user swap history
        let mut user_history = swap_history::create_user_history(test_scenario::ctx(&mut scenario));
        
        // Get pool and registry
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<StatisticsRegistry>(&scenario);
        
        // Initialize pool statistics
        swap_history::init_pool_statistics(&mut registry, pool_id, test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, user1);
        
        // Execute swaps and record history
        let swap_amount = fixtures::small_swap();
        let num_swaps = 5;
        
        let mut i = 0;
        while (i < num_swaps) {
            let coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                test_utils::far_future(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Record in user history
            swap_history::record_user_swap(
                &mut user_history,
                pool_id,
                true, // is_a_to_b
                swap_amount,
                coin::value(&coin_out),
                (swap_amount * fee_bps) / 10000,
                100, // price_impact_bps
                &clock
            );
            
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Verify user history
        let total_swaps = swap_history::get_user_total_swaps(&user_history);
        assert!(total_swaps == num_swaps, 0);
        
        let total_volume = swap_history::get_user_total_volume(&user_history);
        assert!(total_volume == ((swap_amount * num_swaps) as u128), 1);
        
        let swaps = swap_history::get_user_swaps(&user_history);
        assert!(vector::length(swaps) == num_swaps, 2);
        
        // Cleanup
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        swap_history::destroy_user_history_for_testing(user_history);
        position::destroy_for_testing(initial_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: User Preferences Application
    // Requirements: 9.7 - Test user preferences application
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_user_preferences_application() {
        let _admin = fixtures::admin();
        let user1 = fixtures::user1();
        
        let mut scenario = test_scenario::begin(user1);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Create user preferences
        let mut prefs = user_preferences::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Set custom slippage tolerance (1%)
        user_preferences::set_slippage_tolerance(&mut prefs, 100);
        
        // Set custom deadline (30 minutes)
        user_preferences::set_deadline(&mut prefs, 1800);
        
        // Set max price impact (5%)
        user_preferences::set_max_price_impact(&mut prefs, 500);
        
        // Verify preferences were set
        assert!(user_preferences::get_slippage_tolerance(&prefs) == 100, 0);
        assert!(user_preferences::get_deadline(&prefs) == 1800, 1);
        assert!(user_preferences::get_max_price_impact(&prefs) == 500, 2);
        
        // Test calculate_min_output
        let expected_output = 1000000u64;
        let min_output = user_preferences::calculate_min_output(&prefs, expected_output);
        let expected_min = expected_output - (expected_output * 100 / 10000); // 1% slippage
        assert!(min_output == expected_min, 3);
        
        // Test calculate_deadline_ms
        let current_time = clock::timestamp_ms(&clock);
        let deadline = user_preferences::calculate_deadline_ms(&prefs, current_time);
        let expected_deadline = current_time + (1800 * 1000); // 30 minutes in ms
        assert!(deadline == expected_deadline, 4);
        
        // Test auto-compound preference
        user_preferences::set_auto_compound(&mut prefs, true);
        assert!(user_preferences::get_auto_compound(&prefs) == true, 5);
        
        // Test update_all
        user_preferences::update_all(
            &mut prefs,
            200, // 2% slippage
            3600, // 1 hour deadline
            false, // no auto-compound
            1000, // 10% max price impact
            test_scenario::ctx(&mut scenario)
        );
        
        assert!(user_preferences::get_slippage_tolerance(&prefs) == 200, 6);
        assert!(user_preferences::get_deadline(&prefs) == 3600, 7);
        assert!(user_preferences::get_auto_compound(&prefs) == false, 8);
        assert!(user_preferences::get_max_price_impact(&prefs) == 1000, 9);
        
        // Cleanup
        user_preferences::destroy_for_testing(prefs);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
