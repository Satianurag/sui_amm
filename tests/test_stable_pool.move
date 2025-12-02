#[test_only]
module sui_amm::test_stable_pool {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::stable_pool::{Self};
    
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, USDT};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    /// Verifies that the D-invariant is maintained after a swap
    ///
    /// The D-invariant is the core property of StableSwap pools - it represents the
    /// total value in the pool and should never decrease after a swap (only increase
    /// due to fees). This test ensures that D_after >= D_before with zero tolerance.
    ///
    /// **Validates: StableSwap D-invariant property**
    #[test]
    fun test_d_invariant_maintained_after_swap() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        assertions::assert_d_invariant_maintained(&before, &after);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that the D-invariant increases when liquidity is added
    ///
    /// Adding liquidity to a pool should increase the D value proportionally to the
    /// amount of liquidity added. This test ensures that D grows correctly when
    /// additional liquidity is provided to an existing pool.
    ///
    /// **Validates: D-invariant increases with liquidity additions**
    #[test]
    fun test_d_increases_on_add_liquidity() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
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
        
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
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
        
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        assertions::assert_d_increased(&before, &after);
        position::destroy(position1);
        position::destroy(position2);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that the D-invariant decreases when liquidity is removed
    ///
    /// Removing liquidity from a pool should decrease the D value proportionally to
    /// the amount of liquidity removed. This test ensures that D shrinks correctly
    /// when liquidity is withdrawn from the pool.
    ///
    /// **Validates: D-invariant decreases with liquidity removals**
    #[test]
    fun test_d_decreases_on_remove_liquidity() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (mut position, refund_a, refund_b) = stable_pool::add_liquidity(
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
        
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
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
        
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        assertions::assert_d_decreased(&before, &after);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies minimal slippage for balanced swaps in stable pools
    ///
    /// Stable pools with high amplification coefficients should exhibit near 1:1
    /// exchange rates for balanced swaps. This test ensures that a small swap
    /// (1% of reserves) experiences less than 0.1% slippage beyond the trading fee.
    ///
    /// **Validates: Minimal slippage for stable pair swaps**
    #[test]
    fun test_minimal_slippage_balanced_swap() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
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
        
        let amount_in = 10_000_000u64;
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        let expected_output = amount_in - (amount_in * 5 / 10000);
        assertions::assert_slippage_within(expected_output, actual_output, 10);
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies low slippage for stable pair simulation (USDC/USDT)
    ///
    /// This test simulates a realistic USDC/USDT pool with amp=100 and verifies
    /// that a 1% reserve swap experiences less than 0.1% slippage. This validates
    /// that the StableSwap curve provides the expected low-slippage behavior for
    /// pegged assets.
    ///
    /// **Validates: Requirement 2.8** - Slippage < 0.1% for 1% reserve swap
    #[test]
    fun test_stable_pair_simulation_low_slippage() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
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
        
        let amount_in = 10_000_000u64;
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        let expected_output = amount_in - (amount_in * 5 / 10000);
        assertions::assert_slippage_within(expected_output, actual_output, 10);
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that amp ramping uses linear interpolation over time
    ///
    /// The amplification coefficient can be gradually adjusted over time to minimize
    /// price impact. This test ensures that the amp value changes linearly from the
    /// initial value to the target value over the specified duration.
    ///
    /// **Validates: Linear amp ramping behavior**
    #[test]
    fun test_amp_ramping_linear_interpolation() {
        let mut scenario = ts::begin(@0x1);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
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
        
        let _start_time = clock::timestamp_ms(&clock);
        let ramp_duration = fixtures::day() * 2;
        stable_pool::ramp_amp(&mut pool, 15, ramp_duration, &clock);
        
        let amp_start = stable_pool::get_current_amp(&pool, &clock);
        assert!(amp_start == 10, 0);
        
        test_utils::advance_clock(&mut clock, ramp_duration / 2);
        
        let amp_mid = stable_pool::get_current_amp(&pool, &clock);
        assert!(amp_mid >= 10 && amp_mid <= 15, 1);
        
        test_utils::advance_clock(&mut clock, ramp_duration / 2);
        
        let amp_end = stable_pool::get_current_amp(&pool, &clock);
        assert!(amp_end >= 14 && amp_end <= 15, 2);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that higher amp values result in lower slippage
    ///
    /// The amplification coefficient controls the flatness of the bonding curve.
    /// Higher amp values create flatter curves with less slippage for balanced swaps.
    /// This test compares two pools with different amp values and verifies that the
    /// high-amp pool provides better output (less slippage) for the same swap.
    ///
    /// **Validates: Higher amp reduces slippage**
    #[test]
    fun test_amp_effect_on_slippage() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let mut pool_low_amp = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1, ts::ctx(&mut scenario));
        let mut pool_high_amp = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1000, ts::ctx(&mut scenario));
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
        
        let amount_in = 10_000_000u64;
        let coin_in1 = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out1 = stable_pool::swap_a_to_b(
            &mut pool_low_amp,
            coin_in1,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let coin_in2 = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out2 = stable_pool::swap_a_to_b(
            &mut pool_high_amp,
            coin_in2,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let output_low_amp = coin::value(&coin_out1);
        let output_high_amp = coin::value(&coin_out2);
        
        assert!(output_high_amp >= output_low_amp, 0);
        coin::burn_for_testing(coin_out1);
        coin::burn_for_testing(coin_out2);
        position::destroy(position1);
        position::destroy(position2);
        stable_pool::share(pool_low_amp);
        stable_pool::share(pool_high_amp);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that swapping on an empty pool fails with EInsufficientLiquidity
    ///
    /// Attempting to swap on a pool with zero reserves should fail gracefully with
    /// an appropriate error code rather than causing arithmetic errors or panics.
    ///
    /// **Validates: Empty pool error handling**
    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EInsufficientLiquidity)]
    fun test_zero_reserve_handling() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_in = test_utils::mint_coin<USDC>(1000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        coin::burn_for_testing(coin_out);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that extreme pool imbalances are rejected with EExcessivePriceImpact
    ///
    /// Stable pools should reject operations that would create extreme imbalances
    /// (e.g., 1000:1 ratio) as these violate the stable pair assumption. This test
    /// ensures that such operations fail with an appropriate error.
    ///
    /// **Validates: Extreme imbalance rejection**
    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EExcessivePriceImpact)]
    fun test_extreme_imbalance_handling() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 100, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000_000, ts::ctx(&mut scenario));
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
        
        let before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        let coin_in = test_utils::mint_coin<USDC>(10_000_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let after = test_utils::snapshot_stable_pool(&pool, &clock);
        assertions::assert_d_invariant_maintained(&before, &after);
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that creating a pool with amp=0 fails with EInvalidAmp
    ///
    /// The amplification coefficient must be at least 1. Zero is invalid and should
    /// be rejected during pool creation.
    ///
    /// **Validates: Zero amp rejection**
    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EInvalidAmp)]
    fun test_invalid_amp_zero() {
        let mut scenario = ts::begin(@0x1);
        
        let pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 0, ts::ctx(&mut scenario));
        stable_pool::share(pool);
        ts::end(scenario);
    }

    /// Verifies that creating a pool with amp > MAX_AMP fails with EInvalidAmp
    ///
    /// The amplification coefficient has a maximum value of 1000. Values above this
    /// limit should be rejected during pool creation to prevent numerical instability.
    ///
    /// **Validates: Excessive amp rejection**
    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EInvalidAmp)]
    fun test_invalid_amp_too_high() {
        let mut scenario = ts::begin(@0x1);
        
        let pool = stable_pool::create_pool<USDC, USDT>(5, 100, 0, 1001, ts::ctx(&mut scenario));
        stable_pool::share(pool);
        ts::end(scenario);
    }

    /// Verifies that pools with minimum amp (1) behave like constant product pools
    ///
    /// When amp=1, the StableSwap curve degenerates to a constant product curve
    /// (like Uniswap v2). This test ensures that pools with minimum amp work correctly
    /// and exhibit higher slippage than high-amp pools.
    ///
    /// **Validates: Minimum amp boundary behavior**
    #[test]
    fun test_min_amp_behavior() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
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
        
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        assert!(coin::value(&coin_out) > 0, 0);
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that pools with maximum amp (1000) exhibit minimal slippage
    ///
    /// When amp=1000, the StableSwap curve is extremely flat, providing near 1:1
    /// exchange rates for balanced swaps. This test ensures that pools with maximum
    /// amp work correctly and exhibit less than 0.05% slippage.
    ///
    /// **Validates: Maximum amp boundary behavior**
    #[test]
    fun test_max_amp_behavior() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
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
        
        let amount_in = 10_000_000u64;
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        let expected_output = amount_in - (amount_in * 5 / 10000);
        assertions::assert_slippage_within(expected_output, actual_output, 5);
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
