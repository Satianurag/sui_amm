#[test_only]
module sui_amm::test_stable_pool {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::stable_math;
    use sui_amm::position::{Self, LPPosition};
    use sui_amm::test_utils::{Self, USDC, USDT, StablePoolSnapshot};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // D-INVARIANT TESTS - StableSwap invariant verification
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_d_invariant_maintained_after_swap() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with amp=100 (balanced configuration)
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Snapshot D before swap
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Execute swap: 10M USDC -> USDT
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        // Snapshot D after swap
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Verify D_after >= D_before (zero tolerance for StableSwap)
        assertions::assert_d_invariant_maintained(&before, &after);
        
        // Cleanup
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_d_increases_on_add_liquidity() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with initial liquidity
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position1, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Snapshot D before adding more liquidity
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Add more liquidity
        let coin_a2 = test_utils::mint_coin<USDC>(500_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<USDT>(500_000_000, ts::ctx(&mut scenario));
        
        let (position2, refund_a2, refund_b2) = stable_pool::add_liquidity(
            &mut pool,
            coin_a2,
            coin_b2,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        
        // Snapshot D after adding liquidity
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Verify D increased
        assertions::assert_d_increased(&before, &after);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_d_decreases_on_remove_liquidity() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with initial liquidity
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Snapshot D before removing liquidity
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Remove half the liquidity
        let liquidity = position::liquidity(&position);
        let (coin_a_out, coin_b_out) = stable_pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            liquidity / 2,
            1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        
        // Snapshot D after removing liquidity
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Verify D decreased
        assertions::assert_d_decreased(&before, &after);
        
        // Cleanup
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MINIMAL SLIPPAGE TESTS - Stable pair behavior verification
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_minimal_slippage_balanced_swap() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with high amp (500) for minimal slippage
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 500, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Execute small swap (1% of reserves)
        let amount_in = 10_000_000u64; // 1% of 1B
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        // For stable pairs, expect near 1:1 exchange (minus 0.05% fee)
        // Expected output ≈ amount_in * (1 - 0.0005) = 9,995,000
        // Slippage should be < 0.1% (10 bps)
        let expected_output = amount_in - (amount_in * 5 / 10000); // Subtract fee
        assertions::assert_slippage_within(expected_output, actual_output, 10); // < 0.1% slippage
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_stable_pair_simulation_low_slippage() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool simulating USDC/USDT with amp=100
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Execute 1% of reserve swap
        let amount_in = 10_000_000u64; // 1% of 1B
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        // Verify slippage < 0.1% for 1% reserve swap (requirement 2.8)
        let expected_output = amount_in - (amount_in * 5 / 10000); // Subtract 0.05% fee
        assertions::assert_slippage_within(expected_output, actual_output, 10); // < 0.1% slippage
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AMP RAMPING TESTS - Amplification coefficient adjustment
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_amp_ramping_linear_interpolation() {
        let mut scenario = ts::begin(@0x1);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with amp=10
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 10, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Start amp ramp from 10 to 100 over 1 day
        let start_time = clock::timestamp_ms(&clock);
        let ramp_duration = fixtures::day();
        stable_pool::start_amp_ramp(
            &mut pool,
            100, // target_amp
            ramp_duration,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Check amp at start (should be 10)
        let amp_start = stable_pool::get_current_amp(&pool, &clock);
        assert!(amp_start == 10, 0);
        
        // Advance clock to midpoint (12 hours)
        test_utils::advance_clock(&mut clock, ramp_duration / 2);
        
        // Check amp at midpoint (should be ~55: 10 + (100-10)/2)
        let amp_mid = stable_pool::get_current_amp(&pool, &clock);
        assert!(amp_mid >= 50 && amp_mid <= 60, 1); // Allow some tolerance
        
        // Advance clock to end (24 hours)
        test_utils::advance_clock(&mut clock, ramp_duration / 2);
        
        // Check amp at end (should be 100)
        let amp_end = stable_pool::get_current_amp(&pool, &clock);
        assert!(amp_end == 100, 2);
        
        // Cleanup
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_amp_effect_on_slippage() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create two pools: one with low amp (1), one with high amp (1000)
        let mut pool_low_amp = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1, ts::ctx(&mut scenario));
        let mut pool_high_amp = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1000, ts::ctx(&mut scenario));
        
        // Add same liquidity to both
        let coin_a1 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        let (position1, refund_a1, refund_b1) = stable_pool::add_liquidity(
            &mut pool_low_amp,
            coin_a1,
            coin_b1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        
        let coin_a2 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        let (position2, refund_a2, refund_b2) = stable_pool::add_liquidity(
            &mut pool_high_amp,
            coin_a2,
            coin_b2,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        
        // Execute same swap on both pools
        let amount_in = 10_000_000u64;
        let coin_in1 = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out1 = stable_pool::swap_a_to_b(
            &mut pool_low_amp,
            coin_in1,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let coin_in2 = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out2 = stable_pool::swap_a_to_b(
            &mut pool_high_amp,
            coin_in2,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let output_low_amp = coin::value(&coin_out1);
        let output_high_amp = coin::value(&coin_out2);
        
        // High amp should give better output (less slippage)
        assert!(output_high_amp >= output_low_amp, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out1);
        coin::burn_for_testing(coin_out2);
        position::destroy(position1);
        position::destroy(position2);
        stable_pool::share(pool_low_amp);
        stable_pool::share(pool_high_amp);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEGENERATE INPUT HANDLING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EZeroAmount)]
    fun test_zero_reserve_handling() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        
        // Try to swap on empty pool (should fail)
        let coin_in = test_utils::mint_coin<USDC>(1000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(coin_out);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_extreme_imbalance_handling() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with extreme imbalance (1000:1)
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000_000, ts::ctx(&mut scenario)); // 1T
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario)); // 1B
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Snapshot D before swap
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Execute swap on imbalanced pool
        let coin_in = test_utils::mint_coin<USDC>(10_000_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify D is maintained
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        assertions::assert_d_invariant_maintained(&before, &after);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EInvalidAmp)]
    fun test_invalid_amp_zero() {
        let mut scenario = ts::begin(@0x1);
        
        // Try to create pool with amp=0 (should fail)
        let pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 0, ts::ctx(&mut scenario));
        
        // Cleanup (won't reach here)
        stable_pool::share(pool);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EInvalidAmp)]
    fun test_invalid_amp_too_high() {
        let mut scenario = ts::begin(@0x1);
        
        // Try to create pool with amp > MAX_AMP (1000) (should fail)
        let pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1001, ts::ctx(&mut scenario));
        
        // Cleanup (won't reach here)
        stable_pool::share(pool);
        ts::end(scenario);
    }

    #[test]
    fun test_min_amp_behavior() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with MIN_AMP (1) - should behave like constant product
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Execute swap
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // With amp=1, should have more slippage than high amp pools
        // Just verify it works without errors
        assert!(coin::value(&coin_out) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_max_amp_behavior() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with MAX_AMP (1000) - should have minimal slippage
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1000, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = stable_pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Execute swap
        let amount_in = 10_000_000u64;
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        // With max amp, should have very minimal slippage
        let expected_output = amount_in - (amount_in * 5 / 10000); // Subtract fee
        assertions::assert_slippage_within(expected_output, actual_output, 5); // < 0.05% slippage
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
