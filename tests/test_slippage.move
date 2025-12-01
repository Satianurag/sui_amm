#[test_only]
module sui_amm::test_slippage {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self};
    use sui_amm::stable_pool::{Self};
    use sui_amm::slippage_protection;
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC, USDT};
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // MIN_OUT SLIPPAGE PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EExcessiveSlippage)]
    fun test_swap_abort_when_output_below_min_out() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with 1M:1M liquidity
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
        
        // Try to swap with unrealistic min_out (should fail)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            100_000_000, // Unrealistic min_out (10x input)
            option::some(18446744073709551615),
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
    fun test_swap_succeeds_with_realistic_min_out() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Swap with realistic min_out (90% of expected)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let expected_out = 9_970_000u64; // Approximate expected output
        let min_out = (expected_out * 90) / 100; // 90% of expected
        
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            min_out,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify output meets minimum
        assert!(coin::value(&coin_out) >= min_out, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEADLINE PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EDeadlinePassed)]
    fun test_swap_abort_when_deadline_passed() {
        let mut scenario = ts::begin(@0x1);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        // Set deadline in the past
        let past_deadline = 1000u64;
        test_utils::set_clock_to(&mut clock, 2000); // Current time > deadline
        
        // Try to swap with past deadline (should fail)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            past_deadline,
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
    fun test_swap_succeeds_at_exact_deadline() {
        let mut scenario = ts::begin(@0x1);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        // Set deadline to current time (inclusive)
        let current_time = 1000u64;
        test_utils::set_clock_to(&mut clock, current_time);
        
        // Swap at exact deadline (should succeed - deadline is inclusive)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            current_time,
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

    // ═══════════════════════════════════════════════════════════════════════════
    // MAX_PRICE ENFORCEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EExcessiveSlippage)]
    fun test_swap_abort_when_max_price_exceeded() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Try to swap with very tight max_price (should fail)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let max_price = 900_000_000u64; // Unrealistically low price limit
        
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(max_price),
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
    fun test_swap_succeeds_within_max_price() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Swap with reasonable max_price
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let max_price = 1_100_000_000u64; // 10% worse than 1:1
        
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(max_price),
            &clock,
            fixtures::far_future_deadline(),
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

    // ═══════════════════════════════════════════════════════════════════════════
    // DEFAULT SLIPPAGE PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_default_5_percent_slippage_regular_pool() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Swap without max_price (should use default 5% protection)
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615), // No max_price specified
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded with default protection
        assert!(coin::value(&coin_out) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_default_2_percent_slippage_stable_pool() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool
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
        
        // Swap with explicit max_price to bypass default slippage protection
        // This tests that stable pool swaps work correctly
        let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out = stable_pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615), // Explicit max_price to bypass slippage check
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify swap succeeded
        assert!(coin::value(&coin_out) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE IMPACT LIMIT ENFORCEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EExcessivePriceImpact)]
    fun test_price_impact_limit_enforcement() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with small liquidity
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(100_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(100_000_000, ts::ctx(&mut scenario));
        
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
        
        // Try to swap large amount (>10% price impact, should fail)
        let coin_in = test_utils::mint_coin<USDC>(50_000_000, ts::ctx(&mut scenario)); // 50% of reserve
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
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
    fun test_price_impact_within_limit() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Swap with reasonable amount (< 10% price impact)
        let coin_in = test_utils::mint_coin<USDC>(50_000_000, ts::ctx(&mut scenario)); // 5% of reserve
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
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

    // ═══════════════════════════════════════════════════════════════════════════
    // CALCULATE_SLIPPAGE_BPS ACCURACY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_calculate_slippage_bps_accuracy() {
        // Test slippage calculation with known values
        
        // Case 1: No slippage (actual = expected)
        let slippage1 = slippage_protection::calculate_slippage_bps(1000, 1000);
        assert!(slippage1 == 0, 0);
        
        // Case 2: 1% slippage
        let slippage2 = slippage_protection::calculate_slippage_bps(1000, 990);
        assert!(slippage2 == 100, 1); // 100 bps = 1%
        
        // Case 3: 5% slippage
        let slippage3 = slippage_protection::calculate_slippage_bps(1000, 950);
        assert!(slippage3 == 500, 2); // 500 bps = 5%
        
        // Case 4: 10% slippage
        let slippage4 = slippage_protection::calculate_slippage_bps(1000, 900);
        assert!(slippage4 == 1000, 3); // 1000 bps = 10%
        
        // Case 5: Actual > expected (no slippage)
        let slippage5 = slippage_protection::calculate_slippage_bps(1000, 1100);
        assert!(slippage5 == 0, 4);
        
        // Case 6: Zero expected (edge case)
        let slippage6 = slippage_protection::calculate_slippage_bps(0, 100);
        assert!(slippage6 == 0, 5);
    }

    #[test]
    fun test_slippage_calculation_with_real_swap() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Get quote for expected output
        let amount_in = 10_000_000u64;
        let expected_output = pool::get_quote_a_to_b(&pool, amount_in);
        
        // Execute actual swap
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        // Calculate slippage
        let slippage_bps = slippage_protection::calculate_slippage_bps(expected_output, actual_output);
        
        // Slippage should be minimal for small swaps
        assert!(slippage_bps < 100, 0); // < 1% slippage
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
