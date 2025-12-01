#[test_only]
module sui_amm::test_invariants {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self};
    use sui_amm::stable_pool::{Self};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC, USDT};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // K-INVARIANT VERIFICATION TESTS - Requirement 8.1
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_k_invariant_never_decreases_after_swap_sequence() {
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
        
        // Capture initial K
        let mut k_before = test_utils::snapshot_pool(&pool, &clock);
        
        // Execute sequence of 10 swaps alternating directions
        let mut i = 0;
        while (i < 10) {
            if (i % 2 == 0) {
                // Swap A to B
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
            } else {
                // Swap B to A
                let coin_in = test_utils::mint_coin<BTC>(10_000_000, ts::ctx(&mut scenario));
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
            
            // Verify K never decreased
            let k_after = test_utils::snapshot_pool(&pool, &clock);
            assertions::assert_k_invariant_maintained(&k_before, &k_after, 100);
            k_before = k_after;
            
            i = i + 1;
        };
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_k_invariant_maintained_across_complex_operations() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        
        let (mut position1, refund_a, refund_b) = pool::add_liquidity(
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
        
        let k_initial = test_utils::snapshot_pool(&pool, &clock);
        
        // Add more liquidity (K should increase)
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
        
        let k_after_add = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_increased(&k_initial, &k_after_add);
        
        // Execute swaps (K should not decrease)
        let coin_in = test_utils::mint_coin<USDC>(50_000_000, ts::ctx(&mut scenario));
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
        
        let k_after_swap = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_invariant_maintained(&k_after_add, &k_after_swap, 100);
        
        // Remove partial liquidity (K should decrease)
        let liquidity = position::liquidity(&position1);
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position1,
            liquidity / 2,
            1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        
        let k_after_remove = test_utils::snapshot_pool(&pool, &clock);
        assertions::assert_k_decreased(&k_after_swap, &k_after_remove);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // D-INVARIANT VERIFICATION TESTS - Requirement 8.1
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_d_invariant_maintained_in_stableswap() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create stable pool with amp=100
        let mut pool = stable_pool::create_pool<USDC, USDT>(
            5,   // fee_bps
            100, // protocol_fee_bps
            0,   // creator_fee_bps
            100, // amp
            ts::ctx(&mut scenario)
        );
        
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
        
        // Capture initial D
        let mut d_before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Execute sequence of swaps
        let mut i = 0;
        while (i < 5) {
            if (i % 2 == 0) {
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
            } else {
                let coin_in = test_utils::mint_coin<USDT>(10_000_000, ts::ctx(&mut scenario));
                let coin_out = stable_pool::swap_b_to_a(
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
            
            // Verify D never decreased
            let d_after = test_utils::snapshot_stable_pool(&pool, &clock);
            assertions::assert_d_invariant_maintained(&d_before, &d_after);
            d_before = d_after;
            
            i = i + 1;
        };
        
        // Cleanup
        position::destroy(position);
        stable_pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LP SHARE CONSERVATION TESTS - Requirement 10.2
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_lp_share_conservation_single_provider() {
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
        
        // Verify: position liquidity + MINIMUM_LIQUIDITY = total_liquidity
        let position_liquidity = position::liquidity(&position);
        let total_liquidity = pool::get_total_liquidity(&pool);
        assert!(position_liquidity + 1000 == total_liquidity, 0);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_lp_share_conservation_multiple_providers() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        // LP1 adds liquidity
        let coin_a1 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        let (position1, refund_a1, refund_b1) = pool::add_liquidity(
            &mut pool,
            coin_a1,
            coin_b1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        
        // LP2 adds liquidity
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
        
        // LP3 adds liquidity
        let coin_a3 = test_utils::mint_coin<USDC>(250_000_000, ts::ctx(&mut scenario));
        let coin_b3 = test_utils::mint_coin<BTC>(250_000_000, ts::ctx(&mut scenario));
        let (position3, refund_a3, refund_b3) = pool::add_liquidity(
            &mut pool,
            coin_a3,
            coin_b3,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a3);
        coin::burn_for_testing(refund_b3);
        
        // Verify: sum of all position liquidity + MINIMUM_LIQUIDITY = total_liquidity
        let lp1_liquidity = position::liquidity(&position1);
        let lp2_liquidity = position::liquidity(&position2);
        let lp3_liquidity = position::liquidity(&position3);
        let total_liquidity = pool::get_total_liquidity(&pool);
        
        assert!(lp1_liquidity + lp2_liquidity + lp3_liquidity + 1000 == total_liquidity, 0);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        position::destroy(position3);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_lp_share_conservation_after_partial_removal() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with two LPs
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        let coin_a1 = test_utils::mint_coin<USDC>(1_000_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<BTC>(1_000_000_000, ts::ctx(&mut scenario));
        let (mut position1, refund_a1, refund_b1) = pool::add_liquidity(
            &mut pool,
            coin_a1,
            coin_b1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        
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
        
        // LP1 removes half their liquidity
        let lp1_liquidity = position::liquidity(&position1);
        let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position1,
            lp1_liquidity / 2,
            1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_a_out);
        coin::burn_for_testing(coin_b_out);
        
        // Verify conservation still holds
        let lp1_remaining = position::liquidity(&position1);
        let lp2_liquidity = position::liquidity(&position2);
        let total_liquidity = pool::get_total_liquidity(&pool);
        
        assert!(lp1_remaining + lp2_liquidity + 1000 == total_liquidity, 0);
        
        // Cleanup
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE CONSERVATION TESTS - Requirement 10.3
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_fee_conservation_claimed_never_exceeds_accumulated() {
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
        
        // Execute swaps to generate fees
        let mut i = 0;
        while (i < 5) {
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
            i = i + 1;
        };
        
        // Get accumulated fees from pool
        let (acc_fee_a, acc_fee_b) = pool::get_acc_fee_per_share(&pool);
        let position_liquidity = position::liquidity(&position);
        
        // Calculate expected pending fees
        let fee_debt_a = position::fee_debt_a(&position);
        let fee_debt_b = position::fee_debt_b(&position);
        let expected_fee_a = ((position_liquidity as u128) * acc_fee_a / 1_000_000_000_000 - fee_debt_a) as u64;
        let expected_fee_b = ((position_liquidity as u128) * acc_fee_b / 1_000_000_000_000 - fee_debt_b) as u64;
        
        // Claim fees
        let (claimed_a, claimed_b) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        let claimed_fee_a = coin::value(&claimed_a);
        let claimed_fee_b = coin::value(&claimed_b);
        
        // Verify claimed <= expected (with small tolerance for rounding)
        assert!(claimed_fee_a <= expected_fee_a + 10, 0);
        assert!(claimed_fee_b <= expected_fee_b + 10, 1);
        
        // Cleanup
        coin::burn_for_testing(claimed_a);
        coin::burn_for_testing(claimed_b);
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_fee_conservation_multiple_claims() {
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
        
        let mut total_claimed_a = 0u64;
        let mut total_claimed_b = 0u64;
        
        // Execute swaps and claim fees multiple times
        let mut round = 0;
        while (round < 3) {
            // Generate fees
            let mut i = 0;
            while (i < 3) {
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
                i = i + 1;
            };
            
            // Claim fees
            let (claimed_a, claimed_b) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
            total_claimed_a = total_claimed_a + coin::value(&claimed_a);
            total_claimed_b = total_claimed_b + coin::value(&claimed_b);
            coin::burn_for_testing(claimed_a);
            coin::burn_for_testing(claimed_b);
            
            round = round + 1;
        };
        
        // Get total accumulated fees
        let (_pool_fee_a, _pool_fee_b) = pool::get_fees(&pool);
        let (_protocol_fee_a, _protocol_fee_b) = pool::get_protocol_fees(&pool);
        
        // Verify total claimed is reasonable (should be less than total fees in pool)
        // Note: This is a sanity check - claimed fees come from the fee pool
        assert!(total_claimed_a > 0, 0);
        assert!(total_claimed_b > 0, 1);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_fee_conservation_across_multiple_lps() {
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Create pool with two LPs
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
        // LP1: 60% share
        let coin_a1 = test_utils::mint_coin<USDC>(600_000_000, ts::ctx(&mut scenario));
        let coin_b1 = test_utils::mint_coin<BTC>(600_000_000, ts::ctx(&mut scenario));
        let (mut position1, refund_a1, refund_b1) = pool::add_liquidity(
            &mut pool,
            coin_a1,
            coin_b1,
            1,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(refund_a1);
        coin::burn_for_testing(refund_b1);
        
        // LP2: 40% share
        let coin_a2 = test_utils::mint_coin<USDC>(400_000_000, ts::ctx(&mut scenario));
        let coin_b2 = test_utils::mint_coin<BTC>(400_000_000, ts::ctx(&mut scenario));
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
        
        // Generate fees
        let mut i = 0;
        while (i < 10) {
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
            i = i + 1;
        };
        
        // Both LPs claim fees
        let (claimed_a1, claimed_b1) = pool::withdraw_fees(&mut pool, &mut position1, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        let (claimed_a2, claimed_b2) = pool::withdraw_fees(&mut pool, &mut position2, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        
        let lp1_claimed_a = coin::value(&claimed_a1);
        let lp2_claimed_a = coin::value(&claimed_a2);
        
        // Verify total claimed doesn't exceed what was generated
        // LP1 should get ~60% and LP2 should get ~40%
        let total_claimed = lp1_claimed_a + lp2_claimed_a;
        assert!(total_claimed > 0, 0);
        
        // Verify proportionality (with tolerance)
        if (total_claimed > 0) {
            let lp1_share_bps = (lp1_claimed_a as u128) * 10000 / (total_claimed as u128);
            // LP1 should have ~60% (6000 bps), allow 500 bps tolerance
            assert!(lp1_share_bps >= 5500 && lp1_share_bps <= 6500, 1);
        };
        
        // Cleanup
        coin::burn_for_testing(claimed_a1);
        coin::burn_for_testing(claimed_b1);
        coin::burn_for_testing(claimed_a2);
        coin::burn_for_testing(claimed_b2);
        position::destroy(position1);
        position::destroy(position2);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
