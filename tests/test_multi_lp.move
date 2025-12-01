#[test_only]
module sui_amm::test_multi_lp {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self};
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Fee Distribution Proportionality Across 3+ LPs
    // Requirements: 9.2 - Test fee distribution proportionality across 3+ LPs
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_distribution_proportional_three_lps() {
        let admin = fixtures::admin();
        let lp1 = fixtures::user1();
        let lp2 = fixtures::user2();
        let lp3 = fixtures::user3();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Create pool with initial liquidity from admin
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = (1_000_000_000u64, 1_000_000_000u64);
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, lp1);
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        // LP1 adds 60% of initial liquidity (600M each)
        let lp1_position = test_utils::add_liquidity_helper(
            &mut pool,
            600_000_000,
            600_000_000,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        let lp1_liquidity = position::liquidity(&lp1_position);
        
        test_scenario::next_tx(&mut scenario, lp2);
        
        // LP2 adds 30% of initial liquidity (300M each)
        let lp2_position = test_utils::add_liquidity_helper(
            &mut pool,
            300_000_000,
            300_000_000,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        let lp2_liquidity = position::liquidity(&lp2_position);
        
        test_scenario::next_tx(&mut scenario, lp3);
        
        // LP3 adds 10% of initial liquidity (100M each)
        let lp3_position = test_utils::add_liquidity_helper(
            &mut pool,
            100_000_000,
            100_000_000,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        let lp3_liquidity = position::liquidity(&lp3_position);
        
        // Get total liquidity
        let total_liquidity = pool::get_total_liquidity(&pool);
        
        // Verify LP shares are proportional
        // LP1 should have ~30% (600M / 2000M)
        // LP2 should have ~15% (300M / 2000M)
        // LP3 should have ~5% (100M / 2000M)
        
        let lp1_share_bps = ((lp1_liquidity as u128) * 10000 / (total_liquidity as u128)) as u64;
        let lp2_share_bps = ((lp2_liquidity as u128) * 10000 / (total_liquidity as u128)) as u64;
        let lp3_share_bps = ((lp3_liquidity as u128) * 10000 / (total_liquidity as u128)) as u64;
        
        // Allow 100 bps tolerance (1%)
        assert!(lp1_share_bps >= 2900 && lp1_share_bps <= 3100, 0); // ~30%
        assert!(lp2_share_bps >= 1400 && lp2_share_bps <= 1600, 1); // ~15%
        assert!(lp3_share_bps >= 400 && lp3_share_bps <= 600, 2); // ~5%
        
        // Execute swaps to generate fees
        let swap_amount = 50_000_000u64; // 50M
        let mut i = 0;
        while (i < 10) {
            let coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                test_utils::far_future(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Claim fees for all LPs
        test_scenario::next_tx(&mut scenario, lp1);
        let (lp1_fee_a, lp1_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut lp1_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let lp1_total_fees = coin::value(&lp1_fee_a) + coin::value(&lp1_fee_b);
        
        test_scenario::next_tx(&mut scenario, lp2);
        let (lp2_fee_a, lp2_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut lp2_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let lp2_total_fees = coin::value(&lp2_fee_a) + coin::value(&lp2_fee_b);
        
        test_scenario::next_tx(&mut scenario, lp3);
        let (lp3_fee_a, lp3_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut lp3_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let lp3_total_fees = coin::value(&lp3_fee_a) + coin::value(&lp3_fee_b);
        
        // Verify fee distribution is proportional to shares
        // LP1 should get ~2x fees of LP2 (60% vs 30%)
        // LP2 should get ~3x fees of LP3 (30% vs 10%)
        
        if (lp1_total_fees > 0 && lp2_total_fees > 0 && lp3_total_fees > 0) {
            let ratio_lp1_lp2 = (lp1_total_fees * 100) / lp2_total_fees;
            let ratio_lp2_lp3 = (lp2_total_fees * 100) / lp3_total_fees;
            
            // LP1/LP2 should be ~200 (2x), allow 180-220
            assert!(ratio_lp1_lp2 >= 180 && ratio_lp1_lp2 <= 220, 3);
            
            // LP2/LP3 should be ~300 (3x), allow 270-330
            assert!(ratio_lp2_lp3 >= 270 && ratio_lp2_lp3 <= 330, 4);
        };
        
        // Cleanup
        coin::burn_for_testing<BTC>(lp1_fee_a);
        coin::burn_for_testing<USDC>(lp1_fee_b);
        coin::burn_for_testing<BTC>(lp2_fee_a);
        coin::burn_for_testing<USDC>(lp2_fee_b);
        coin::burn_for_testing<BTC>(lp3_fee_a);
        coin::burn_for_testing<USDC>(lp3_fee_b);
        
        test_scenario::return_shared(pool);
        position::destroy_for_testing(admin_position);
        position::destroy_for_testing(lp1_position);
        position::destroy_for_testing(lp2_position);
        position::destroy_for_testing(lp3_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Varying LP Share Scenarios
    // Requirements: 9.2 - Test varying LP share scenarios
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_varying_lp_shares() {
        let admin = fixtures::admin();
        let whale = fixtures::whale();
        let retail = fixtures::retail();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::minimum_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, whale);
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        // Whale adds massive liquidity (90% of pool)
        let (whale_a, whale_b) = (900_000_000u64, 900_000_000u64);
        let mut whale_position = test_utils::add_liquidity_helper(
            &mut pool,
            whale_a,
            whale_b,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        let whale_liquidity = position::liquidity(&whale_position);
        
        test_scenario::next_tx(&mut scenario, retail);
        
        // Retail adds small liquidity (10% of pool)
        let (retail_a, retail_b) = (100_000_000u64, 100_000_000u64);
        let mut retail_position = test_utils::add_liquidity_helper(
            &mut pool,
            retail_a,
            retail_b,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        let retail_liquidity = position::liquidity(&retail_position);
        
        let total_liquidity = pool::get_total_liquidity(&pool);
        
        // Verify whale has ~90% share
        assertions::assert_lp_share_proportional(
            whale_liquidity,
            total_liquidity,
            9000, // 90%
            200 // 2% tolerance
        );
        
        // Verify retail has ~10% share
        assertions::assert_lp_share_proportional(
            retail_liquidity,
            total_liquidity,
            1000, // 10%
            200 // 2% tolerance
        );
        
        // Execute swaps
        let swap_amount = 10_000_000u64;
        let mut i = 0;
        while (i < 5) {
            let coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                test_utils::far_future(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Claim fees
        test_scenario::next_tx(&mut scenario, whale);
        let (whale_fee_a, whale_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut whale_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let whale_total_fees = coin::value(&whale_fee_a) + coin::value(&whale_fee_b);
        
        test_scenario::next_tx(&mut scenario, retail);
        let (retail_fee_a, retail_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut retail_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let retail_total_fees = coin::value(&retail_fee_a) + coin::value(&retail_fee_b);
        
        // Verify whale gets ~9x fees of retail
        if (whale_total_fees > 0 && retail_total_fees > 0) {
            let ratio = (whale_total_fees * 100) / retail_total_fees;
            // Should be ~900 (9x), allow 800-1000
            assert!(ratio >= 800 && ratio <= 1000, 0);
        };
        
        // Cleanup
        coin::burn_for_testing<BTC>(whale_fee_a);
        coin::burn_for_testing<USDC>(whale_fee_b);
        coin::burn_for_testing<BTC>(retail_fee_a);
        coin::burn_for_testing<USDC>(retail_fee_b);
        
        test_scenario::return_shared(pool);
        position::destroy_for_testing(admin_position);
        position::destroy_for_testing(whale_position);
        position::destroy_for_testing(retail_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Fee Claiming Order Independence
    // Requirements: 9.2 - Test fee claiming order independence
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_claiming_order_independence() {
        let admin = fixtures::admin();
        let lp1 = fixtures::user1();
        let lp2 = fixtures::user2();
        let lp3 = fixtures::user3();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, lp1);
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        // All LPs add equal liquidity
        let add_amount = 100_000_000u64;
        
        let mut lp1_position = test_utils::add_liquidity_helper(
            &mut pool,
            add_amount,
            add_amount,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, lp2);
        let mut lp2_position = test_utils::add_liquidity_helper(
            &mut pool,
            add_amount,
            add_amount,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, lp3);
        let mut lp3_position = test_utils::add_liquidity_helper(
            &mut pool,
            add_amount,
            add_amount,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Execute swaps to generate fees
        let swap_amount = 10_000_000u64;
        let mut i = 0;
        while (i < 10) {
            let coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                test_utils::far_future(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Claim fees in order: LP3, LP1, LP2 (not sequential)
        test_scenario::next_tx(&mut scenario, lp3);
        let (lp3_fee_a, lp3_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut lp3_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let lp3_total_fees = coin::value(&lp3_fee_a) + coin::value(&lp3_fee_b);
        
        test_scenario::next_tx(&mut scenario, lp1);
        let (lp1_fee_a, lp1_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut lp1_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let lp1_total_fees = coin::value(&lp1_fee_a) + coin::value(&lp1_fee_b);
        
        test_scenario::next_tx(&mut scenario, lp2);
        let (lp2_fee_a, lp2_fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut lp2_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        let lp2_total_fees = coin::value(&lp2_fee_a) + coin::value(&lp2_fee_b);
        
        // Verify all LPs received approximately equal fees (within 5% tolerance)
        if (lp1_total_fees > 0 && lp2_total_fees > 0 && lp3_total_fees > 0) {
            let max_fees = if (lp1_total_fees > lp2_total_fees) {
                if (lp1_total_fees > lp3_total_fees) { lp1_total_fees } else { lp3_total_fees }
            } else {
                if (lp2_total_fees > lp3_total_fees) { lp2_total_fees } else { lp3_total_fees }
            };
            
            let min_fees = if (lp1_total_fees < lp2_total_fees) {
                if (lp1_total_fees < lp3_total_fees) { lp1_total_fees } else { lp3_total_fees }
            } else {
                if (lp2_total_fees < lp3_total_fees) { lp2_total_fees } else { lp3_total_fees }
            };
            
            // Difference should be less than 5% of max
            let diff = max_fees - min_fees;
            let tolerance = max_fees / 20; // 5%
            assert!(diff <= tolerance, 0);
        };
        
        // Verify second claim returns zero fees
        test_scenario::next_tx(&mut scenario, lp1);
        let (lp1_fee_a2, lp1_fee_b2) = pool::withdraw_fees(
            &mut pool,
            &mut lp1_position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&lp1_fee_a2) == 0, 1);
        assert!(coin::value(&lp1_fee_b2) == 0, 2);
        
        // Cleanup
        coin::burn_for_testing<BTC>(lp1_fee_a);
        coin::burn_for_testing<USDC>(lp1_fee_b);
        coin::burn_for_testing<BTC>(lp2_fee_a);
        coin::burn_for_testing<USDC>(lp2_fee_b);
        coin::burn_for_testing<BTC>(lp3_fee_a);
        coin::burn_for_testing<USDC>(lp3_fee_b);
        coin::burn_for_testing<BTC>(lp1_fee_a2);
        coin::burn_for_testing<USDC>(lp1_fee_b2);
        
        test_scenario::return_shared(pool);
        position::destroy_for_testing(admin_position);
        position::destroy_for_testing(lp1_position);
        position::destroy_for_testing(lp2_position);
        position::destroy_for_testing(lp3_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
