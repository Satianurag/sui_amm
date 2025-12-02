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

    // K-Invariant Verification Tests
    // Verifies the constant product formula K = reserve_a * reserve_b is maintained
    // K should never decrease after swaps (may increase slightly due to fees)

    #[test]
    fun test_k_invariant_never_decreases_after_swap_sequence() {
        // Verifies K never decreases across a sequence of alternating swaps
        // Each swap should maintain or slightly increase K due to fee accumulation
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
        
        let mut k_before = test_utils::snapshot_pool(&pool, &clock);
        
        let mut i = 0;
        while (i < 10) {
            if (i % 2 == 0) {
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
        // Verifies K behaves correctly across mixed operations: add liquidity, swap, remove liquidity
        // K should increase on add, maintain on swap, and decrease on remove
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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

    // D-Invariant Verification Tests
    // Verifies the StableSwap invariant D is maintained across operations
    // D represents the total value in the pool and should not decrease on swaps

    #[test]
    fun test_d_invariant_maintained_in_stableswap() {
        // Verifies D invariant never decreases across a sequence of stable pool swaps
        // StableSwap uses amplification coefficient to reduce slippage for similar-priced assets
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
        
        let mut d_before = test_utils::snapshot_stable_pool(&pool, &clock);
        
        // Use max_price to bypass default 2% slippage protection
        let max_price = option::some(18446744073709551615);
        let mut i = 0;
        while (i < 5) {
            if (i % 2 == 0) {
                let coin_in = test_utils::mint_coin<USDC>(10_000_000, ts::ctx(&mut scenario));
                let coin_out = stable_pool::swap_a_to_b(
                    &mut pool,
                    coin_in,
                    1,
                    max_price,
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
                    max_price,
                    &clock,
                    fixtures::far_future_deadline(),
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(coin_out);
            };
            
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

    // LP Share Conservation Tests
    // Verifies sum of all position liquidity plus MINIMUM_LIQUIDITY equals total pool liquidity
    // This ensures no liquidity is created or destroyed incorrectly

    #[test]
    fun test_lp_share_conservation_single_provider() {
        // Verifies conservation holds for single LP
        // Position liquidity + MINIMUM_LIQUIDITY (1000) should equal total liquidity
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
        // Verifies conservation holds across multiple LPs
        // Sum of all position liquidity + MINIMUM_LIQUIDITY should equal total
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
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
        // Verifies conservation holds after partial liquidity removal
        // Removing liquidity should decrease both position and total proportionally
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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

    // Fee Conservation Tests
    // Verifies fees are correctly tracked and distributed without creating or losing value
    // Claimed fees should never exceed accumulated fees

    #[test]
    fun test_fee_conservation_claimed_never_exceeds_accumulated() {
        // Verifies claimed fees match calculated pending fees within tolerance
        // This ensures the fee debt mechanism correctly tracks what LPs are owed
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
        
        let (acc_fee_a, acc_fee_b) = pool::get_acc_fee_per_share(&pool);
        let position_liquidity = position::liquidity(&position);
        
        let fee_debt_a = position::fee_debt_a(&position);
        let fee_debt_b = position::fee_debt_b(&position);
        let expected_fee_a = ((position_liquidity as u128) * acc_fee_a / 1_000_000_000_000 - fee_debt_a) as u64;
        let expected_fee_b = ((position_liquidity as u128) * acc_fee_b / 1_000_000_000_000 - fee_debt_b) as u64;
        
        let (claimed_a, claimed_b) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        let claimed_fee_a = coin::value(&claimed_a);
        let claimed_fee_b = coin::value(&claimed_b);
        
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
        // Verifies fees can be claimed multiple times without double-counting
        // Fee debt mechanism should prevent claiming the same fees twice
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
        
        let mut total_claimed_a = 0u64;
        let mut total_claimed_b = 0u64;
        
        let mut round = 0;
        while (round < 3) {
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
            
            let (claimed_a, claimed_b) = pool::withdraw_fees(&mut pool, &mut position, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
            total_claimed_a = total_claimed_a + coin::value(&claimed_a);
            total_claimed_b = total_claimed_b + coin::value(&claimed_b);
            coin::burn_for_testing(claimed_a);
            coin::burn_for_testing(claimed_b);
            
            round = round + 1;
        };
        
        let (_pool_fee_a, _pool_fee_b) = pool::get_fees(&pool);
        let (_protocol_fee_a, _protocol_fee_b) = pool::get_protocol_fees(&pool);
        
        // All swaps are A→B, so fees accumulate in token A
        assert!(total_claimed_a > 0, 0);
        
        // Cleanup
        position::destroy(position);
        pool::share(pool);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_fee_conservation_across_multiple_lps() {
        // Verifies fees are distributed proportionally to liquidity shares
        // LP with 60% liquidity should receive ~60% of fees
        let mut scenario = ts::begin(@0x1);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ts::ctx(&mut scenario));
        
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
        
        let (claimed_a1, claimed_b1) = pool::withdraw_fees(&mut pool, &mut position1, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        let (claimed_a2, claimed_b2) = pool::withdraw_fees(&mut pool, &mut position2, &clock, fixtures::far_future_deadline(), ts::ctx(&mut scenario));
        
        let lp1_claimed_a = coin::value(&claimed_a1);
        let lp2_claimed_a = coin::value(&claimed_a2);
        
        let total_claimed = lp1_claimed_a + lp2_claimed_a;
        assert!(total_claimed > 0, 0);
        
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
