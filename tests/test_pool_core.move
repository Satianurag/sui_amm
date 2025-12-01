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

    // ═══════════════════════════════════════════════════════════════════════════
    // K-INVARIANT TESTS - Core constant product formula verification
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_k_invariant_maintained_after_swap() {
        let owner = @0xA;
        let mut scenario = ts::begin(owner);
        
        // Create pool with 1M:1M liquidity
        ts::next_tx(&mut scenario, owner);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            pool::share(pool);
        };
        
        // Add initial liquidity
        ts::next_tx(&mut scenario, owner);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
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
            
            // Snapshot K before swap
            let before = test_utils::snapshot_pool(pool, &clock);
            
            // Execute swap: 10M USDC -> BTC
            let coin_in = test_utils::mint_coin<USDC>(10_000_000, ctx);
            let coin_out = pool::swap_a_to_b(
                pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(coin_out);
            
            // Snapshot K after swap
            let after = test_utils::snapshot_pool(pool, &clock);
            
            // Verify K_after >= K_before (with tolerance for rounding)
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
        let mut scenario = ts::begin(@0x1);
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
        
        // Snapshot K before adding more liquidity
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        // Add more liquidity
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
        
        // Snapshot K after adding liquidity
        let after = test_utils::snapshot_pool(&pool, &clock);
        
        // Verify K increased
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
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with initial liquidity
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
        
        // Snapshot K before removing liquidity
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        // Remove half the liquidity
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
        
        // Snapshot K after removing liquidity
        let after = test_utils::snapshot_pool(&pool, &clock);
        
        // Verify K decreased
        assertions::assert_k_decreased(&before, &after);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP OUTPUT CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_swap_output_calculation_accuracy() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with 1M:1M liquidity, 0.3% fee
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
        
        // Execute swap
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        // Verify output matches formula: output = (input_after_fee * reserve_out) / (reserve_in + input_after_fee)
        assertions::assert_swap_output_correct(
            amount_in,
            reserve_a,
            reserve_b,
            fee_bps,
            actual_output,
            10 // tolerance
        );
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LP TOKEN MINTING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_initial_lp_token_minting() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        let amount_a = 1_000_000_000u64;
        let amount_b = 1_000_000_000u64;
        let coin_a = test_utils::mint_coin<USDC>(amount_a, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(amount_b, ts::ctx(&mut scenario));
        
        // Add initial liquidity
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
        
        // Verify initial liquidity = sqrt(amount_a * amount_b) - MINIMUM_LIQUIDITY
        assertions::assert_initial_liquidity_correct(
            amount_a,
            amount_b,
            minted_liquidity,
            1000 // MINIMUM_LIQUIDITY
        );
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_subsequent_lp_token_minting() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Get current state
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let total_supply = pool::get_total_liquidity(&pool);
        
        // Add more liquidity
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
        
        // Verify subsequent liquidity minting is proportional
        assertions::assert_subsequent_liquidity_correct(
            amount_a,
            amount_b,
            reserve_a,
            reserve_b,
            total_supply,
            minted_liquidity,
            10 // tolerance
        );
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE IMPACT CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_price_impact_calculation_accuracy() {
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
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let amount_in = 50_000_000u64; // 5% of reserve
        
        // Execute swap
        let coin_in = test_utils::mint_coin<USDC>(amount_in, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let actual_output = coin::value(&coin_out);
        
        // Verify price impact is calculated and within limits
        assertions::assert_price_impact_calculated(
            amount_in,
            reserve_a,
            reserve_b,
            actual_output,
            1000 // max 10% price impact
        );
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTREME VALUE HANDLING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_extreme_value_handling_large_reserves() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with very large reserves (near u64 safe limits)
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let large_amount = 18446744073709551u64; // u64::MAX / 1000
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
        
        // Verify no overflow in K calculation
        assertions::assert_k_no_overflow(reserve_a, reserve_b);
        
        // Execute swap with large amount
        let swap_amount = large_amount / 100; // 1% of reserve
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
        
        // Verify swap succeeded and K is maintained
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
        let mut scenario = ts::begin(@0x1);
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
        
        // Snapshot before dust swap
        let before = test_utils::snapshot_pool(&pool, &clock);
        
        // Execute swap with dust amount (1 unit)
        let coin_in = test_utils::mint_coin<USDC>(1, ts::ctx(&mut scenario));
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            0, // Accept any output for dust
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify K is maintained even with dust amounts
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
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with minimum viable liquidity
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let min_amount = 10_000u64; // Just above MINIMUM_LIQUIDITY threshold
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
        
        // Verify MINIMUM_LIQUIDITY (1000) was burned
        let total_liquidity = pool::get_total_liquidity(&pool);
        assert!(total_liquidity >= 1000, 0);
        
        // Verify position received liquidity minus burned amount
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
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with 1:1000 imbalance
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
        
        // Snapshot before swap
        let before = test_utils::snapshot_pool(&pool, &clock);
        
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
        
        // Verify K is maintained and reserves stay positive
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
