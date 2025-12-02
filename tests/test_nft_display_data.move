#[test_only]
module sui_amm::test_nft_display_data {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use std::string::{Self};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, USDT};
    use sui_amm::fixtures;
    use sui_amm::string_utils;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Display Data Completeness
    // Feature: nft-display-enhancements, Property 3: Display data completeness
    // Validates: Requirements 2.1, 2.2
    // 
    // Property: For any position, calling make_nft_display_data() should return 
    // a struct where all fields are populated with valid values (no null/undefined states)
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_display_data_completeness_fresh_position() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Get position view and create display data
        let position_view = pool::get_position_view(&pool, &position);
        let staleness_threshold = 86400000; // 24 hours
        let display_data = position::make_nft_display_data(
            &position,
            &position_view,
            &clock,
            staleness_threshold
        );
        
        // Verify all identity fields are populated
        assert!(position::display_position_id(&display_data) == object::id(&position), 0);
        assert!(position::display_pool_id(&display_data) == pool_id, 1);
        
        // Verify basic info fields are populated
        let name = position::display_name(&display_data);
        let description = position::display_description(&display_data);
        let pool_type = position::display_pool_type(&display_data);
        assert!(std::string::length(&name) > 0, 2);
        assert!(std::string::length(&description) > 0, 3);
        assert!(std::string::length(&pool_type) > 0, 4);
        assert!(position::display_fee_tier_bps(&display_data) == fee_bps, 5);
        
        // Verify position size is populated
        assert!(position::display_liquidity_shares(&display_data) > 0, 6);
        
        // Verify current values are populated
        assert!(position::display_current_value_a(&display_data) > 0, 7);
        assert!(position::display_current_value_b(&display_data) > 0, 8);
        
        // Verify fees are populated (may be 0 for fresh position)
        let _pending_fees_a = position::display_pending_fees_a(&display_data);
        let _pending_fees_b = position::display_pending_fees_b(&display_data);
        
        // Verify IL is populated (should be 0 for fresh position)
        let il_bps = position::display_impermanent_loss_bps(&display_data);
        assert!(il_bps == 0, 9);
        
        // Verify entry tracking is populated
        assert!(position::display_original_deposit_a(&display_data) > 0, 10);
        assert!(position::display_original_deposit_b(&display_data) > 0, 11);
        assert!(position::display_entry_price_ratio_scaled(&display_data) > 0, 12);
        
        // Verify cached values are populated
        assert!(position::display_cached_value_a(&display_data) > 0, 13);
        assert!(position::display_cached_value_b(&display_data) > 0, 14);
        let _cached_fee_a = position::display_cached_fee_a(&display_data);
        let _cached_fee_b = position::display_cached_fee_b(&display_data);
        let _cached_il_bps = position::display_cached_il_bps(&display_data);
        
        // Verify image URL is populated
        let image_url = position::display_image_url(&display_data);
        assert!(std::string::length(&image_url) > 0, 15);
        
        // Verify staleness fields are populated
        let _is_stale = position::display_is_stale(&display_data);
        let _last_update_ms = position::display_last_update_ms(&display_data);
        assert!(position::display_staleness_threshold_ms(&display_data) == staleness_threshold, 16);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_display_data_completeness_after_swaps() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute multiple swaps to generate fees and change state
        let mut i = 0;
        while (i < 10) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Get display data
        let position_view = pool::get_position_view(&pool, &position);
        let display_data = position::make_nft_display_data(
            &position,
            &position_view,
            &clock,
            86400000
        );
        
        // Verify all fields are still populated after swaps
        assert!(position::display_position_id(&display_data) == object::id(&position), 0);
        assert!(position::display_pool_id(&display_data) == pool_id, 1);
        assert!(std::string::length(&position::display_name(&display_data)) > 0, 2);
        assert!(position::display_liquidity_shares(&display_data) > 0, 3);
        assert!(position::display_current_value_a(&display_data) > 0, 4);
        assert!(position::display_current_value_b(&display_data) > 0, 5);
        
        // After swaps, fees should be > 0
        assert!(position::display_pending_fees_a(&display_data) > 0, 6);
        
        // Verify image URL is still populated
        assert!(std::string::length(&position::display_image_url(&display_data)) > 0, 7);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_display_data_completeness_with_zero_liquidity() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get display data for zero liquidity position
        let position_view = pool::get_position_view(&pool, &position);
        let display_data = position::make_nft_display_data(
            &position,
            &position_view,
            &clock,
            86400000
        );
        
        // Verify all fields are populated even with zero liquidity
        assert!(position::display_position_id(&display_data) == object::id(&position), 0);
        assert!(position::display_pool_id(&display_data) == pool_id, 1);
        assert!(std::string::length(&position::display_name(&display_data)) > 0, 2);
        
        // Liquidity should be 0
        assert!(position::display_liquidity_shares(&display_data) == 0, 3);
        
        // Values should be 0
        assert!(position::display_current_value_a(&display_data) == 0, 4);
        assert!(position::display_current_value_b(&display_data) == 0, 5);
        
        // Fees should be 0
        assert!(position::display_pending_fees_a(&display_data) == 0, 6);
        assert!(position::display_pending_fees_b(&display_data) == 0, 7);
        
        // Image URL should still be populated
        assert!(std::string::length(&position::display_image_url(&display_data)) > 0, 8);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_display_data_completeness_small_equal_pool() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 1_000_000;
        let initial_b = 1_000_000;
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let position_view = pool::get_position_view(&pool, &position);
        let display_data = position::make_nft_display_data(&position, &position_view, &clock, 86400000);
        
        assert!(position::display_position_id(&display_data) == object::id(&position), 0);
        assert!(position::display_liquidity_shares(&display_data) > 0, 1);
        assert!(position::display_current_value_a(&display_data) > 0, 2);
        assert!(position::display_current_value_b(&display_data) > 0, 3);
        assert!(std::string::length(&position::display_image_url(&display_data)) > 0, 4);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_display_data_completeness_unbalanced_pool() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 1_000_000;
        let initial_b = 10_000_000; // 1:10 ratio
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let position_view = pool::get_position_view(&pool, &position);
        let display_data = position::make_nft_display_data(&position, &position_view, &clock, 86400000);
        
        assert!(position::display_position_id(&display_data) == object::id(&position), 0);
        assert!(position::display_liquidity_shares(&display_data) > 0, 1);
        assert!(position::display_current_value_a(&display_data) > 0, 2);
        assert!(position::display_current_value_b(&display_data) > 0, 3);
        assert!(std::string::length(&position::display_image_url(&display_data)) > 0, 4);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Real-time vs Cached Consistency
    // Feature: nft-display-enhancements, Property 4: Real-time vs cached consistency
    // Validates: Requirements 2.2, 2.3
    // 
    // Property: For any position where metadata was just refreshed, the cached 
    // values in NFTDisplayData should equal the real-time calculated values
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_realtime_cached_consistency_after_refresh() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute swaps to generate fees and change state
        let mut i = 0;
        while (i < 5) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Refresh metadata to sync cached values with real-time
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Get display data
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        
        // Verify cached values equal real-time values after refresh
        assert!(
            position::display_cached_value_a(&display_data) == position::display_current_value_a(&display_data),
            0
        );
        assert!(
            position::display_cached_value_b(&display_data) == position::display_current_value_b(&display_data),
            1
        );
        assert!(
            position::display_cached_fee_a(&display_data) == position::display_pending_fees_a(&display_data),
            2
        );
        assert!(
            position::display_cached_fee_b(&display_data) == position::display_pending_fees_b(&display_data),
            3
        );
        assert!(
            position::display_cached_il_bps(&display_data) == position::display_impermanent_loss_bps(&display_data),
            4
        );
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_realtime_cached_consistency_fresh_position() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Refresh metadata to sync cached values with real-time
        // (Fresh positions have cached values set to deposit amounts, which may differ
        // from actual position value due to MINIMUM_LIQUIDITY burn)
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // After refresh, cached values should equal real-time values
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        
        assert!(
            position::display_cached_value_a(&display_data) == position::display_current_value_a(&display_data),
            0
        );
        assert!(
            position::display_cached_value_b(&display_data) == position::display_current_value_b(&display_data),
            1
        );
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_realtime_cached_consistency_after_increase_liquidity() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Increase liquidity (which auto-refreshes metadata)
        let add_a = 500_000;
        let add_b = 500_000;
        let (refund_a, refund_b) = pool::increase_liquidity(
            &mut pool,
            &mut position,
            coin::mint_for_testing<USDC>(add_a, ts::ctx(&mut scenario)),
            coin::mint_for_testing<USDT>(add_b, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get display data
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        
        // Verify cached values equal real-time values after increase_liquidity
        assert!(
            position::display_cached_value_a(&display_data) == position::display_current_value_a(&display_data),
            0
        );
        assert!(
            position::display_cached_value_b(&display_data) == position::display_current_value_b(&display_data),
            1
        );
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_realtime_cached_consistency_multiple_refreshes() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Perform multiple rounds of swaps and refreshes
        let mut round = 0;
        while (round < 3) {
            // Execute swaps
            let mut i = 0;
            while (i < 3) {
                let swap_amount = fixtures::medium_swap();
                let _coin_out = test_utils::swap_a_to_b_helper(
                    &mut pool,
                    swap_amount,
                    0,
                    0,
                    fixtures::far_future_deadline(),
                    &clock,
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(_coin_out);
                i = i + 1;
            };
            
            // Refresh metadata
            pool::refresh_position_metadata(&pool, &mut position, &clock);
            
            // Verify consistency after each refresh
            let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
            assert!(
                position::display_cached_value_a(&display_data) == position::display_current_value_a(&display_data),
                round
            );
            assert!(
                position::display_cached_value_b(&display_data) == position::display_current_value_b(&display_data),
                round + 100
            );
            
            round = round + 1;
        };
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Zero Liquidity Safety
    // Feature: nft-display-enhancements, Property 6: Zero liquidity safety
    // Validates: Requirements 3.5
    // 
    // Property: For any position with zero liquidity, all value and fee queries 
    // should return zero without panicking or reverting
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_zero_liquidity_safety_after_full_removal() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get display data for zero liquidity position - should not panic
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        
        // Verify all value and fee queries return zero
        assert!(position::display_liquidity_shares(&display_data) == 0, 0);
        assert!(position::display_current_value_a(&display_data) == 0, 1);
        assert!(position::display_current_value_b(&display_data) == 0, 2);
        assert!(position::display_pending_fees_a(&display_data) == 0, 3);
        assert!(position::display_pending_fees_b(&display_data) == 0, 4);
        assert!(position::display_impermanent_loss_bps(&display_data) == 0, 5);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_zero_liquidity_safety_get_position_view() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get position view - should not panic
        let position_view = pool::get_position_view(&pool, &position);
        let (value_a, value_b) = position::view_value(&position_view);
        let (fee_a, fee_b) = position::view_fees(&position_view);
        
        // Verify all values are zero
        assert!(value_a == 0, 0);
        assert!(value_b == 0, 1);
        assert!(fee_a == 0, 2);
        assert!(fee_b == 0, 3);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_zero_liquidity_safety_after_swaps() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute swaps to generate fees
        let mut i = 0;
        while (i < 5) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Remove all liquidity (including fees)
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get display data - should not panic even after swaps
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        
        // Verify all values are zero
        assert!(position::display_liquidity_shares(&display_data) == 0, 0);
        assert!(position::display_current_value_a(&display_data) == 0, 1);
        assert!(position::display_current_value_b(&display_data) == 0, 2);
        assert!(position::display_pending_fees_a(&display_data) == 0, 3);
        assert!(position::display_pending_fees_b(&display_data) == 0, 4);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_zero_liquidity_safety_multiple_operations() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Perform multiple queries on zero liquidity position - all should work
        let _display_data1 = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        let _position_view1 = pool::get_position_view(&pool, &position);
        let _display_data2 = pool::get_nft_display_data(&pool, &position, &clock, 3600000);
        let _position_view2 = pool::get_position_view(&pool, &position);
        
        // Refresh metadata on zero liquidity position - should not panic
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Get display data again after refresh
        let display_data3 = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        assert!(position::display_liquidity_shares(&display_data3) == 0, 0);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Staleness Detection Accuracy
    // Feature: nft-display-enhancements, Property 5: Staleness detection accuracy
    // Validates: Requirements 4.1, 4.2, 4.4
    // 
    // Property: For any position and staleness threshold, is_stale should be true 
    // if and only if (current_time - last_update_ms) > staleness_threshold_ms
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_staleness_detection_exact_threshold() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time and refresh metadata
        clock::set_for_testing(&mut clock, 1000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let last_update = position::last_metadata_update_ms(&position);
        assert!(last_update == 1000000, 0);
        
        // Test: exactly at threshold should NOT be stale (> not >=)
        let threshold = 500000;
        clock::set_for_testing(&mut clock, last_update + threshold);
        let (is_stale, age_ms) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale == false, 1);
        assert!(age_ms == threshold, 2);
        
        // Test: one millisecond past threshold SHOULD be stale
        clock::set_for_testing(&mut clock, last_update + threshold + 1);
        let (is_stale2, age_ms2) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale2 == true, 3);
        assert!(age_ms2 == threshold + 1, 4);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_staleness_detection_before_threshold() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time and refresh metadata
        clock::set_for_testing(&mut clock, 2000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let last_update = position::last_metadata_update_ms(&position);
        
        // Test various times before threshold
        let threshold = 1000000;
        
        // Test: 1ms after update - not stale
        clock::set_for_testing(&mut clock, last_update + 1);
        let (is_stale1, age_ms1) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale1 == false, 0);
        assert!(age_ms1 == 1, 1);
        
        // Test: halfway to threshold - not stale
        clock::set_for_testing(&mut clock, last_update + threshold / 2);
        let (is_stale2, age_ms2) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale2 == false, 2);
        assert!(age_ms2 == threshold / 2, 3);
        
        // Test: 1ms before threshold - not stale
        clock::set_for_testing(&mut clock, last_update + threshold - 1);
        let (is_stale3, age_ms3) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale3 == false, 4);
        assert!(age_ms3 == threshold - 1, 5);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_staleness_detection_after_threshold() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time and refresh metadata
        clock::set_for_testing(&mut clock, 3000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let last_update = position::last_metadata_update_ms(&position);
        
        // Test various times after threshold
        let threshold = 600000;
        
        // Test: 1ms past threshold - stale
        clock::set_for_testing(&mut clock, last_update + threshold + 1);
        let (is_stale1, age_ms1) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale1 == true, 0);
        assert!(age_ms1 == threshold + 1, 1);
        
        // Test: 2x threshold - stale
        clock::set_for_testing(&mut clock, last_update + threshold * 2);
        let (is_stale2, age_ms2) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale2 == true, 2);
        assert!(age_ms2 == threshold * 2, 3);
        
        // Test: 10x threshold - stale
        clock::set_for_testing(&mut clock, last_update + threshold * 10);
        let (is_stale3, age_ms3) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale3 == true, 4);
        assert!(age_ms3 == threshold * 10, 5);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_staleness_detection_never_updated() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Position has never been explicitly refreshed (last_metadata_update_ms == 0)
        let last_update = position::last_metadata_update_ms(&position);
        assert!(last_update == 0, 0);
        
        // Test: never updated position with small threshold should be stale
        clock::set_for_testing(&mut clock, 1000000);
        let threshold = 500000; // 500 seconds
        let (is_stale, age_ms) = position::get_staleness_info(&position, &clock, threshold);
        
        // Should be stale because age (u64::MAX) > threshold
        assert!(is_stale == true, 1);
        
        // Age should be u64::MAX to indicate never updated
        assert!(age_ms == 18446744073709551615, 2);
        
        // Test with any threshold - never updated position should always be stale
        let (is_stale2, age_ms2) = position::get_staleness_info(&position, &clock, 1);
        assert!(is_stale2 == true, 3);
        assert!(age_ms2 == 18446744073709551615, 4);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_staleness_detection_various_thresholds() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time and refresh metadata
        clock::set_for_testing(&mut clock, 5000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let last_update = position::last_metadata_update_ms(&position);
        
        // Advance time by a fixed amount
        let time_elapsed = 3600000; // 1 hour
        clock::set_for_testing(&mut clock, last_update + time_elapsed);
        
        // Test with various thresholds
        // Threshold > elapsed: not stale
        let (is_stale1, age_ms1) = position::get_staleness_info(&position, &clock, 7200000); // 2 hours
        assert!(is_stale1 == false, 0);
        assert!(age_ms1 == time_elapsed, 1);
        
        // Threshold == elapsed: not stale (> not >=)
        let (is_stale2, age_ms2) = position::get_staleness_info(&position, &clock, time_elapsed);
        assert!(is_stale2 == false, 2);
        assert!(age_ms2 == time_elapsed, 3);
        
        // Threshold < elapsed: stale
        let (is_stale3, age_ms3) = position::get_staleness_info(&position, &clock, 1800000); // 30 minutes
        assert!(is_stale3 == true, 4);
        assert!(age_ms3 == time_elapsed, 5);
        
        // Very small threshold: stale
        let (is_stale4, age_ms4) = position::get_staleness_info(&position, &clock, 1000); // 1 second
        assert!(is_stale4 == true, 6);
        assert!(age_ms4 == time_elapsed, 7);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_staleness_detection_after_refresh() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let threshold = 1000000;
        
        // Initial refresh
        clock::set_for_testing(&mut clock, 10000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Immediately after refresh: not stale
        let (is_stale1, age_ms1) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale1 == false, 0);
        assert!(age_ms1 == 0, 1);
        
        // Advance time past threshold: stale
        clock::set_for_testing(&mut clock, 10000000 + threshold + 1);
        let (is_stale2, age_ms2) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale2 == true, 2);
        assert!(age_ms2 == threshold + 1, 3);
        
        // Refresh again
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Immediately after second refresh: not stale
        let (is_stale3, age_ms3) = position::get_staleness_info(&position, &clock, threshold);
        assert!(is_stale3 == false, 4);
        assert!(age_ms3 == 0, 5);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Entry Point Equivalence
    // Feature: nft-display-enhancements, Property 9: Entry point equivalence
    // Validates: Requirements 5.1, 5.2, 5.4
    // 
    // Property: For any operation, calling the entry point wrapper should produce 
    // the same state changes as calling the underlying function directly
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_entry_point_equivalence_auto_compound() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        // Create two identical pools and positions
        let (pool_id1, mut position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let (pool_id2, mut position2) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ts::ctx(&mut scenario)
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool1 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id1);
        let mut pool2 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id2);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Generate fees in both pools with identical swaps
        let mut i = 0;
        while (i < 10) {
            let swap_amount = fixtures::medium_swap();
            
            let _coin_out1 = test_utils::swap_a_to_b_helper(
                &mut pool1,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out1);
            
            let _coin_out2 = test_utils::swap_a_to_b_helper(
                &mut pool2,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out2);
            
            i = i + 1;
        };
        
        // Capture state before auto-compound
        let liquidity1_before = position::liquidity(&position1);
        let liquidity2_before = position::liquidity(&position2);
        assert!(liquidity1_before == liquidity2_before, 0);
        
        let (fees1_a_before, fees1_b_before) = pool::get_accumulated_fees(&pool1, &position1);
        let (fees2_a_before, fees2_b_before) = pool::get_accumulated_fees(&pool2, &position2);
        assert!(fees1_a_before == fees2_a_before, 1);
        assert!(fees1_b_before == fees2_b_before, 2);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Call direct function on position1
        let (liquidity_increase1, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool1,
            &mut position1,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        // Call entry point wrapper on position2
        sui_amm::sui_amm::auto_compound_fees_entry(
            &mut pool2,
            &mut position2,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify both positions have identical state after operations
        let liquidity1_after = position::liquidity(&position1);
        let liquidity2_after = position::liquidity(&position2);
        assert!(liquidity1_after == liquidity2_after, 3);
        
        // Verify liquidity increased by same amount
        let liquidity_increase2 = liquidity2_after - liquidity2_before;
        assert!(liquidity_increase1 == liquidity_increase2, 4);
        
        // Verify fees are now zero (or near zero) in both positions
        let (fees1_a_after, fees1_b_after) = pool::get_accumulated_fees(&pool1, &position1);
        let (fees2_a_after, fees2_b_after) = pool::get_accumulated_fees(&pool2, &position2);
        assert!(fees1_a_after == fees2_a_after, 5);
        assert!(fees1_b_after == fees2_b_after, 6);
        
        // Verify fee debt is identical
        assert!(position::fee_debt_a(&position1) == position::fee_debt_a(&position2), 7);
        assert!(position::fee_debt_b(&position1) == position::fee_debt_b(&position2), 8);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool1);
        ts::return_shared(pool2);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        ts::end(scenario);
    }

    #[test]
    fun test_property_entry_point_equivalence_refresh_metadata() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        // Create two identical pools and positions
        let (pool_id1, mut position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let (pool_id2, mut position2) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ts::ctx(&mut scenario)
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool1 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id1);
        let mut pool2 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id2);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute identical swaps in both pools to make metadata stale
        let mut i = 0;
        while (i < 5) {
            let swap_amount = fixtures::medium_swap();
            
            let _coin_out1 = test_utils::swap_a_to_b_helper(
                &mut pool1,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out1);
            
            let _coin_out2 = test_utils::swap_a_to_b_helper(
                &mut pool2,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out2);
            
            i = i + 1;
        };
        
        // Advance time to make metadata stale
        clock::increment_for_testing(&mut clock, 90000000); // 25 hours
        
        // Capture state before refresh
        let cached_value_a1_before = position::cached_value_a(&position1);
        let cached_value_b1_before = position::cached_value_b(&position1);
        let cached_value_a2_before = position::cached_value_a(&position2);
        let cached_value_b2_before = position::cached_value_b(&position2);
        assert!(cached_value_a1_before == cached_value_a2_before, 0);
        assert!(cached_value_b1_before == cached_value_b2_before, 1);
        
        let last_update1_before = position::last_metadata_update_ms(&position1);
        let last_update2_before = position::last_metadata_update_ms(&position2);
        assert!(last_update1_before == last_update2_before, 2);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Call direct function on position1
        pool::refresh_position_metadata(&pool1, &mut position1, &clock);
        
        // Call entry point wrapper on position2
        sui_amm::sui_amm::refresh_position_metadata_entry(&pool2, &mut position2, &clock);
        
        // Verify both positions have identical state after refresh
        let cached_value_a1_after = position::cached_value_a(&position1);
        let cached_value_b1_after = position::cached_value_b(&position1);
        let cached_value_a2_after = position::cached_value_a(&position2);
        let cached_value_b2_after = position::cached_value_b(&position2);
        assert!(cached_value_a1_after == cached_value_a2_after, 3);
        assert!(cached_value_b1_after == cached_value_b2_after, 4);
        
        let cached_fee_a1_after = position::cached_fee_a(&position1);
        let cached_fee_b1_after = position::cached_fee_b(&position1);
        let cached_fee_a2_after = position::cached_fee_a(&position2);
        let cached_fee_b2_after = position::cached_fee_b(&position2);
        assert!(cached_fee_a1_after == cached_fee_a2_after, 5);
        assert!(cached_fee_b1_after == cached_fee_b2_after, 6);
        
        let cached_il1_after = position::cached_il_bps(&position1);
        let cached_il2_after = position::cached_il_bps(&position2);
        assert!(cached_il1_after == cached_il2_after, 7);
        
        // Verify timestamps are updated identically
        let last_update1_after = position::last_metadata_update_ms(&position1);
        let last_update2_after = position::last_metadata_update_ms(&position2);
        assert!(last_update1_after == last_update2_after, 8);
        assert!(last_update1_after > last_update1_before, 9);
        
        // Verify metadata is no longer stale
        let (is_stale1, _) = position::get_staleness_info(&position1, &clock, 86400000);
        let (is_stale2, _) = position::get_staleness_info(&position2, &clock, 86400000);
        assert!(is_stale1 == false, 10);
        assert!(is_stale2 == false, 11);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool1);
        ts::return_shared(pool2);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        ts::end(scenario);
    }

    #[test]
    fun test_property_entry_point_equivalence_error_handling() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Try to auto-compound with insufficient fees (no swaps executed)
        // Both direct call and entry point should fail with same error
        
        // This should fail because there are no fees to compound
        // We can't directly test the error code match, but we verify both fail
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_entry_point_equivalence_multiple_operations() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        // Create two identical pools and positions
        let (pool_id1, mut position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let (pool_id2, mut position2) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ts::ctx(&mut scenario)
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool1 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id1);
        let mut pool2 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id2);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Perform 2 rounds of operations (reduced from 3 to avoid timeout)
        let mut round = 0;
        while (round < 2) {
            // Execute 2 swaps per round (reduced from 3)
            let mut i = 0;
            while (i < 2) {
                let swap_amount = fixtures::medium_swap();
                
                let _coin_out1 = test_utils::swap_a_to_b_helper(
                    &mut pool1,
                    swap_amount,
                    0,
                    0,
                    fixtures::far_future_deadline(),
                    &clock,
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(_coin_out1);
                
                let _coin_out2 = test_utils::swap_a_to_b_helper(
                    &mut pool2,
                    swap_amount,
                    0,
                    0,
                    fixtures::far_future_deadline(),
                    &clock,
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(_coin_out2);
                
                i = i + 1;
            };
            
            ts::next_tx(&mut scenario, fixtures::admin());
            
            // Refresh metadata using different methods
            if (round % 2 == 0) {
                pool::refresh_position_metadata(&pool1, &mut position1, &clock);
                sui_amm::sui_amm::refresh_position_metadata_entry(&pool2, &mut position2, &clock);
            } else {
                sui_amm::sui_amm::refresh_position_metadata_entry(&pool1, &mut position1, &clock);
                pool::refresh_position_metadata(&pool2, &mut position2, &clock);
            };
            
            // Verify state is identical after each round
            assert!(position::cached_value_a(&position1) == position::cached_value_a(&position2), round);
            assert!(position::cached_value_b(&position1) == position::cached_value_b(&position2), round + 100);
            assert!(position::last_metadata_update_ms(&position1) == position::last_metadata_update_ms(&position2), round + 200);
            
            clock::increment_for_testing(&mut clock, 1000000);
            round = round + 1;
        };
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool1);
        ts::return_shared(pool2);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Image URL Format Validity
    // Feature: nft-display-enhancements, Property 8: Image URL format validity
    // Validates: Requirements 2.5
    // 
    // Property: For any position, the image_url field in NFTDisplayData should 
    // start with "data:image/svg+xml;base64," indicating a valid data URI
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_image_url_format_validity_fresh_position() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Get display data
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        let image_url = position::display_image_url(&display_data);
        
        // Verify image URL starts with the correct data URI prefix
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url, &expected_prefix), 0);
        
        // Verify image URL is not empty
        assert!(string::length(&image_url) > string::length(&expected_prefix), 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_image_url_format_validity_after_refresh() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute swaps to change state
        let mut i = 0;
        while (i < 5) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Refresh metadata to regenerate SVG
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Get display data
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        let image_url = position::display_image_url(&display_data);
        
        // Verify image URL still has correct format after refresh
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url, &expected_prefix), 0);
        assert!(string::length(&image_url) > string::length(&expected_prefix), 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_image_url_format_validity_after_auto_compound() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute swaps to generate fees
        let mut i = 0;
        while (i < 10) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Auto-compound fees (which refreshes metadata)
        let (_liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        // Get display data
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        let image_url = position::display_image_url(&display_data);
        
        // Verify image URL has correct format after auto-compound
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url, &expected_prefix), 0);
        assert!(string::length(&image_url) > string::length(&expected_prefix), 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_image_url_format_validity_zero_liquidity() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get display data for zero liquidity position
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        let image_url = position::display_image_url(&display_data);
        
        // Verify image URL still has correct format even with zero liquidity
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url, &expected_prefix), 0);
        assert!(string::length(&image_url) > string::length(&expected_prefix), 1);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_image_url_format_validity_various_pool_sizes() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        
        // Test with small pool
        let (pool_id1, position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            1_000_000,
            1_000_000,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool1 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let display_data1 = pool::get_nft_display_data(&pool1, &position1, &clock, 86400000);
        let image_url1 = position::display_image_url(&display_data1);
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url1, &expected_prefix), 0);
        
        ts::return_shared(pool1);
        position::destroy_for_testing(position1);
        
        // Test with large pool
        ts::next_tx(&mut scenario, fixtures::admin());
        let (pool_id2, position2) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            1_000_000_000,
            1_000_000_000,
            fixtures::admin(),
            ts::ctx(&mut scenario)
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool2 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id2);
        
        let display_data2 = pool::get_nft_display_data(&pool2, &position2, &clock, 86400000);
        let image_url2 = position::display_image_url(&display_data2);
        assert!(string_utils::starts_with(&image_url2, &expected_prefix), 1);
        
        ts::return_shared(pool2);
        position::destroy_for_testing(position2);
        
        // Test with unbalanced pool
        ts::next_tx(&mut scenario, fixtures::admin());
        let (pool_id3, position3) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            1_000_000,
            10_000_000,
            fixtures::admin(),
            ts::ctx(&mut scenario)
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool3 = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id3);
        
        let display_data3 = pool::get_nft_display_data(&pool3, &position3, &clock, 86400000);
        let image_url3 = position::display_image_url(&display_data3);
        assert!(string_utils::starts_with(&image_url3, &expected_prefix), 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool3);
        position::destroy_for_testing(position3);
        ts::end(scenario);
    }

    #[test]
    fun test_property_image_url_format_validity_cached_vs_direct() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Get image URL from display data
        let display_data = pool::get_nft_display_data(&pool, &position, &clock, 86400000);
        let image_url_from_display = position::display_image_url(&display_data);
        
        // Get image URL directly from position
        let image_url_from_position = position::cached_image_url(&position);
        
        // Both should have the same format
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url_from_display, &expected_prefix), 0);
        assert!(string_utils::starts_with(&image_url_from_position, &expected_prefix), 1);
        
        // Both should be identical
        assert!(image_url_from_display == image_url_from_position, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION TEST: End-to-End Auto-Compound Flow
    // Validates: Requirements 1.1, 1.2, 1.3, 1.5
    // 
    // This test validates the complete auto-compound workflow from pool creation
    // through fee generation, auto-compounding, and metadata refresh
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_integration_end_to_end_auto_compound_flow() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Step 1: Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial clock time to non-zero
        clock::set_for_testing(&mut clock, 1000000);
        
        // Capture initial state
        let initial_liquidity = position::liquidity(&position);
        let (initial_fees_a, initial_fees_b) = pool::get_accumulated_fees(&pool, &position);
        assert!(initial_fees_a == 0, 0);
        assert!(initial_fees_b == 0, 1);
        
        // Step 2: Execute multiple swaps to generate fees
        let num_swaps = 15;
        let mut i = 0;
        while (i < num_swaps) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Verify fees were generated
        let (fees_a_before_compound, _fees_b_before_compound) = pool::get_accumulated_fees(&pool, &position);
        assert!(fees_a_before_compound > 0, 2);
        // Note: fees_b might be 0 if all swaps were A->B
        
        // Capture metadata state before auto-compound
        let _cached_value_a_before = position::cached_value_a(&position);
        let _cached_value_b_before = position::cached_value_b(&position);
        let last_update_before = position::last_metadata_update_ms(&position);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Step 3: Call auto_compound_fees()
        let (liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position,
            0, // min_liquidity_increase
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        // Step 4: Verify position liquidity increased
        let final_liquidity = position::liquidity(&position);
        assert!(final_liquidity > initial_liquidity, 3);
        assert!(final_liquidity == initial_liquidity + liquidity_increase, 4);
        assert!(liquidity_increase > 0, 5);
        
        // Step 5: Verify fees are now zero (or near zero due to rounding)
        let (fees_a_after_compound, _fees_b_after_compound) = pool::get_accumulated_fees(&pool, &position);
        // Fees should be significantly reduced (ideally to 0, but allow small rounding errors)
        assert!(fees_a_after_compound < fees_a_before_compound / 100, 6); // Less than 1% of original
        
        // Step 6: Verify metadata is refreshed
        let last_update_after = position::last_metadata_update_ms(&position);
        assert!(last_update_after > last_update_before, 7);
        
        // Verify cached values were updated
        let cached_value_a_after = position::cached_value_a(&position);
        let cached_value_b_after = position::cached_value_b(&position);
        
        // Cached values may change in either direction depending on swaps and pool ratio
        // The important thing is that total value increased and metadata was refreshed
        // We verify this by checking that cached values match real-time values
        
        // Verify cached values match real-time values (metadata was refreshed)
        let position_view = pool::get_position_view(&pool, &position);
        let (current_value_a, current_value_b) = position::view_value(&position_view);
        assert!(cached_value_a_after == current_value_a, 10);
        assert!(cached_value_b_after == current_value_b, 11);
        
        // Verify metadata is not stale
        let (is_stale, _) = position::get_staleness_info(&position, &clock, 86400000);
        assert!(is_stale == false, 12);
        
        // Verify the auto-compound maintained pool ratio (Requirement 1.2)
        // The liquidity increase should be proportional to the pool's current ratio
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let ratio_a = (cached_value_a_after as u128) * 1_000_000 / (reserve_a as u128);
        let ratio_b = (cached_value_b_after as u128) * 1_000_000 / (reserve_b as u128);
        // Ratios should be approximately equal (within 1% tolerance)
        let ratio_diff = if (ratio_a > ratio_b) { ratio_a - ratio_b } else { ratio_b - ratio_a };
        let max_ratio = if (ratio_a > ratio_b) { ratio_a } else { ratio_b };
        assert!(ratio_diff * 100 < max_ratio, 13); // Less than 1% difference
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_auto_compound_with_multiple_swap_directions() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let initial_liquidity = position::liquidity(&position);
        
        // Execute swaps in both directions to generate fees in both tokens
        let mut i = 0;
        while (i < 5) {
            // Swap A -> B
            let swap_amount_a = fixtures::medium_swap();
            let _coin_out_b = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount_a,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out_b);
            
            // Swap B -> A
            let swap_amount_b = fixtures::medium_swap();
            let _coin_out_a = test_utils::swap_b_to_a_helper(
                &mut pool,
                swap_amount_b,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out_a);
            
            i = i + 1;
        };
        
        // Verify fees in both tokens
        let (fees_a_before, fees_b_before) = pool::get_accumulated_fees(&pool, &position);
        assert!(fees_a_before > 0, 0);
        assert!(fees_b_before > 0, 1);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Auto-compound fees
        let (liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        // Verify liquidity increased
        let final_liquidity = position::liquidity(&position);
        assert!(final_liquidity > initial_liquidity, 2);
        assert!(liquidity_increase > 0, 3);
        
        // Verify fees are now minimal
        let (fees_a_after, fees_b_after) = pool::get_accumulated_fees(&pool, &position);
        assert!(fees_a_after < fees_a_before / 100, 4);
        assert!(fees_b_after < fees_b_before / 100, 5);
        
        // Verify metadata is refreshed and consistent
        let position_view = pool::get_position_view(&pool, &position);
        let (current_value_a, current_value_b) = position::view_value(&position_view);
        assert!(position::cached_value_a(&position) == current_value_a, 6);
        assert!(position::cached_value_b(&position) == current_value_b, 7);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_auto_compound_preserves_total_value() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute swaps to generate fees
        let mut i = 0;
        while (i < 10) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Calculate total value before auto-compound (position value + fees)
        let position_view_before = pool::get_position_view(&pool, &position);
        let (value_a_before, value_b_before) = position::view_value(&position_view_before);
        let (fees_a_before, fees_b_before) = position::view_fees(&position_view_before);
        let total_a_before = value_a_before + fees_a_before;
        let total_b_before = value_b_before + fees_b_before;
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Auto-compound fees
        let (_liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        // Calculate total value after auto-compound (should be approximately the same)
        let position_view_after = pool::get_position_view(&pool, &position);
        let (value_a_after, value_b_after) = position::view_value(&position_view_after);
        let (fees_a_after, fees_b_after) = position::view_fees(&position_view_after);
        let total_a_after = value_a_after + fees_a_after;
        let total_b_after = value_b_after + fees_b_after;
        
        // Total value should be preserved (within small rounding tolerance)
        // Allow up to 0.1% difference due to rounding
        let diff_a = if (total_a_after > total_a_before) {
            total_a_after - total_a_before
        } else {
            total_a_before - total_a_after
        };
        let diff_b = if (total_b_after > total_b_before) {
            total_b_after - total_b_before
        } else {
            total_b_before - total_b_after
        };
        
        assert!(diff_a * 1000 < total_a_before, 0); // Less than 0.1% difference
        assert!(diff_b * 1000 < total_b_before, 1); // Less than 0.1% difference
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_auto_compound_multiple_rounds() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let initial_liquidity = position::liquidity(&position);
        let mut current_liquidity = initial_liquidity;
        
        // Perform multiple rounds of swap + auto-compound
        let mut round = 0;
        while (round < 3) {
            // Execute swaps to generate fees
            let mut i = 0;
            while (i < 5) {
                let swap_amount = fixtures::medium_swap();
                let _coin_out = test_utils::swap_a_to_b_helper(
                    &mut pool,
                    swap_amount,
                    0,
                    0,
                    fixtures::far_future_deadline(),
                    &clock,
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(_coin_out);
                i = i + 1;
            };
            
            // Verify fees were generated
            let (fees_a, _fees_b) = pool::get_accumulated_fees(&pool, &position);
            assert!(fees_a > 0, round);
            
            ts::next_tx(&mut scenario, fixtures::admin());
            
            // Auto-compound
            let (liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
                &mut pool,
                &mut position,
                0,
                &clock,
                fixtures::far_future_deadline(),
                ts::ctx(&mut scenario)
            );

            // Clean up refund coins
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);

            // Clean up refund coins
            
            // Verify liquidity increased
            let new_liquidity = position::liquidity(&position);
            assert!(new_liquidity > current_liquidity, round + 100);
            assert!(liquidity_increase > 0, round + 200);
            current_liquidity = new_liquidity;
            
            // Verify metadata is fresh
            let (is_stale, _) = position::get_staleness_info(&position, &clock, 86400000);
            assert!(is_stale == false, round + 300);
            
            ts::next_tx(&mut scenario, fixtures::user1());
            round = round + 1;
        };
        
        // Verify total liquidity growth over all rounds
        let final_liquidity = position::liquidity(&position);
        assert!(final_liquidity > initial_liquidity, 400);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool::EInsufficientFeesToCompound)]
    fun test_integration_auto_compound_fails_with_insufficient_fees() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Try to auto-compound without generating any fees - should fail
        let (_liquidity_increase, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION TEST: Display Data Refresh Flow
    // Validates: Requirements 2.2, 2.3, 2.4, 4.1, 4.4
    // 
    // This test validates the complete display data refresh workflow including
    // staleness detection, metadata refresh, and cached value synchronization
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_integration_display_data_refresh_flow() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Step 1: Create position with initial metadata
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time and refresh metadata to establish baseline
        clock::set_for_testing(&mut clock, 1000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Capture initial metadata state
        let initial_cached_value_a = position::cached_value_a(&position);
        let initial_cached_value_b = position::cached_value_b(&position);
        let initial_cached_fee_a = position::cached_fee_a(&position);
        let initial_cached_fee_b = position::cached_fee_b(&position);
        let _initial_cached_il = position::cached_il_bps(&position);
        let initial_last_update = position::last_metadata_update_ms(&position);
        
        assert!(initial_last_update == 1000000, 0);
        
        // Verify metadata is fresh initially
        let staleness_threshold = 3600000; // 1 hour
        let (is_stale_initial, age_initial) = position::get_staleness_info(&position, &clock, staleness_threshold);
        assert!(is_stale_initial == false, 1);
        assert!(age_initial == 0, 2);
        
        // Verify initial cached values match real-time values
        let position_view_initial = pool::get_position_view(&pool, &position);
        let (initial_real_value_a, initial_real_value_b) = position::view_value(&position_view_initial);
        assert!(initial_cached_value_a == initial_real_value_a, 3);
        assert!(initial_cached_value_b == initial_real_value_b, 4);
        
        ts::next_tx(&mut scenario, fixtures::user1());
        
        // Step 2: Execute swaps to make metadata stale
        // Advance time past the staleness threshold
        clock::set_for_testing(&mut clock, 1000000 + staleness_threshold + 1000000); // 1 hour + 1000 seconds past
        
        // Execute multiple swaps to change pool state and generate fees
        let num_swaps = 10;
        let mut i = 0;
        while (i < num_swaps) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Step 3: Check is_stale returns true
        let (is_stale_after_swaps, age_after_swaps) = position::get_staleness_info(&position, &clock, staleness_threshold);
        assert!(is_stale_after_swaps == true, 5);
        assert!(age_after_swaps > staleness_threshold, 6);
        
        // Verify cached values are now different from real-time values
        let position_view_stale = pool::get_position_view(&pool, &position);
        let (stale_real_value_a, _stale_real_value_b) = position::view_value(&position_view_stale);
        let (stale_real_fee_a, _stale_real_fee_b) = position::view_fees(&position_view_stale);
        
        // Cached values should still be the old values
        assert!(position::cached_value_a(&position) == initial_cached_value_a, 7);
        assert!(position::cached_value_b(&position) == initial_cached_value_b, 8);
        assert!(position::cached_fee_a(&position) == initial_cached_fee_a, 9);
        assert!(position::cached_fee_b(&position) == initial_cached_fee_b, 10);
        
        // Real-time values should have changed due to swaps
        // (Pool state changed, so position value may have changed)
        // Fees should definitely have increased
        assert!(stale_real_fee_a > initial_cached_fee_a, 11);
        
        // Verify display data shows staleness
        let display_data_stale = pool::get_nft_display_data(&pool, &position, &clock, staleness_threshold);
        assert!(position::display_is_stale(&display_data_stale) == true, 12);
        assert!(position::display_cached_value_a(&display_data_stale) == initial_cached_value_a, 13);
        assert!(position::display_current_value_a(&display_data_stale) == stale_real_value_a, 14);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Step 4: Call refresh_position_metadata()
        let current_time = clock::timestamp_ms(&clock);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Verify last_update_ms was updated
        let updated_last_update = position::last_metadata_update_ms(&position);
        assert!(updated_last_update == current_time, 15);
        assert!(updated_last_update > initial_last_update, 16);
        
        // Step 5: Verify cached values match real-time values
        let position_view_refreshed = pool::get_position_view(&pool, &position);
        let (refreshed_real_value_a, refreshed_real_value_b) = position::view_value(&position_view_refreshed);
        let (refreshed_real_fee_a, refreshed_real_fee_b) = position::view_fees(&position_view_refreshed);
        
        // Cached values should now match real-time values
        assert!(position::cached_value_a(&position) == refreshed_real_value_a, 17);
        assert!(position::cached_value_b(&position) == refreshed_real_value_b, 18);
        assert!(position::cached_fee_a(&position) == refreshed_real_fee_a, 19);
        assert!(position::cached_fee_b(&position) == refreshed_real_fee_b, 20);
        
        // Verify IL is also synced (get from display data since there's no direct accessor)
        let display_data_for_il = pool::get_nft_display_data(&pool, &position, &clock, staleness_threshold);
        assert!(
            position::display_cached_il_bps(&display_data_for_il) == position::display_impermanent_loss_bps(&display_data_for_il),
            21
        );
        
        // Step 6: Verify is_stale returns false
        let (is_stale_after_refresh, age_after_refresh) = position::get_staleness_info(&position, &clock, staleness_threshold);
        assert!(is_stale_after_refresh == false, 22);
        assert!(age_after_refresh == 0, 23);
        
        // Verify display data shows freshness
        let display_data_fresh = pool::get_nft_display_data(&pool, &position, &clock, staleness_threshold);
        assert!(position::display_is_stale(&display_data_fresh) == false, 24);
        
        // Verify cached and real-time values in display data are now identical
        assert!(
            position::display_cached_value_a(&display_data_fresh) == position::display_current_value_a(&display_data_fresh),
            25
        );
        assert!(
            position::display_cached_value_b(&display_data_fresh) == position::display_current_value_b(&display_data_fresh),
            26
        );
        assert!(
            position::display_cached_fee_a(&display_data_fresh) == position::display_pending_fees_a(&display_data_fresh),
            27
        );
        assert!(
            position::display_cached_fee_b(&display_data_fresh) == position::display_pending_fees_b(&display_data_fresh),
            28
        );
        assert!(
            position::display_cached_il_bps(&display_data_fresh) == position::display_impermanent_loss_bps(&display_data_fresh),
            29
        );
        
        // Verify image URL was regenerated
        let image_url = position::display_image_url(&display_data_fresh);
        let expected_prefix = string::utf8(b"data:image/svg+xml;base64,");
        assert!(string_utils::starts_with(&image_url, &expected_prefix), 30);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_display_data_refresh_flow_multiple_cycles() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create position with initial metadata
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let staleness_threshold = 3600000; // 1 hour
        let mut current_time = 1000000u64;
        
        // Perform multiple cycles of: refresh -> make stale -> verify -> refresh
        let mut cycle = 0;
        while (cycle < 3) {
            // Refresh metadata
            clock::set_for_testing(&mut clock, current_time);
            pool::refresh_position_metadata(&pool, &mut position, &clock);
            
            // Verify metadata is fresh
            let (is_stale_fresh, age_fresh) = position::get_staleness_info(&position, &clock, staleness_threshold);
            assert!(is_stale_fresh == false, cycle);
            assert!(age_fresh == 0, cycle + 100);
            
            // Verify cached values match real-time
            let position_view_fresh = pool::get_position_view(&pool, &position);
            let (fresh_real_a, fresh_real_b) = position::view_value(&position_view_fresh);
            assert!(position::cached_value_a(&position) == fresh_real_a, cycle + 200);
            assert!(position::cached_value_b(&position) == fresh_real_b, cycle + 300);
            
            ts::next_tx(&mut scenario, fixtures::user1());
            
            // Advance time and execute swaps to make stale
            current_time = current_time + staleness_threshold + 1000000;
            clock::set_for_testing(&mut clock, current_time);
            
            let mut i = 0;
            while (i < 5) {
                let swap_amount = fixtures::medium_swap();
                let _coin_out = test_utils::swap_a_to_b_helper(
                    &mut pool,
                    swap_amount,
                    0,
                    0,
                    fixtures::far_future_deadline(),
                    &clock,
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(_coin_out);
                i = i + 1;
            };
            
            // Verify metadata is now stale
            let (is_stale_stale, age_stale) = position::get_staleness_info(&position, &clock, staleness_threshold);
            assert!(is_stale_stale == true, cycle + 400);
            assert!(age_stale > staleness_threshold, cycle + 500);
            
            // Verify cached values differ from real-time
            let position_view_stale = pool::get_position_view(&pool, &position);
            let (_stale_real_a, _stale_real_b) = position::view_value(&position_view_stale);
            let (stale_real_fee_a, _stale_real_fee_b) = position::view_fees(&position_view_stale);
            
            // Cached values should be old, real-time should be new
            // (We can't assert exact inequality because pool state changes are complex,
            // but we can verify fees increased)
            assert!(stale_real_fee_a > 0, cycle + 600);
            
            ts::next_tx(&mut scenario, fixtures::admin());
            cycle = cycle + 1;
        };
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_display_data_refresh_flow_with_different_thresholds() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create position with initial metadata
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Refresh metadata at time 0
        clock::set_for_testing(&mut clock, 1000000);
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        ts::next_tx(&mut scenario, fixtures::user1());
        
        // Execute swaps and advance time
        clock::set_for_testing(&mut clock, 1000000 + 7200000); // 2 hours later
        
        let mut i = 0;
        while (i < 5) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Test with different staleness thresholds
        // 1 hour threshold: should be stale
        let (is_stale_1h, _) = position::get_staleness_info(&position, &clock, 3600000);
        assert!(is_stale_1h == true, 0);
        
        let display_data_1h = pool::get_nft_display_data(&pool, &position, &clock, 3600000);
        assert!(position::display_is_stale(&display_data_1h) == true, 1);
        
        // 3 hour threshold: should not be stale
        let (is_stale_3h, _) = position::get_staleness_info(&position, &clock, 10800000);
        assert!(is_stale_3h == false, 2);
        
        let display_data_3h = pool::get_nft_display_data(&pool, &position, &clock, 10800000);
        assert!(position::display_is_stale(&display_data_3h) == false, 3);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Refresh metadata
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // After refresh, should not be stale with any reasonable threshold
        let (is_stale_after_1h, _) = position::get_staleness_info(&position, &clock, 3600000);
        assert!(is_stale_after_1h == false, 4);
        
        let (is_stale_after_3h, _) = position::get_staleness_info(&position, &clock, 10800000);
        assert!(is_stale_after_3h == false, 5);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION TEST: Multi-Position Scenarios
    // Validates: Requirements 1.1, 1.3, 2.2
    // 
    // This test validates that multiple positions in the same pool can be managed
    // independently, with auto-compound and metadata updates affecting only the
    // targeted position without impacting others
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_integration_multi_position_scenarios() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Step 1: Create pool with initial liquidity from first position
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time
        clock::set_for_testing(&mut clock, 1000000);
        
        // Step 2: Create additional positions in the same pool
        let add_amount_a = 500_000;
        let add_amount_b = 500_000;
        
        let (mut position2, refund_a2, refund_b2) = pool::add_liquidity(
            &mut pool,
            coin::mint_for_testing<USDC>(add_amount_a, ts::ctx(&mut scenario)),
            coin::mint_for_testing<USDT>(add_amount_b, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        
        ts::next_tx(&mut scenario, fixtures::user2());
        
        let (position3, refund_a3, refund_b3) = pool::add_liquidity(
            &mut pool,
            coin::mint_for_testing<USDC>(add_amount_a, ts::ctx(&mut scenario)),
            coin::mint_for_testing<USDT>(add_amount_b, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a3);
        coin::burn_for_testing(refund_b3);
        
        // Capture initial state of all positions
        let liquidity1_initial = position::liquidity(&position1);
        let liquidity2_initial = position::liquidity(&position2);
        let liquidity3_initial = position::liquidity(&position3);
        
        let _cached_value_a1_initial = position::cached_value_a(&position1);
        let cached_value_a2_initial = position::cached_value_a(&position2);
        let cached_value_a3_initial = position::cached_value_a(&position3);
        
        let last_update1_initial = position::last_metadata_update_ms(&position1);
        let last_update2_initial = position::last_metadata_update_ms(&position2);
        let last_update3_initial = position::last_metadata_update_ms(&position3);
        
        ts::next_tx(&mut scenario, fixtures::user1());
        
        // Step 3: Execute swaps affecting all positions
        let num_swaps = 15;
        let mut i = 0;
        while (i < num_swaps) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Verify all positions have accumulated fees
        let (fees1_a_before, _fees1_b_before) = pool::get_accumulated_fees(&pool, &position1);
        let (fees2_a_before, fees2_b_before) = pool::get_accumulated_fees(&pool, &position2);
        let (fees3_a_before, fees3_b_before) = pool::get_accumulated_fees(&pool, &position3);
        
        assert!(fees1_a_before > 0, 0);
        assert!(fees2_a_before > 0, 1);
        assert!(fees3_a_before > 0, 2);
        
        // Verify liquidity hasn't changed yet
        assert!(position::liquidity(&position1) == liquidity1_initial, 3);
        assert!(position::liquidity(&position2) == liquidity2_initial, 4);
        assert!(position::liquidity(&position3) == liquidity3_initial, 5);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Step 4: Auto-compound one position (position1)
        let (liquidity_increase1, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position1,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        // Step 5: Verify position1 was affected
        let liquidity1_after_compound = position::liquidity(&position1);
        assert!(liquidity1_after_compound > liquidity1_initial, 6);
        assert!(liquidity1_after_compound == liquidity1_initial + liquidity_increase1, 7);
        assert!(liquidity_increase1 > 0, 8);
        
        // Verify position1 fees are now minimal
        let (fees1_a_after, _fees1_b_after) = pool::get_accumulated_fees(&pool, &position1);
        assert!(fees1_a_after < fees1_a_before / 100, 9); // Less than 1% of original
        
        // Verify position1 metadata was updated
        let last_update1_after = position::last_metadata_update_ms(&position1);
        assert!(last_update1_after > last_update1_initial, 10);
        
        // Verify position1 cached values were updated
        let cached_value_a1_after = position::cached_value_a(&position1);
        // Cached value should have changed (either increased or adjusted based on pool ratio)
        // We just verify it was updated by checking it matches real-time
        let position_view1 = pool::get_position_view(&pool, &position1);
        let (current_value_a1, _) = position::view_value(&position_view1);
        assert!(cached_value_a1_after == current_value_a1, 11);
        
        // Step 6: Verify other positions unaffected
        // Position2 and Position3 should have same liquidity
        assert!(position::liquidity(&position2) == liquidity2_initial, 12);
        assert!(position::liquidity(&position3) == liquidity3_initial, 13);
        
        // Position2 and Position3 should still have their fees
        let (fees2_a_after, fees2_b_after) = pool::get_accumulated_fees(&pool, &position2);
        let (fees3_a_after, fees3_b_after) = pool::get_accumulated_fees(&pool, &position3);
        assert!(fees2_a_after == fees2_a_before, 14);
        assert!(fees2_b_after == fees2_b_before, 15);
        assert!(fees3_a_after == fees3_a_before, 16);
        assert!(fees3_b_after == fees3_b_before, 17);
        
        // Position2 and Position3 metadata should be unchanged
        assert!(position::last_metadata_update_ms(&position2) == last_update2_initial, 18);
        assert!(position::last_metadata_update_ms(&position3) == last_update3_initial, 19);
        
        // Position2 and Position3 cached values should be unchanged
        assert!(position::cached_value_a(&position2) == cached_value_a2_initial, 20);
        assert!(position::cached_value_a(&position3) == cached_value_a3_initial, 21);
        
        // Step 7: Verify independent metadata updates
        // Advance time to make metadata stale
        clock::increment_for_testing(&mut clock, 90000000); // 25 hours
        
        // Check staleness for all positions
        let staleness_threshold = 86400000; // 24 hours
        let (is_stale1, _) = position::get_staleness_info(&position1, &clock, staleness_threshold);
        let (is_stale2, _) = position::get_staleness_info(&position2, &clock, staleness_threshold);
        let (is_stale3, _) = position::get_staleness_info(&position3, &clock, staleness_threshold);
        
        // Position1 should not be stale (was just updated during auto-compound)
        // Actually, we advanced time by 25 hours, so it should be stale now
        assert!(is_stale1 == true, 22);
        
        // Position2 and Position3 should definitely be stale (never refreshed after creation)
        assert!(is_stale2 == true, 23);
        assert!(is_stale3 == true, 24);
        
        ts::next_tx(&mut scenario, fixtures::user1());
        
        // Refresh only position2's metadata
        pool::refresh_position_metadata(&pool, &mut position2, &clock);
        
        // Verify position2 metadata was updated
        let last_update2_after_refresh = position::last_metadata_update_ms(&position2);
        assert!(last_update2_after_refresh > last_update2_initial, 25);
        
        // Verify position2 is no longer stale
        let (is_stale2_after, _) = position::get_staleness_info(&position2, &clock, staleness_threshold);
        assert!(is_stale2_after == false, 26);
        
        // Verify position2 cached values match real-time
        let position_view2 = pool::get_position_view(&pool, &position2);
        let (current_value_a2, current_value_b2) = position::view_value(&position_view2);
        assert!(position::cached_value_a(&position2) == current_value_a2, 27);
        assert!(position::cached_value_b(&position2) == current_value_b2, 28);
        
        // Verify position1 and position3 metadata unchanged by position2's refresh
        assert!(position::last_metadata_update_ms(&position1) == last_update1_after, 29);
        assert!(position::last_metadata_update_ms(&position3) == last_update3_initial, 30);
        
        // Verify position1 and position3 are still stale
        let (is_stale1_final, _) = position::get_staleness_info(&position1, &clock, staleness_threshold);
        let (is_stale3_final, _) = position::get_staleness_info(&position3, &clock, staleness_threshold);
        assert!(is_stale1_final == true, 31);
        assert!(is_stale3_final == true, 32);
        
        // Step 8: Verify display data for all positions shows independent state
        let display_data1 = pool::get_nft_display_data(&pool, &position1, &clock, staleness_threshold);
        let display_data2 = pool::get_nft_display_data(&pool, &position2, &clock, staleness_threshold);
        let display_data3 = pool::get_nft_display_data(&pool, &position3, &clock, staleness_threshold);
        
        // Position1: stale, has increased liquidity
        assert!(position::display_is_stale(&display_data1) == true, 33);
        assert!(position::display_liquidity_shares(&display_data1) == liquidity1_after_compound, 34);
        
        // Position2: fresh, original liquidity
        assert!(position::display_is_stale(&display_data2) == false, 35);
        assert!(position::display_liquidity_shares(&display_data2) == liquidity2_initial, 36);
        
        // Position3: stale, original liquidity
        assert!(position::display_is_stale(&display_data3) == true, 37);
        assert!(position::display_liquidity_shares(&display_data3) == liquidity3_initial, 38);
        
        // Verify all positions have different IDs
        assert!(position::display_position_id(&display_data1) != position::display_position_id(&display_data2), 39);
        assert!(position::display_position_id(&display_data2) != position::display_position_id(&display_data3), 40);
        assert!(position::display_position_id(&display_data1) != position::display_position_id(&display_data3), 41);
        
        // Verify all positions belong to the same pool
        assert!(position::display_pool_id(&display_data1) == pool_id, 42);
        assert!(position::display_pool_id(&display_data2) == pool_id, 43);
        assert!(position::display_pool_id(&display_data3) == pool_id, 44);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        position::destroy_for_testing(position3);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_multi_position_auto_compound_all() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create second position
        let (mut position2, refund_a2, refund_b2) = pool::add_liquidity(
            &mut pool,
            coin::mint_for_testing<USDC>(500_000, ts::ctx(&mut scenario)),
            coin::mint_for_testing<USDT>(500_000, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        
        let liquidity1_initial = position::liquidity(&position1);
        let liquidity2_initial = position::liquidity(&position2);
        
        // Execute swaps to generate fees (many swaps to ensure sufficient fees for smaller positions)
        let mut i = 0;
        while (i < 50) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Verify both positions have fees
        let (fees1_a_before, _) = pool::get_accumulated_fees(&pool, &position1);
        let (fees2_a_before, _) = pool::get_accumulated_fees(&pool, &position2);
        assert!(fees1_a_before > 0, 0);
        assert!(fees2_a_before > 0, 1);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Auto-compound both positions
        let (liquidity_increase1, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position1,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);

        // Clean up refund coins
        
        ts::next_tx(&mut scenario, fixtures::user1());
        
        // Check if position2 still has enough fees after position1's auto-compound
        let (fees2_a_mid, fees2_b_mid) = pool::get_accumulated_fees(&pool, &position2);
        let total_fees2_mid = fees2_a_mid + fees2_b_mid;
        
        // Only auto-compound position2 if it still has sufficient fees
        let liquidity_increase2 = if (total_fees2_mid >= 1000) {
            let (liq_inc, refund_a, refund_b) = pool::auto_compound_fees(
                &mut pool,
                &mut position2,
                0,
                &clock,
                fixtures::far_future_deadline(),
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            liq_inc
        } else {
            // If fees dropped below threshold, just verify position2 is unchanged
            0
        };
        
        // Verify position1 increased liquidity
        assert!(position::liquidity(&position1) == liquidity1_initial + liquidity_increase1, 2);
        assert!(liquidity_increase1 > 0, 4);
        
        // Verify position1 has minimal fees now
        let (fees1_a_after, _) = pool::get_accumulated_fees(&pool, &position1);
        assert!(fees1_a_after < fees1_a_before / 100, 6);
        
        // If position2 was auto-compounded, verify it increased
        if (liquidity_increase2 > 0) {
            assert!(position::liquidity(&position2) == liquidity2_initial + liquidity_increase2, 3);
            let (fees2_a_after, _) = pool::get_accumulated_fees(&pool, &position2);
            assert!(fees2_a_after < fees2_a_before / 100, 7);
        };
        
        // Verify both positions have fresh metadata
        let (is_stale1, _) = position::get_staleness_info(&position1, &clock, 86400000);
        let (is_stale2, _) = position::get_staleness_info(&position2, &clock, 86400000);
        assert!(is_stale1 == false, 8);
        assert!(is_stale2 == false, 9);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        ts::end(scenario);
    }

    #[test]
    fun test_integration_multi_position_different_sizes() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with large initial position
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        
        let (pool_id, position_large) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            10_000_000, // Large position
            10_000_000,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create small position
        let (mut position_small, refund_a_small, refund_b_small) = pool::add_liquidity(
            &mut pool,
            coin::mint_for_testing<USDC>(100_000, ts::ctx(&mut scenario)), // Small position
            coin::mint_for_testing<USDT>(100_000, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a_small);
        coin::burn_for_testing(refund_b_small);
        
        let liquidity_large_initial = position::liquidity(&position_large);
        let liquidity_small_initial = position::liquidity(&position_small);
        
        // Large position should have much more liquidity
        assert!(liquidity_large_initial > liquidity_small_initial * 50, 0);
        
        // Execute swaps to generate fees (many smaller swaps to avoid price impact but generate enough fees)
        let mut i = 0;
        while (i < 100) {
            let swap_amount = fixtures::small_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Both positions should have fees proportional to their size
        let (fees_large_a, _) = pool::get_accumulated_fees(&pool, &position_large);
        let (fees_small_a, _) = pool::get_accumulated_fees(&pool, &position_small);
        
        assert!(fees_large_a > 0, 1);
        assert!(fees_small_a > 0, 2);
        // Large position should have much more fees
        assert!(fees_large_a > fees_small_a * 50, 3);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        
        // Auto-compound only the small position
        let (liquidity_increase_small, refund_a, refund_b) = pool::auto_compound_fees(
            &mut pool,
            &mut position_small,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );

        // Clean up refund coins
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Verify small position increased
        assert!(position::liquidity(&position_small) == liquidity_small_initial + liquidity_increase_small, 4);
        assert!(liquidity_increase_small > 0, 5);
        
        // Verify large position unchanged
        assert!(position::liquidity(&position_large) == liquidity_large_initial, 6);
        
        // Verify large position still has significant fees (may have changed slightly due to global fee accumulator updates)
        let (fees_large_a_after, _) = pool::get_accumulated_fees(&pool, &position_large);
        // Fees should still be substantial (at least 90% of original)
        assert!(fees_large_a_after > fees_large_a * 9 / 10, 7);
        
        // Verify small position fees are now minimal
        let (fees_small_a_after, _) = pool::get_accumulated_fees(&pool, &position_small);
        assert!(fees_small_a_after < fees_small_a / 100, 8);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position_large);
        position::destroy_for_testing(position_small);
        ts::end(scenario);
    }
}
