#[test_only]
module sui_amm::test_attack_vectors {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self};
    use sui_amm::position::{Self};
    use sui_amm::admin::{Self, AdminCap};
    use sui_amm::test_utils::{Self, USDC, BTC, USDT};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    /// Tests that verify the system prevents fee double-claiming attacks where
    /// a malicious user attempts to claim the same fees multiple times.

    /// Verifies that claiming fees twice in succession returns zero on the second claim.
    /// This test ensures the fee debt tracking mechanism prevents double-claiming by
    /// updating the position's fee debt after each withdrawal.
    #[test]
    fun test_fee_double_claiming_prevention() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Execute a swap to generate trading fees
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
        
        // First claim should return accumulated fees
        let (claimed_a1, claimed_b1) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        let first_claim_amount = coin::value(&claimed_a1);
        assert!(first_claim_amount > 0, 0);
        
        // Second claim immediately after should return zero, proving double-claim prevention
        let (claimed_a2, claimed_b2) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        assert!(coin::value(&claimed_a2) == 0, 1);
        assert!(coin::value(&claimed_b2) == 0, 2);
        
        // Cleanup
        coin::burn_for_testing(claimed_a1);
        coin::burn_for_testing(claimed_b1);
        coin::burn_for_testing(claimed_a2);
        coin::burn_for_testing(claimed_b2);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that after claiming fees, only newly generated fees can be claimed.
    /// This test ensures the fee debt mechanism correctly tracks what has been claimed
    /// and only allows withdrawal of fees generated after the last claim.
    #[test]
    fun test_fee_double_claiming_after_new_fees() {
        let mut scenario = ts::begin(@0x1);
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
        
        // Generate initial fees through a swap
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
        
        let (claimed_a1, claimed_b1) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        coin::burn_for_testing(claimed_a1);
        coin::burn_for_testing(claimed_b1);
        
        // Generate additional fees through another swap
        let coin_in2 = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
        let coin_out2 = pool::swap_a_to_b(
            &mut pool,
            coin_in2,
            1,
            option::none(),
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out2);
        
        // Claim again - should only receive newly generated fees, not previously claimed fees
        let (claimed_a2, claimed_b2) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        assert!(coin::value(&claimed_a2) > 0, 0);
        
        // Cleanup
        coin::burn_for_testing(claimed_a2);
        coin::burn_for_testing(claimed_b2);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Tests that verify the system prevents pool draining attacks where a malicious
    /// user attempts to extract all liquidity from a pool through large swaps.

    /// Verifies that even with a massive swap (90% of reserves), the pool maintains
    /// positive reserves and never reaches zero. The constant product formula ensures
    /// that complete pool draining is mathematically impossible.
    #[test]
    fun test_pool_draining_prevention_large_swap() {
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
        
        // Disable price impact protection to isolate pool draining prevention mechanism
        pool::set_risk_params_for_testing(&mut pool, 50, 10000);
        
        // Attempt to drain 90% of the pool's reserves through a single massive swap
        let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
        let huge_swap = (reserve_a as u128) * 90 / 100;
        let coin_in = test_utils::mint_coin<USDC>((huge_swap as u64), ts::ctx(&mut scenario));
        
        let coin_out = pool::swap_a_to_b(
            &mut pool,
            coin_in,
            1,
            option::some(18446744073709551615), // Explicit max_price to bypass default slippage protection
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify that despite the massive swap, both reserves remain positive
        let snapshot = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_reserves_positive(&snapshot);
        
        // Cleanup
        coin::burn_for_testing(coin_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that multiple sequential large swaps cannot drain the pool.
    /// Each swap reduces available liquidity, making subsequent swaps progressively
    /// less effective at extracting value, ensuring reserves always remain positive.
    #[test]
    fun test_pool_draining_prevention_sequential_swaps() {
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
        
        // Execute 10 consecutive swaps, each consuming 10% of current reserves
        let mut i = 0;
        while (i < 10) {
            let (reserve_a, _) = pool::get_reserves(&pool);
            let swap_amount = reserve_a / 10;
            
            let coin_in = test_utils::mint_coin<USDC>(swap_amount, ts::ctx(&mut scenario));
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::some(18446744073709551615), // Explicit max_price to bypass default slippage protection
                &clock,
                fixtures::far_future_deadline(),
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            
            // After each swap, verify reserves remain positive
            let snapshot = test_utils::snapshot_pool(&pool, &clock);
            assertions::assert_reserves_positive(&snapshot);
            
            i = i + 1;
        };
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Tests that verify the emergency pause mechanism correctly blocks all pool
    /// operations when activated by an admin, preventing operations during security incidents.

    /// Verifies that swap operations are blocked when a pool is paused.
    /// This emergency mechanism allows admins to halt trading during security incidents
    /// or critical bugs without affecting other pools.
    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EPaused)]
    fun test_paused_pool_blocks_swaps() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap using test_init which properly transfers to sender
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
        };
        
        // Create pool
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            transfer::public_transfer(position, admin);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Pause pool
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            admin::pause_pool(&admin_cap, pool, &clock);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        
        // Attempt to execute a swap on the paused pool - should abort with EPaused
        ts::next_tx(&mut scenario, admin);
        {
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
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
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Verifies that liquidity addition is blocked when a pool is paused.
    /// This prevents users from adding liquidity during emergency situations
    /// when the pool state may be compromised.
    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EPaused)]
    fun test_paused_pool_blocks_add_liquidity() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap using test_init which properly transfers to sender
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
        };
        
        // Create pool
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            transfer::public_transfer(position, admin);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Pause pool
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            admin::pause_pool(&admin_cap, pool, &clock);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        
        // Attempt to add liquidity to the paused pool - should abort with EPaused
        ts::next_tx(&mut scenario, admin);
        {
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let coin_a = test_utils::mint_coin<USDC>(100_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(100_000_000, ctx);
            
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
            transfer::public_transfer(position, admin);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Tests that verify the slippage protection mechanism defends against sandwich
    /// attacks where an attacker front-runs and back-runs a victim's transaction.

    /// Verifies that slippage protection limits the damage from sandwich attacks.
    /// When an attacker front-runs a victim's swap to manipulate the price, the victim's
    /// min_out parameter ensures they receive acceptable output despite the price manipulation.
    #[test]
    fun test_sandwich_attack_resistance_via_slippage() {
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
        
        let victim_amount = 10_000_000u64;
        
        // Calculate expected output before any price manipulation
        let (_reserve_a, _reserve_b) = pool::get_reserves(&pool);
        let expected_output = pool::get_quote_a_to_b(&pool, victim_amount);
        
        // Attacker front-runs with a 2% swap to manipulate the price
        let attacker_frontrun = test_utils::mint_coin<USDC>(20_000_000, ts::ctx(&mut scenario));
        let attacker_out1 = pool::swap_a_to_b(
            &mut pool,
            attacker_frontrun,
            1,
            option::some(18446744073709551615), // Explicit max_price to bypass default slippage protection
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Victim's swap with 10% slippage tolerance protects against excessive losses
        let min_out = (expected_output as u128) * 90 / 100;
        let victim_swap = test_utils::mint_coin<USDC>(victim_amount, ts::ctx(&mut scenario));
        let victim_out = pool::swap_a_to_b(
            &mut pool,
            victim_swap,
            (min_out as u64),
            option::some(18446744073709551615), // Explicit max_price to bypass default slippage protection
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify the victim received output within their acceptable slippage tolerance
        let actual_output = coin::value(&victim_out);
        assert!(actual_output >= (min_out as u64), 0);
        
        // Cleanup
        coin::burn_for_testing(attacker_out1);
        coin::burn_for_testing(victim_out);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Tests that verify the amplification coefficient (amp) in stable pools is bounded
    /// to prevent manipulation attacks that could destabilize the pool.

    /// Verifies that stable pools can be created with amp values at the minimum (1)
    /// and maximum (1000) bounds, and that these pools function correctly.
    /// The amp parameter controls the curve's flatness in stable pools.
    #[test]
    fun test_amp_bounded_by_min_max() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create a stable pool with the minimum allowed amp value
        let mut pool_min = stable_pool::create_pool<USDC, USDT>(
            5,   // fee_bps
            100, // protocol_fee_bps
            0,   // creator_fee_bps
            1,   // MIN_AMP
            ts::ctx(&mut scenario)
        );
        
        let coin_a1 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position1, refund_a1, refund_b1) = stable_pool::add_liquidity(
            &mut pool_min,
            coin_a1,
            coin_b1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        
        // Verify the pool operates correctly with minimum amp
        let current_amp_min = stable_pool::get_current_amp(&pool_min, &clock);
        assert!(current_amp_min == 1, 0);
        
        // Create a second pool with maximum amp to test the upper bound
        let mut pool_max = stable_pool::create_pool<USDC, USDT>(
            5,    // fee_bps
            100,  // protocol_fee_bps
            0,    // creator_fee_bps
            1000, // MAX_AMP
            ts::ctx(&mut scenario)
        );
        
        let coin_a2 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<USDT>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (position2, refund_a2, refund_b2) = stable_pool::add_liquidity(
            &mut pool_max,
            coin_a2,
            coin_b2,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a2);
        coin::burn_for_testing(refund_b2);
        
        // Verify the pool operates correctly with maximum amp
        let current_amp_max = stable_pool::get_current_amp(&pool_max, &clock);
        assert!(current_amp_max == 1000, 1);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        stable_pool::share(pool_min);
        stable_pool::share(pool_max);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Verifies that attempting to create a stable pool with amp exceeding the maximum
    /// bound (1000) results in an abort. This prevents manipulation attacks that could
    /// destabilize the pool by using extreme amplification values.
    #[test]
    #[expected_failure]
    fun test_amp_cannot_exceed_max() {
        let mut scenario = ts::begin(@0x1);
        
        // Attempt to create a pool with amp = 1001, which exceeds MAX_AMP
        let pool = stable_pool::create_pool<USDC, USDT>(
            5,
            100,
            0,
            1001,
            ts::ctx(&mut scenario)
        );
        
        stable_pool::share(pool);
        ts::end(scenario);
    }

    /// Verifies that attempting to create a stable pool with amp below the minimum
    /// bound (1) results in an abort. This ensures the pool maintains stable swap
    /// characteristics and prevents degenerate behavior.
    #[test]
    #[expected_failure]
    fun test_amp_cannot_be_below_min() {
        let mut scenario = ts::begin(@0x1);
        
        // Attempt to create a pool with amp = 0, which is below MIN_AMP
        let pool = stable_pool::create_pool<USDC, USDT>(
            5,
            100,
            0,
            0,
            ts::ctx(&mut scenario)
        );
        
        stable_pool::share(pool);
        ts::end(scenario);
    }
}
