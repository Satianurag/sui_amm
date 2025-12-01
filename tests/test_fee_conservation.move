#[test_only]
module sui_amm::test_fee_conservation {
    use sui::test_scenario;
    use sui::coin;
    use sui::clock;
    use sui_amm::pool;
    use sui_amm::position;
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;
    use sui_amm::fee_distributor;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: TOTAL CLAIMED FEES NEVER EXCEED TOTAL ACCUMULATED FEES
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_conservation_1000_random_claims() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Create pool with standard liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, position1) = test_utils::create_initialized_pool<USDC, BTC>(
            &mut scenario,
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            retail_a,
            retail_b,
            fixtures::admin(),
            ctx
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::user1());
        
        // Add second LP position
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let mut clock = clock::create_for_testing(ctx);
        
        let position2 = test_utils::add_liquidity_helper(
            &mut pool,
            retail_a / 2,
            retail_b / 2,
            0,
            0,
            test_utils::far_future(),
            &clock,
            ctx
        );
        
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        
        test_scenario::next_tx(&mut scenario, fixtures::user2());
        
        // Add third LP position
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let mut clock = clock::create_for_testing(ctx);
        
        let position3 = test_utils::add_liquidity_helper(
            &mut pool,
            retail_a / 4,
            retail_b / 4,
            0,
            0,
            test_utils::far_future(),
            &clock,
            ctx
        );
        
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        // Get pool and clock
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let mut clock = clock::create_for_testing(ctx);
        let mut position1 = test_scenario::take_from_sender<position::LPPosition>(&scenario);
        
        test_scenario::next_tx(&mut scenario, fixtures::user1());
        let mut position2 = test_scenario::take_from_sender<position::LPPosition>(&scenario);
        
        test_scenario::next_tx(&mut scenario, fixtures::user2());
        let mut position3 = test_scenario::take_from_sender<position::LPPosition>(&scenario);
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        // Track total fees accumulated and claimed
        let mut total_fees_accumulated_a = 0u128;
        let mut total_fees_accumulated_b = 0u128;
        let mut total_fees_claimed_a = 0u64;
        let mut total_fees_claimed_b = 0u64;
        
        let seed = fixtures::default_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        while (i < iterations) {
            let operation = test_utils::lcg_random(seed, i) % 4;
            
            if (operation == 0) {
                // Execute swap to generate fees
                let (reserve_a, reserve_b) = pool::get_reserves(&pool);
                let is_a_to_b = (test_utils::lcg_random(seed, i * 2) % 2) == 0;
                
                let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                
                if (is_a_to_b) {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i, reserve_a);
                    let coin_out = test_utils::swap_a_to_b_helper(
                        &mut pool,
                        amount_in,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        ctx
                    );
                    coin::burn_for_testing(coin_out);
                    
                    // Calculate fees generated
                    let fee_amount = ((amount_in as u128) * (fee_bps as u128) / 10000) as u64;
                    let protocol_fee = ((fee_amount as u128) * (protocol_fee_bps as u128) / 10000) as u64;
                    let lp_fee = fee_amount - protocol_fee;
                    total_fees_accumulated_a = total_fees_accumulated_a + (lp_fee as u128);
                } else {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i + 1, reserve_b);
                    let coin_out = test_utils::swap_b_to_a_helper(
                        &mut pool,
                        amount_in,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        ctx
                    );
                    coin::burn_for_testing(coin_out);
                    
                    // Calculate fees generated
                    let fee_amount = ((amount_in as u128) * (fee_bps as u128) / 10000) as u64;
                    let protocol_fee = ((fee_amount as u128) * (protocol_fee_bps as u128) / 10000) as u64;
                    let lp_fee = fee_amount - protocol_fee;
                    total_fees_accumulated_b = total_fees_accumulated_b + (lp_fee as u128);
                };
                
                let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
            } else if (operation == 1) {
                // Position 1 claims fees
                let (fee_a, fee_b) = fee_distributor::claim_fees(
                    &mut pool,
                    &mut position1,
                    &clock,
                    fixtures::far_future_deadline(),
                    ctx
                );
                
                let claimed_a = coin::value(&fee_a);
                let claimed_b = coin::value(&fee_b);
                
                total_fees_claimed_a = total_fees_claimed_a + claimed_a;
                total_fees_claimed_b = total_fees_claimed_b + claimed_b;
                
                coin::burn_for_testing(fee_a);
                coin::burn_for_testing(fee_b);
                
                // Verify claimed fees don't exceed accumulated
                assert!((total_fees_claimed_a as u128) <= total_fees_accumulated_a, 0);
                assert!((total_fees_claimed_b as u128) <= total_fees_accumulated_b, 1);
            } else if (operation == 2) {
                // Position 2 claims fees
                let (fee_a, fee_b) = fee_distributor::claim_fees(
                    &mut pool,
                    &mut position2,
                    &clock,
                    fixtures::far_future_deadline(),
                    ctx
                );
                
                let claimed_a = coin::value(&fee_a);
                let claimed_b = coin::value(&fee_b);
                
                total_fees_claimed_a = total_fees_claimed_a + claimed_a;
                total_fees_claimed_b = total_fees_claimed_b + claimed_b;
                
                coin::burn_for_testing(fee_a);
                coin::burn_for_testing(fee_b);
                
                // Verify claimed fees don't exceed accumulated
                assert!((total_fees_claimed_a as u128) <= total_fees_accumulated_a, 2);
                assert!((total_fees_claimed_b as u128) <= total_fees_accumulated_b, 3);
            } else {
                // Position 3 claims fees
                let (fee_a, fee_b) = fee_distributor::claim_fees(
                    &mut pool,
                    &mut position3,
                    &clock,
                    fixtures::far_future_deadline(),
                    ctx
                );
                
                let claimed_a = coin::value(&fee_a);
                let claimed_b = coin::value(&fee_b);
                
                total_fees_claimed_a = total_fees_claimed_a + claimed_a;
                total_fees_claimed_b = total_fees_claimed_b + claimed_b;
                
                coin::burn_for_testing(fee_a);
                coin::burn_for_testing(fee_b);
                
                // Verify claimed fees don't exceed accumulated
                assert!((total_fees_claimed_a as u128) <= total_fees_accumulated_a, 4);
                assert!((total_fees_claimed_b as u128) <= total_fees_accumulated_b, 5);
            };
            
            i = i + 1;
        };
        
        // Final verification: total claimed should never exceed total accumulated
        assert!((total_fees_claimed_a as u128) <= total_fees_accumulated_a, 6);
        assert!((total_fees_claimed_b as u128) <= total_fees_accumulated_b, 7);
        
        // Cleanup
        transfer::public_transfer(position1, fixtures::admin());
        transfer::public_transfer(position2, fixtures::user1());
        transfer::public_transfer(position3, fixtures::user2());
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: NO FEE DOUBLE-CLAIMING ACROSS RANDOM SEQUENCES
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_no_fee_double_claiming() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Create pool with standard liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, mut position) = test_utils::create_initialized_pool<USDC, BTC>(
            &mut scenario,
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            retail_a,
            retail_b,
            fixtures::admin(),
            ctx
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        // Get pool and clock
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let mut clock = clock::create_for_testing(ctx);
        
        let seed = fixtures::alt_random_seed();
        let mut i = 0;
        
        while (i < 100) {
            // Execute random swaps to generate fees
            let num_swaps = (test_utils::lcg_random(seed, i) % 10) + 1;
            let mut j = 0;
            
            while (j < num_swaps) {
                let (reserve_a, reserve_b) = pool::get_reserves(&pool);
                let is_a_to_b = (test_utils::lcg_random(seed, i * 10 + j) % 2) == 0;
                
                if (is_a_to_b) {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i * 10 + j, reserve_a);
                    let coin_out = test_utils::swap_a_to_b_helper(
                        &mut pool,
                        amount_in,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        ctx
                    );
                    coin::burn_for_testing(coin_out);
                } else {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i * 10 + j + 1, reserve_b);
                    let coin_out = test_utils::swap_b_to_a_helper(
                        &mut pool,
                        amount_in,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        ctx
                    );
                    coin::burn_for_testing(coin_out);
                };
                
                j = j + 1;
            };
            
            // Claim fees first time
            let (fee_a_1, fee_b_1) = fee_distributor::claim_fees(
                &mut pool,
                &mut position,
                &clock,
                ctx
            );
            
            let claimed_a_1 = coin::value(&fee_a_1);
            let claimed_b_1 = coin::value(&fee_b_1);
            
            coin::burn_for_testing(fee_a_1);
            coin::burn_for_testing(fee_b_1);
            
            // Immediately claim fees second time (should be zero or near-zero)
            let (fee_a_2, fee_b_2) = fee_distributor::claim_fees(
                &mut pool,
                &mut position,
                &clock,
                ctx
            );
            
            let claimed_a_2 = coin::value(&fee_a_2);
            let claimed_b_2 = coin::value(&fee_b_2);
            
            // Second claim should yield zero (no double-claiming)
            assert!(claimed_a_2 == 0, 0);
            assert!(claimed_b_2 == 0, 1);
            
            coin::burn_for_testing(fee_a_2);
            coin::burn_for_testing(fee_b_2);
            
            i = i + 1;
        };
        
        // Cleanup
        transfer::public_transfer(position, fixtures::admin());
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: FEE CONSERVATION WITH MULTIPLE LPS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_conservation_multiple_lps() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, position1) = test_utils::create_initialized_pool<USDC, BTC>(
            &mut scenario,
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let mut clock = clock::create_for_testing(ctx);
        
        // Add multiple LP positions with varying amounts
        let seed = fixtures::default_random_seed();
        let mut positions = vector::empty<position::LPPosition>();
        vector::push_back(&mut positions, position1);
        
        let mut i = 0;
        while (i < 5) {
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            let (add_a, add_b) = test_utils::random_liquidity_amounts(
                seed,
                i,
                reserve_a,
                reserve_b,
                reserve_a / 5
            );
            
            if (add_a > 10000 && add_b > 10000) {
                let new_position = test_utils::add_liquidity_helper(
                    &mut pool,
                    add_a,
                    add_b,
                    0,
                    0,
                    test_utils::far_future(),
                    &clock,
                    ctx
                );
                vector::push_back(&mut positions, new_position);
            };
            
            i = i + 1;
        };
        
        // Execute swaps to generate fees
        let mut total_lp_fees_a = 0u128;
        let mut total_lp_fees_b = 0u128;
        
        i = 0;
        while (i < 100) {
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            let is_a_to_b = (test_utils::lcg_random(seed, i + 100) % 2) == 0;
            
            if (is_a_to_b) {
                let amount_in = test_utils::random_safe_swap_amount(seed, i + 100, reserve_a);
                let coin_out = test_utils::swap_a_to_b_helper(
                    &mut pool,
                    amount_in,
                    0,
                    0,
                    test_utils::far_future(),
                    &clock,
                    ctx
                );
                coin::burn_for_testing(coin_out);
                
                // Track LP fees
                let fee_amount = ((amount_in as u128) * (fee_bps as u128) / 10000) as u64;
                let protocol_fee = ((fee_amount as u128) * (protocol_fee_bps as u128) / 10000) as u64;
                let lp_fee = fee_amount - protocol_fee;
                total_lp_fees_a = total_lp_fees_a + (lp_fee as u128);
            } else {
                let amount_in = test_utils::random_safe_swap_amount(seed, i + 101, reserve_b);
                let coin_out = test_utils::swap_b_to_a_helper(
                    &mut pool,
                    amount_in,
                    0,
                    0,
                    test_utils::far_future(),
                    &clock,
                    ctx
                );
                coin::burn_for_testing(coin_out);
                
                // Track LP fees
                let fee_amount = ((amount_in as u128) * (fee_bps as u128) / 10000) as u64;
                let protocol_fee = ((fee_amount as u128) * (protocol_fee_bps as u128) / 10000) as u64;
                let lp_fee = fee_amount - protocol_fee;
                total_lp_fees_b = total_lp_fees_b + (lp_fee as u128);
            };
            
            i = i + 1;
        };
        
        // All LPs claim their fees
        let mut total_claimed_a = 0u128;
        let mut total_claimed_b = 0u128;
        
        let positions_len = vector::length(&positions);
        i = 0;
        while (i < positions_len) {
            let mut pos = vector::pop_back(&mut positions);
            
            let (fee_a, fee_b) = fee_distributor::claim_fees(
                &mut pool,
                &mut pos,
                &clock,
                ctx
            );
            
            total_claimed_a = total_claimed_a + (coin::value(&fee_a) as u128);
            total_claimed_b = total_claimed_b + (coin::value(&fee_b) as u128);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            
            transfer::public_transfer(pos, fixtures::admin());
            
            i = i + 1;
        };
        
        vector::destroy_empty(positions);
        
        // Verify total claimed fees don't exceed total accumulated fees
        // Allow small tolerance for rounding
        let tolerance = 1000u128;
        assert!(total_claimed_a <= total_lp_fees_a + tolerance, 0);
        assert!(total_claimed_b <= total_lp_fees_b + tolerance, 1);
        
        // Cleanup
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
