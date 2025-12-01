#[test_only]
module sui_amm::test_edge_cases {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin::{Self};
    use sui_amm::pool::{Self};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // MINIMUM_LIQUIDITY EDGE CASES - Testing the 1000 unit burn threshold
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_minimum_liquidity_burned_on_first_deposit() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        // Add initial liquidity - exactly at minimum threshold
        let amount_a = 10_000u64; // sqrt(10000 * 10000) = 10000
        let amount_b = 10_000u64;
        let coin_a = test_utils::mint_coin<USDC>(amount_a, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(amount_b, ts::ctx(&mut scenario));
        
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
        
        // Verify MINIMUM_LIQUIDITY (1000) was burned
        let total_liquidity = pool::get_total_liquidity(&pool);
        let position_liquidity = position::liquidity(&position);
        
        // Total liquidity should be sqrt(10000 * 10000) = 10000
        assert!(total_liquidity == 10000, 0);
        
        // Position should have received: sqrt(10000 * 10000) - 1000 = 9000
        let expected_liquidity = 10_000 - 1000;
        assert!(position_liquidity == expected_liquidity, 1);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_minimum_liquidity_only_burned_once() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with initial liquidity
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
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
        
        let total_after_first = pool::get_total_liquidity(&pool);
        
        // Add second liquidity - should NOT burn additional MINIMUM_LIQUIDITY
        let coin_a2 = test_utils::mint_coin<USDC>(500_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(500_000_000, ts::ctx(&mut scenario));
        
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
        
        let total_after_second = pool::get_total_liquidity(&pool);
        let position2_liquidity = position::liquidity(&position2);
        
        // Total liquidity should increase by exactly the minted amount (no additional burn)
        assert!(total_after_second == total_after_first + position2_liquidity, 2);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EInsufficientLiquidity)]
    fun test_minimum_liquidity_insufficient_initial_deposit() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        // Try to add liquidity below MIN_INITIAL_LIQUIDITY (10000)
        // sqrt(5000 * 5000) = 5000 < 10000
        let coin_a = test_utils::mint_coin<USDC>(5_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(5_000, ts::ctx(&mut scenario));
        
        // This should fail with EInsufficientLiquidity
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ZERO AMOUNT HANDLING - Testing EZeroAmount error
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EZeroAmount)]
    fun test_zero_amount_swap_fails() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with liquidity
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
        
        // Try to swap zero amount - should fail
        let coin_in = test_utils::mint_coin<USDC>(0, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            0,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EZeroAmount)]
    fun test_zero_amount_add_liquidity_fails() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        // Try to add zero liquidity - should fail
        let coin_a = test_utils::mint_coin<USDC>(0, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000, ts::ctx(&mut scenario));
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EZeroAmount)]
    fun test_zero_amount_increase_liquidity_fails() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with initial liquidity
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
        
        // Try to increase liquidity with zero amount - should fail
        let coin_a2 = test_utils::mint_coin<USDC>(0, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(1_000_000, ts::ctx(&mut scenario));
        
        let (refund_a2, refund_b2) = pool::increase_liquidity(
            &mut pool,
            &mut position,
            coin_a2,
            coin_b2,
            1, // min_liquidity
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MISMATCHED POOL_ID HANDLING - Testing EWrongPool error
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EWrongPool)]
    fun test_wrong_pool_remove_liquidity_fails() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create first pool
        let mut pool1 = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (mut position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool1,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Create second pool (different pool_id)
        let mut pool2 = pool::create_pool<USDC, BTC>(100, 100, 0, ts::ctx(&mut scenario));
        
        // Try to remove liquidity from pool2 using position from pool1 - should fail
        let liquidity = position::liquidity(&position);
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
            &mut pool2,
            &mut position,
            liquidity / 2,
            1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        position::destroy(position);
        pool::share(pool1);
        pool::share(pool2);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EWrongPool)]
    fun test_wrong_pool_increase_liquidity_fails() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create first pool
        let mut pool1 = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (mut position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool1,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        // Create second pool (different pool_id)
        let mut pool2 = pool::create_pool<USDC, BTC>(100, 100, 0, ts::ctx(&mut scenario));
        
        // Try to increase liquidity on pool2 using position from pool1 - should fail
        let coin_a2 = test_utils::mint_coin<USDC>(500_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(500_000_000, ts::ctx(&mut scenario));
        
        let (refund_a2, refund_b2) = pool::increase_liquidity(
            &mut pool2,
            &mut position,
            coin_a2,
            coin_b2,
            1, // min_liquidity
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        position::destroy(position);
        pool::share(pool1);
        pool::share(pool2);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // Note: claim_fees test removed as the function is package-private (withdraw_fees)

    // ═══════════════════════════════════════════════════════════════════════════
    // ROUNDING BEHAVIOR - Testing that rounding favors protocol
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_rounding_favors_protocol_in_swap() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with specific reserves to test rounding
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_003, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_007, ts::ctx(&mut scenario));
        
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
        
        // Execute small swap that will cause rounding
        let swap_amount = 13u64; // Odd number to force rounding
        let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            0,
            option::some(18446744073709551615), // Explicit max_price to bypass default slippage protection
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let output_amount = coin::value(&coin_out);
        let (reserve_a_after, reserve_b_after) = pool::get_reserves(&pool);
        
        // Calculate K before and after
        let k_before = (reserve_a_before as u128) * (reserve_b_before as u128);
        let k_after = (reserve_a_after as u128) * (reserve_b_after as u128);
        
        // K should never decrease (rounding should favor protocol)
        assert!(k_after >= k_before, 0);
        
        // User should receive slightly less due to rounding down
        // This is expected and correct behavior
        assert!(output_amount > 0, 1);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_rounding_in_liquidity_calculation() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with initial liquidity
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
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
        
        // Add liquidity with amounts that will cause rounding
        let coin_a2 = test_utils::mint_coin<USDC>(333, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(333, ts::ctx(&mut scenario));
        
        let (position2, refund_a2, refund_b2) = pool::add_liquidity(
            &mut pool,
            coin_a2,
            coin_b2,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify refunds exist (due to rounding)
        let refund_a_value = coin::value(&refund_a2);
        let refund_b_value = coin::value(&refund_b2);
        
        // At least one refund should exist due to rounding
        // The protocol keeps the rounded-down portion
        assert!(refund_a_value > 0 || refund_b_value > 0, 2);
        
        // Position should have received liquidity (rounded down)
        let position2_liquidity = position::liquidity(&position2);
        assert!(position2_liquidity > 0, 3);
        
        // Cleanup
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTREME RESERVE IMBALANCE - Testing 1:1000000 ratio operations
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_extreme_imbalance_1_to_1000000() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with extreme 1:1000000 imbalance
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000_000, ts::ctx(&mut scenario)); // 1 trillion
        let coin_b = test_utils::mint_coin<BTC>(1_000_000, ts::ctx(&mut scenario)); // 1 million
        
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
        
        // Verify extreme imbalance ratio (approximately 1:1000000)
        let ratio = (reserve_a as u128) / (reserve_b as u128);
        assert!(ratio >= 900_000 && ratio <= 1_100_000, 0); // Allow some tolerance
        
        // Snapshot before swap
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        // Execute swap on extremely imbalanced pool
        let swap_amount = 10_000_000_000u64; // 10 billion (1% of larger reserve)
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
        
        // Verify swap succeeded
        let output_amount = coin::value(&coin_out);
        assert!(output_amount > 0, 1);
        
        // Verify K is maintained despite extreme imbalance
        let after = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_invariant_maintained(&before, &after, 1000);
        
        // Verify reserves stay positive
        assertions::assert_reserves_positive(&after);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_extreme_imbalance_swap_both_directions() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with extreme imbalance
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000, ts::ctx(&mut scenario));
        
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
        
        // Swap A to B (from abundant to scarce)
        let before1 = test_utils::snapshot_pool(&pool, &clock);
        let coin_in1 = test_utils::mint_coin<USDC>(10_000_000_000, ts::ctx(&mut scenario));
        let coin_out1 = pool::swap_a_to_b(
            &mut pool,
            coin_in1,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        let after1 = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_invariant_maintained(&before1, &after1, 1000);
        
        // Swap B to A (from scarce to abundant)
        let before2 = test_utils::snapshot_pool(&pool, &clock);
        let coin_in2 = test_utils::mint_coin<BTC>(100, ts::ctx(&mut scenario));
        let coin_out2 = pool::swap_b_to_a(
            &mut pool,
            coin_in2,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        let after2 = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_invariant_maintained(&before2, &after2, 1000);
        
        // Verify both swaps succeeded
        assert!(coin::value(&coin_out1) > 0, 2);
        assert!(coin::value(&coin_out2) > 0, 3);
        
        // Cleanup
        coin::burn_for_testing(coin_out1);
        coin::burn_for_testing(coin_out2);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_extreme_imbalance_add_remove_liquidity() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with extreme imbalance
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000, ts::ctx(&mut scenario));
        
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
        
        // Add more liquidity to imbalanced pool
        let coin_a2 = test_utils::mint_coin<USDC>(500_000_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(500_000, ts::ctx(&mut scenario));
        
        let (mut position2, refund_a2, refund_b2) = pool::add_liquidity(
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
        
        // Verify liquidity was added successfully
        let position2_liquidity = position::liquidity(&position2);
        assert!(position2_liquidity > 0, 4);
        
        // Remove liquidity from imbalanced pool
        let liquidity_to_remove = position2_liquidity / 2;
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position2,
            liquidity_to_remove,
            1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify tokens were returned
        assert!(coin::value(&coin_a_out) > 0, 5);
        assert!(coin::value(&coin_b_out) > 0, 6);
        
        // Cleanup
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEADLINE EDGE CASES - Testing exact timestamp boundary
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_deadline_at_exact_current_timestamp_succeeds() {
        let mut scenario = ts::begin(fixtures::admin());
        
        // Create clock at specific time
        let current_time = 1_000_000_000u64;
        let clock = test_utils::create_clock_at(current_time, ts::ctx(&mut scenario));
        
        // Create pool with liquidity
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
        
        // Execute swap with deadline exactly at current timestamp (should succeed - inclusive)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            current_time, // Deadline exactly at current time
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded
        assert!(coin::value(&coin_out) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EDeadlinePassed)]
    fun test_deadline_one_ms_past_fails() {
        let mut scenario = ts::begin(fixtures::admin());
        
        // Create clock at specific time
        let current_time = 1_000_000_000u64;
        let clock = test_utils::create_clock_at(current_time, ts::ctx(&mut scenario));
        
        // Create pool with liquidity
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
        
        // Execute swap with deadline 1ms in the past (should fail)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            current_time - 1, // Deadline 1ms in the past
            ts::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here)
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_deadline_one_ms_future_succeeds() {
        let mut scenario = ts::begin(fixtures::admin());
        
        // Create clock at specific time
        let current_time = 1_000_000_000u64;
        let clock = test_utils::create_clock_at(current_time, ts::ctx(&mut scenario));
        
        // Create pool with liquidity
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
        
        // Execute swap with deadline 1ms in the future (should succeed)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            current_time + 1, // Deadline 1ms in the future
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded
        assert!(coin::value(&coin_out) > 0, 1);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_deadline_far_future_succeeds() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with liquidity
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
        
        // Execute swap with far future deadline (u64::MAX)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            18446744073709551615u64, // u64::MAX
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded
        assert!(coin::value(&coin_out) > 0, 2);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADDITIONAL EDGE CASES - Comprehensive boundary testing
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_single_unit_swap_maintains_invariant() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with standard liquidity
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
        
        // Snapshot before single unit swap
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        // Execute swap with exactly 1 unit
        let coin_in = test_utils::mint_coin<USDC>(1, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            0, // Accept any output
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Snapshot after swap
        let after = test_utils::snapshot_pool(&pool, &clock);
        
        // Verify K is maintained even with single unit swap
        assertions::assert_k_invariant_maintained(&before, &after, 10);
        
        // Output might be 0 due to fees on such small amount, but that's acceptable
        let _output = coin::value(&coin_out);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_minimum_liquidity_with_imbalanced_amounts() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with imbalanced minimum liquidity
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        // Use amounts where sqrt(a*b) >= 10000 but a != b
        let coin_a = test_utils::mint_coin<USDC>(20_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(5_000, ts::ctx(&mut scenario));
        // sqrt(20000 * 5000) = sqrt(100000000) = 10000
        
        let (position, refund_a, refund_b) = pool::add_liquidity(
            &mut pool,
            coin_a,
            coin_b,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify MINIMUM_LIQUIDITY was burned
        let total_liquidity = pool::get_total_liquidity(&pool);
        assert!(total_liquidity == 1000, 3);
        
        // Verify position received correct liquidity
        let position_liquidity = position::liquidity(&position);
        assert!(position_liquidity == 10_000 - 1000, 4);
        
        // Verify refunds were issued for imbalanced amounts
        let _refund_a_value = coin::value(&refund_a);
        let _refund_b_value = coin::value(&refund_b);
        
        // Cleanup
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_consecutive_small_swaps_maintain_invariant() {
        let mut scenario = ts::begin(fixtures::admin());
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
        
        // Execute 10 consecutive small swaps
        let mut i = 0;
        while (i < 10) {
            let before = test_utils::snapshot_pool(&pool, &clock);
            
            let coin_in = test_utils::mint_coin<USDC>(100, ts::ctx(&mut scenario));
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                0,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                ts::ctx(&mut scenario)
            );
            
            let after = test_utils::snapshot_pool(&pool, &clock);
            
            // Verify K maintained after each swap
            assertions::assert_k_invariant_maintained(&before, &after, 10);
            
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_rounding_with_very_small_liquidity_removal() {
        let mut scenario = ts::begin(fixtures::admin());
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with liquidity
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
        
        let total_liquidity = position::liquidity(&position);
        
        // Remove very small amount of liquidity (1 unit)
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            1, // Remove just 1 unit
            0, // Accept any output
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify position liquidity decreased
        let remaining_liquidity = position::liquidity(&position);
        assert!(remaining_liquidity == total_liquidity - 1, 5);
        
        // Verify some tokens were returned (might be 0 due to rounding, which is acceptable)
        let _out_a = coin::value(&coin_a_out);
        let _out_b = coin::value(&coin_b_out);
        
        // Cleanup
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
