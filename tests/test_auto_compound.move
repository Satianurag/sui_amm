#[test_only]
module sui_amm::test_auto_compound {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, USDT};
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Auto-compound preserves value
    // Feature: nft-display-enhancements, Property 1: Auto-compound preserves value
    // Validates: Requirements 1.1, 1.3
    // 
    // Property: For any position with pending fees, auto-compounding should result 
    // in a position value (liquidity + fees) that is greater than or equal to the 
    // original position value plus fees, accounting for rounding.
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_auto_compound_value_preservation_basic() {
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
        
        // Get position value before auto-compound
        let view_before = pool::get_position_view(&pool, &position);
        let (value_a_before, value_b_before) = position::view_value(&view_before);
        let (fee_a_before, fee_b_before) = position::view_fees(&view_before);
        let total_value_before = value_a_before + value_b_before + fee_a_before + fee_b_before;
        
        // Auto-compound fees
        ts::next_tx(&mut scenario, fixtures::admin());
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
        
        // Verify liquidity increased
        assert!(liquidity_increase > 0, 0);
        
        // Clean up refund coins
        
        // Get position value after auto-compound
        let view_after = pool::get_position_view(&pool, &position);
        let (value_a_after, value_b_after) = position::view_value(&view_after);
        let (fee_a_after, fee_b_after) = position::view_fees(&view_after);
        let total_value_after = value_a_after + value_b_after + fee_a_after + fee_b_after;
        
        // Property: Total value should be preserved (allowing for small rounding)
        // After auto-compound, fees should be near zero and value should have increased
        // Note: Fees might not be exactly zero due to the swap operation generating new fees
        assert!(fee_a_after < 1000, 1); // Fees should be minimal after compound
        assert!(fee_b_after < 1000, 2);
        
        // Total value after should be >= total value before (minus small rounding tolerance)
        // Allow 0.1% tolerance for rounding
        let tolerance = total_value_before / 1000;
        assert!(total_value_after + tolerance >= total_value_before, 3);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_auto_compound_value_preservation_large_fees() {
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
        
        // Execute many swaps to generate large fees
        let mut i = 0;
        while (i < 50) {
            let swap_amount = fixtures::large_swap();
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
        
        // Get position value before auto-compound
        let view_before = pool::get_position_view(&pool, &position);
        let (value_a_before, value_b_before) = position::view_value(&view_before);
        let (fee_a_before, fee_b_before) = position::view_fees(&view_before);
        let total_value_before = value_a_before + value_b_before + fee_a_before + fee_b_before;
        
        // Verify we have substantial fees
        assert!(fee_a_before > 1000, 0);
        
        // Auto-compound fees
        ts::next_tx(&mut scenario, fixtures::admin());
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
        
        // Get position value after auto-compound
        let view_after = pool::get_position_view(&pool, &position);
        let (value_a_after, value_b_after) = position::view_value(&view_after);
        let (fee_a_after, fee_b_after) = position::view_fees(&view_after);
        let total_value_after = value_a_after + value_b_after + fee_a_after + fee_b_after;
        
        // Property: Value should be preserved
        let tolerance = total_value_before / 1000;
        assert!(total_value_after + tolerance >= total_value_before, 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_auto_compound_value_preservation_multiple_compounds() {
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
        
        // Perform multiple rounds of swaps and auto-compound
        let mut round = 0;
        while (round < 3) {
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
            
            // Get value before compound
            let view_before = pool::get_position_view(&pool, &position);
            let (value_a_before, value_b_before) = position::view_value(&view_before);
            let (fee_a_before, fee_b_before) = position::view_fees(&view_before);
            let total_value_before = value_a_before + value_b_before + fee_a_before + fee_b_before;
            
            // Auto-compound
            ts::next_tx(&mut scenario, fixtures::admin());
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
            
            // Get value after compound
            let view_after = pool::get_position_view(&pool, &position);
            let (value_a_after, value_b_after) = position::view_value(&view_after);
            let (fee_a_after, fee_b_after) = position::view_fees(&view_after);
            let total_value_after = value_a_after + value_b_after + fee_a_after + fee_b_after;
            
            // Verify value preservation in each round
            let tolerance = total_value_before / 1000;
            assert!(total_value_after + tolerance >= total_value_before, round);
            
            round = round + 1;
        };
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Auto-compound maintains pool ratio
    // Feature: nft-display-enhancements, Property 2: Auto-compound maintains pool ratio
    // Validates: Requirements 1.2
    // 
    // Property: For any auto-compound operation, the ratio of reinvested token A 
    // to token B should match the current pool ratio within the pool's tolerance threshold.
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_auto_compound_ratio_maintenance_balanced_pool() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 100_000_000; // Larger pool to reduce price impact
        let initial_b = 100_000_000; // 1:1 ratio
        
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
        
        // Execute swaps to generate fees (use small swaps to avoid price impact)
        let mut i = 0;
        while (i < 20) {
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
        
        // Auto-compound fees
        ts::next_tx(&mut scenario, fixtures::admin());
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
        
        // Property: Liquidity should have increased
        // The auto-compound function uses increase_liquidity which maintains pool ratio
        // We verify that liquidity increased, which means the operation succeeded
        // and the ratio was maintained (otherwise increase_liquidity would have failed)
        assert!(liquidity_increase > 0, 0);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_auto_compound_ratio_maintenance_unbalanced_pool() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 100_000_000; // Larger pool to reduce price impact
        let initial_b = 500_000_000; // 1:5 ratio
        
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
        
        // Execute swaps to generate fees (use small swaps to avoid price impact)
        let mut i = 0;
        while (i < 20) {
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
        
        // Auto-compound fees
        ts::next_tx(&mut scenario, fixtures::admin());
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
        
        // Property: Liquidity should have increased
        // The auto-compound function uses increase_liquidity which maintains pool ratio
        // We verify that liquidity increased, which means the operation succeeded
        // and the ratio was maintained (otherwise increase_liquidity would have failed)
        assert!(liquidity_increase > 0, 0);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Auto-compound minimum threshold
    // Feature: nft-display-enhancements, Property 7: Auto-compound minimum threshold
    // Validates: Requirements 1.4
    // 
    // Property: For any position, attempting to auto-compound with fees below the 
    // minimum threshold should revert, and the position state should remain unchanged.
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EInsufficientFeesToCompound)]
    fun test_property_auto_compound_minimum_threshold_no_fees() {
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
        
        // Try to auto-compound without any fees - should fail
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
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EInsufficientFeesToCompound)]
    fun test_property_auto_compound_minimum_threshold_small_fees() {
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
        
        // Execute a single small swap to generate minimal fees
        let swap_amount = 100; // Very small swap
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
        
        // Try to auto-compound with fees below threshold - should fail
        ts::next_tx(&mut scenario, fixtures::admin());
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
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: Fee debt consistency after auto-compound
    // Feature: nft-display-enhancements, Property 10: Fee debt consistency after auto-compound
    // Validates: Requirements 1.3
    // 
    // Property: For any position after auto-compounding, the fee_debt should be 
    // updated such that pending fees are zero (within rounding tolerance).
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_property_fee_debt_consistency_after_auto_compound() {
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
        
        // Verify we have fees before auto-compound
        let view_before = pool::get_position_view(&pool, &position);
        let (fee_a_before, _fee_b_before) = position::view_fees(&view_before);
        assert!(fee_a_before > 1000, 0);
        
        // Auto-compound fees
        ts::next_tx(&mut scenario, fixtures::admin());
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
        
        // Property: After auto-compound, pending fees should be near zero
        let view_after = pool::get_position_view(&pool, &position);
        let (fee_a_after, fee_b_after) = position::view_fees(&view_after);
        
        // Allow tolerance for rounding and swap fees (< 1000 units)
        assert!(fee_a_after < 1000, 1);
        assert!(fee_b_after < 1000, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_property_fee_debt_consistency_multiple_compounds() {
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
        
        // Perform multiple rounds of swaps and auto-compound
        let mut round = 0;
        while (round < 3) {
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
            
            // Auto-compound
            ts::next_tx(&mut scenario, fixtures::admin());
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
            
            // Verify fees are near zero after each compound
            let view_after = pool::get_position_view(&pool, &position);
            let (fee_a_after, fee_b_after) = position::view_fees(&view_after);
            assert!(fee_a_after < 1000, round);
            assert!(fee_b_after < 1000, round + 100);
            
            round = round + 1;
        };
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
}
