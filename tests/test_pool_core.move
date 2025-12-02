#[test_only]
module sui_amm::test_pool_core {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // K-Invariant Tests
    // Verifies the constant product formula K = reserve_a * reserve_b is maintained
    // K should never decrease after swaps (may increase slightly due to fees)

    #[test]
    fun test_k_invariant_maintained_after_swap() {
        let owner = @0xA;
        let mut scenario = ts::begin(owner);
        
        // Create pool with 1M:1M liquidity
        ts::next_tx(&mut scenario, owner);
        {
            let ctx = ts::ctx(&mut scenario);
            let pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            pool::share(pool);
        };
        
        // Add initial liquidity
        ts::next_tx(&mut scenario, owner);
        {
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            let before = test_utils::snapshot_pool(pool, &clock);
            
            let coin_in = test_utils::mint_coin<USDC>(10_000_000, ctx);
            let coin_out = pool::swap_a_to_b(
                pool,
                coin_in,
                1,
                option::some(18446744073709551615),
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(coin_out);
            
            let after = test_utils::snapshot_pool(pool, &clock);
            
            // Verifies K_after >= K_before (K may increase slightly due to fees)
            assertions::assert_k_invariant_maintained(&before, &after, 10);
            
            // Cleanup
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_k_increases_on_add_liquidity() {
        // Verifies that adding liquidity increases K proportionally
        // This ensures the pool grows correctly as more liquidity is added
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let before = test_utils::snapshot_pool(&pool, &clock);
        
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
        
        let after = test_utils::snapshot_pool(&pool, &clock);
        
        assertions::assert_k_increased(&before, &after);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_k_decreases_on_remove_liquidity() {
        // Verifies that removing liquidity decreases K proportionally
        // This ensures LPs can withdraw their share without breaking the pool
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        let liquidity = position::liquidity(&position);
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
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
        
        let after = test_utils::snapshot_pool(&pool, &clock);
        
        assertions::assert_k_decreased(&before, &after);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // Swap Output Calculation Tests
    // Verifies swap outputs match the constant product formula
    // Formula: output = (input_after_fee * reserve_out) / (reserve_in + input_after_fee)

    #[test]
    fun test_swap_output_calculation_accuracy() {
        // Verifies swap output matches the mathematical formula within tolerance
        // This ensures users receive the correct amount for their swaps
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let amount_in = 10_000_000u64;
        let fee_bps = 30u64;
        
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
        
        assertions::assert_swap_output_correct(
            amount_in,
            reserve_a,
            reserve_b,
            fee_bps,
            actual_output,
            10
        );
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // LP Token Minting Tests
    // Verifies liquidity tokens are minted correctly for initial and subsequent deposits
    // Initial: liquidity = sqrt(amount_a * amount_b) - MINIMUM_LIQUIDITY
    // Subsequent: liquidity = min(amount_a * total_supply / reserve_a, amount_b * total_supply / reserve_b)

    #[test]
    fun test_initial_lp_token_minting() {
        // Verifies initial liquidity minting uses geometric mean formula
        // MINIMUM_LIQUIDITY (1000) is burned to prevent inflation attacks
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        let amount_a = 1_000_000_000u64;
        let amount_b = 1_000_000_000u64;
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
        
        let minted_liquidity = position::liquidity(&position);
        
        // Expected: sqrt(1_000_000_000 * 1_000_000_000) - 1000 = 1_000_000_000 - 1000
        let expected_liquidity = 1_000_000_000 - 1000;
        assert!(minted_liquidity <= expected_liquidity, 0);
        assert!(minted_liquidity >= expected_liquidity - 100000, 1);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_subsequent_lp_token_minting() {
        // Verifies subsequent liquidity minting is proportional to existing reserves
        // This ensures fair distribution of LP tokens based on contribution
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let total_supply = pool::get_total_liquidity(&pool);
        
        let amount_a = 500_000_000u64;
        let amount_b = 500_000_000u64;
        let coin_a2 = test_utils::mint_coin<USDC>(amount_a, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(amount_b, ts::ctx(&mut scenario));
        
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
        
        let minted_liquidity = position::liquidity(&position2);
        
        assertions::assert_subsequent_liquidity_correct(
            amount_a,
            amount_b,
            reserve_a,
            reserve_b,
            total_supply,
            minted_liquidity,
            10
        );
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // Price Impact Calculation Tests
    // Verifies price impact is calculated correctly and stays within acceptable limits
    // Large swaps relative to reserves should have higher price impact

    #[test]
    fun test_price_impact_calculation_accuracy() {
        // Verifies price impact calculation for a 5% swap relative to reserves
        // Price impact should be measurable but within acceptable limits
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let amount_in = 50_000_000u64;
        
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
        
        assertions::assert_price_impact_calculated(
            amount_in,
            reserve_a,
            reserve_b,
            actual_output,
            1000
        );
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // Extreme Value Handling Tests
    // Verifies pool operations handle edge cases without overflow or errors
    // Tests include large reserves, dust amounts, and extreme imbalances

    #[test]
    fun test_extreme_value_handling_large_reserves() {
        // Verifies pool handles near-maximum reserve values without overflow
        // Uses u128 intermediate calculations to prevent u64 * u64 overflow
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = 18446744073709551u64;
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
        
        assertions::assert_k_no_overflow(reserve_a, reserve_b);
        
        let swap_amount = large_amount / 100;
        let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let after = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_reserves_positive(&after);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_dust_amount_handling() {
        // Verifies pool handles extremely small swap amounts gracefully
        // Dust swaps may produce zero output due to rounding, but should not break K invariant
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        let coin_in = test_utils::mint_coin<USDC>(1, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            0,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let after = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_invariant_maintained(&before, &after, 10);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_minimum_liquidity_edge_case() {
        // Verifies MINIMUM_LIQUIDITY (1000) is burned on first deposit
        // This prevents inflation attacks where attackers manipulate the price by donating tokens
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let min_amount = 10_000u64;
        let coin_a = test_utils::mint_coin<USDC>(min_amount, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(min_amount, ts::ctx(&mut scenario));
        
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
        
        let total_liquidity = pool::get_total_liquidity(&pool);
        assert!(total_liquidity >= 1000, 0);
        
        let position_liquidity = position::liquidity(&position);
        assert!(position_liquidity > 0, 1);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_extreme_imbalance_operations() {
        // Verifies pool handles extreme reserve imbalances (1:1000 ratio)
        // Imbalanced pools should still maintain K invariant and positive reserves
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(10_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(10_000_000, ts::ctx(&mut scenario));
        
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
        
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        let coin_in = test_utils::mint_coin<USDC>(100_000_000, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let after = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_invariant_maintained(&before, &after, 100);
        assertions::assert_reserves_positive(&after);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
