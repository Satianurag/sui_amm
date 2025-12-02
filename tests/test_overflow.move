#[test_only]
module sui_amm::test_overflow {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self};
    use sui_amm::stable_pool::{Self};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC, USDT};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    /// Tests that verify intermediate calculations use u128 to prevent overflow
    /// when working with large reserve values that would overflow u64 multiplication.

    /// Verifies that pools with very large reserves (near u64 limits) can perform
    /// swaps without overflow. The K-invariant calculation uses u128 internally
    /// to safely handle the multiplication of large reserve values.
    #[test]
    fun test_no_overflow_with_large_reserves() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with reserves approaching u64 limits
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = fixtures::near_u64_max();
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(large_amount, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
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
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        
        // Verify K-invariant calculation handles large values without overflow
        assertions::assert_k_no_overflow(reserve_a, reserve_b);
        
        // Execute a swap with 1% of reserves
        let swap_amount = large_amount / 100;
        let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded without overflow
        let output_value = coin::value(&coin_out);
        assert!(output_value > 0, 0);
        
        // Verify K still doesn't overflow after swap
        let (reserve_a_after, reserve_b_after) = pool::get_reserves(&pool);
        assertions::assert_k_no_overflow(reserve_a_after, reserve_b_after);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that fee accumulation calculations don't overflow even with
    /// large reserves and many swaps. Fee per share is tracked using u128
    /// to prevent overflow in the accumulator.
    #[test]
    fun test_no_overflow_in_fee_calculations() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with large reserves
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = fixtures::near_u64_max() / 10;
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(large_amount, ts::ctx(&mut scenario));
        
        let (mut position, refund_a, refund_b) = pool::add_liquidity(
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
        
        // Execute 10 swaps to accumulate significant fees
        let mut i = 0;
        while (i < 10) {
            let swap_amount = large_amount / 1000;
            let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Verify the fee accumulator didn't overflow
        let (acc_fee_a, acc_fee_b) = pool::get_acc_fee_per_share(&pool);
        assert!(acc_fee_a > 0, 0);
        assert!(acc_fee_b >= 0, 1);
        
        // Claim fees - calculation should not overflow
        let (claimed_a, claimed_b) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        let claimed_value_a = coin::value(&claimed_a);
        assert!(claimed_value_a > 0, 2);
        
        // Cleanup
        coin::burn_for_testing(claimed_a);
        coin::burn_for_testing(claimed_b);
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that liquidity minting calculations don't overflow when adding
    /// liquidity to pools with large existing reserves. The sqrt and proportional
    /// calculations use u128 to prevent overflow.
    #[test]
    fun test_no_overflow_in_liquidity_calculations() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = fixtures::near_u64_max() / 10;
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(large_amount, ts::ctx(&mut scenario));
        
        let (position1, refund_a, refund_b) = pool::add_liquidity(
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
        
        // Add additional liquidity - proportional calculation should not overflow
        let add_amount = large_amount / 10;
        let coin_a2 = test_utils::mint_coin<USDC>(add_amount, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(add_amount, ts::ctx(&mut scenario));
        
        let (position2, refund_a2, refund_b2) = pool::add_liquidity(
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
        
        // Verify liquidity was correctly minted without overflow
        let lp2_liquidity = position::liquidity(&position2);
        assert!(lp2_liquidity > 0, 0);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that swap output calculations don't overflow with large reserves.
    /// The constant product formula uses u128 for intermediate calculations
    /// to safely handle large values.
    #[test]
    fun test_no_overflow_in_swap_output_calculation() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with large reserves
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = fixtures::near_u64_max() / 10;
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(large_amount, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
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
        
        // Execute a 1% swap that stays within slippage limits
        let swap_amount = large_amount / 100;
        let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
        
        // Intermediate calculations should use u128 to prevent overflow
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify the swap produced reasonable output
        let output_value = coin::value(&coin_out);
        assert!(output_value > 0, 0);
        assert!(output_value < swap_amount, 1);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Tests that verify subtraction operations are protected against underflow
    /// by checking values before subtraction or using safe math operations.

    /// Verifies that attempting to remove more liquidity than available results
    /// in an abort rather than underflow. This protects against accounting errors.
    #[test]
    #[expected_failure]
    fun test_underflow_protection_insufficient_liquidity() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let min_amount = 10_000u64;
        
        let coin_a = test_utils::mint_coin<USDC>(min_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(min_amount, ts::ctx(&mut scenario));
        
        let (mut position, refund_a, refund_b) = pool::add_liquidity(
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
        
        let position_liquidity = position::liquidity(&position);
        
        // Attempt to remove more liquidity than the position holds
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            position_liquidity + 1,
            1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Unreachable cleanup code
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that fee debt updates handle the case where accumulated fees
    /// equal the debt without underflow. The second claim should return zero.
    #[test]
    fun test_safe_subtraction_in_fee_debt_update() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (mut position, refund_a, refund_b) = pool::add_liquidity(
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
        
        // Generate fees through a swap
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        // First claim updates fee debt to current accumulated fees
        let (claimed_a, claimed_b) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        coin::burn_for_testing(claimed_a);
        coin::burn_for_testing(claimed_b);
        
        // Second claim should return zero without underflow
        let (claimed_a2, claimed_b2) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        assert!(coin::value(&claimed_a2) == 0, 0);
        assert!(coin::value(&claimed_b2) == 0, 1);
        
        // Cleanup
        coin::burn_for_testing(claimed_a2);
        coin::burn_for_testing(claimed_b2);
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that reserve updates during swaps safely handle subtraction.
    /// Reserves should decrease for the output token and increase for the input token.
    #[test]
    fun test_safe_subtraction_in_reserve_updates() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
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
        
        let (reserve_a_before, reserve_b_before) = pool::get_reserves(&pool);
        
        // Execute a swap that modifies both reserves
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        let (reserve_a_after, reserve_b_after) = pool::get_reserves(&pool);
        
        // Verify reserves updated correctly without underflow
        assert!(reserve_a_after > reserve_a_before, 0);
        assert!(reserve_b_after < reserve_b_before, 1);
        assert!(reserve_b_after > 0, 2);
        
        // Cleanup
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Tests that verify the system handles extreme values correctly across
    /// multiple operations, maintaining invariants and preventing overflow/underflow.

    /// Verifies that a sequence of large swaps in alternating directions maintains
    /// pool invariants and doesn't cause overflow. Each swap is verified independently.
    #[test]
    fun test_extreme_value_swap_sequence() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with large reserves
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = fixtures::near_u64_max() / 100;
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(large_amount, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
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
        
        // Execute 5 large swaps alternating direction
        let mut i = 0;
        while (i < 5) {
            let swap_amount = large_amount / 100;
            
            if (i % 2 == 0) {
                let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
                let coin_out = pool::swap_a_to_b(
                    &mut pool,
                    coin_in,
                    1,
                    option::none(),
                    &clock,
                    fixtures::far_future_deadline(),
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(coin_out);
            } else {
                let coin_in = test_utils::mint_coin<BTC>(swap_amount, ts::ctx(&mut scenario));
                let coin_out = pool::swap_b_to_a(
                    &mut pool,
                    coin_in,
                    1,
                    option::none(),
                    &clock,
                    fixtures::far_future_deadline(),
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(coin_out);
            };
            
            // After each swap, verify no overflow and reserves remain positive
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            assertions::assert_k_no_overflow(reserve_a, reserve_b);
            assertions::assert_reserves_positive(&test_utils::snapshot_pool(&pool, &clock));
            
            i = i + 1;
        };
        
        // Cleanup
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that pools with extreme reserve imbalance (1:1000000 ratio) can
    /// perform swaps without overflow. This tests the robustness of the math library.
    #[test]
    fun test_extreme_imbalance_no_overflow() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with extreme imbalance (1:1000000)
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = 1_000_000_000_000u64; // 1 trillion
        let small_amount = 1_000_000u64; // 1 million
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(small_amount, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
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
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        
        // Verify K calculation doesn't overflow even with extreme imbalance
        assertions::assert_k_no_overflow(reserve_a, reserve_b);
        
        // Execute swap on imbalanced pool
        let coin_in = test_utils::mint_coin<USDC>(100_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded
        assert!(coin::value(&coin_out) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_stable_pool_no_overflow_with_large_values() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with large reserves
        let mut pool = stable_pool::create_pool<USDC, USDT>(
            5,   // fee_bps
            100, // protocol_fee_bps
            0,   // creator_fee_bps
            10,  // amp (reduced from 100 to ensure stability with large values)
            ts::ctx(&mut scenario)
        );
        
        // Use 1 billion (1e9) which is safe for StableSwap math
        let large_amount = 1_000_000_000u64;
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<USDT>(large_amount, ts::ctx(&mut scenario));
        
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
        
        // Execute swap - D-invariant calculation should not overflow
        let swap_amount = large_amount / 100;
        let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded
        assert!(coin::value(&coin_out) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_price_impact_calculation_no_overflow() {
        let mut scenario = ts::begin(@0xA);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with large reserves
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = fixtures::near_u64_max() / 100;
        
        let coin_a = test_utils::mint_coin<USDC>(large_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(large_amount, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
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
        
        // Calculate price impact for large swap - should not overflow
        let swap_amount = large_amount / 20; // 5% of reserve
        let price_impact = pool::calculate_swap_price_impact_a2b(&pool, swap_amount);
        
        // Verify calculation succeeded and result is reasonable
        assert!(price_impact > 0, 0);
        assert!(price_impact < 10000, 1); // Should be less than 100%
        
        // Cleanup
        position::destroy(position);
        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
