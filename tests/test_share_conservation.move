#[test_only]
module sui_amm::test_share_conservation {
    use sui::test_scenario;
    use sui::coin;
    use sui::clock;
    use sui_amm::pool;
    use sui_amm::position;
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: TOTAL LP SHARES ALWAYS SUM TO TOTAL_LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_share_conservation_1000_random_operations() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        // Create pool with initial liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, position1) = test_utils::create_initialized_pool<USDC, BTC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            retail_a,
            retail_b,
            fixtures::admin(),
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Track all positions
        let mut positions = vector::empty<position::LPPosition>();
        vector::push_back(&mut positions, position1);
        
        let seed = fixtures::default_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        while (i < iterations) {
            let operation = test_utils::lcg_random(seed, i) % 3;
            
            if (operation == 0) {
                // Add liquidity operation
                let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
                let (add_a, add_b) = test_utils::random_liquidity_amounts(
                    seed,
                    i + 1,
                    reserve_a / 10 // Max 10% of current reserve
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
                        test_scenario::ctx(&mut scenario)
                    );
                    
                    vector::push_back(&mut positions, new_position);
                };
            } else if (operation == 1 && vector::length(&positions) > 1) {
                // Remove partial liquidity from random position
                let pos_index = (test_utils::lcg_random(seed, i + 2) % vector::length(&positions)) as u64;
                let mut pos = vector::remove(&mut positions, pos_index);
                
                let liquidity = position::liquidity(&pos);
                if (liquidity > 2000) {
                    let remove_amount = liquidity / 10; // Remove 10%
                    let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
                        &mut pool,
                        &mut pos,
                        remove_amount,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        test_scenario::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(coin_a);
                    coin::burn_for_testing(coin_b);
                    
                    // Put position back
                    vector::push_back(&mut positions, pos);
                } else {
                    // Put position back without modification
                    vector::push_back(&mut positions, pos);
                };
            } else {
                // Execute swap (doesn't affect share conservation)
                let (reserve_a, reserve_b) = pool::get_reserves(&pool);
                let is_a_to_b = (test_utils::lcg_random(seed, i + 3) % 2) == 0;
                
                if (is_a_to_b) {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i + 4, reserve_a);
                    let coin_out = test_utils::swap_a_to_b_helper(
                        &mut pool,
                        amount_in,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        test_scenario::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(coin_out);
                } else {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i + 5, reserve_b);
                    let coin_out = test_utils::swap_b_to_a_helper(
                        &mut pool,
                        amount_in,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        test_scenario::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(coin_out);
                };
            };
            
            // Verify share conservation after each operation
            let total_liquidity = pool::get_total_liquidity(&pool);
            let mut sum_of_shares = 0u64;
            
            let positions_len = vector::length(&positions);
            let mut j = 0;
            while (j < positions_len) {
                let pos = vector::borrow(&positions, j);
                sum_of_shares = sum_of_shares + position::liquidity(pos);
                j = j + 1;
            };
            
            // Total LP shares should equal total_liquidity
            // Note: MINIMUM_LIQUIDITY (1000) is burned on first deposit
            assert!(sum_of_shares + 1000 == total_liquidity, 0);
            
            i = i + 1;
        };
        
        // Final verification
        let total_liquidity = pool::get_total_liquidity(&pool);
        let mut sum_of_shares = 0u64;
        
        let positions_len = vector::length(&positions);
        let mut j = 0;
        while (j < positions_len) {
            let pos = vector::pop_back(&mut positions);
            sum_of_shares = sum_of_shares + position::liquidity(&pos);
            position::destroy_for_testing(pos);
            j = j + 1;
        };
        
        vector::destroy_empty(positions);
        
        // Verify final conservation
        assert!(sum_of_shares + 1000 == total_liquidity, 1);
        
        // Cleanup
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: SHARE CONSERVATION WITH FULL LIQUIDITY REMOVALS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_share_conservation_with_full_removals() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        // Create pool with initial liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, position1) = test_utils::create_initialized_pool<USDC, BTC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            retail_a,
            retail_b,
            fixtures::admin(),
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Track all positions
        let mut positions = vector::empty<position::LPPosition>();
        vector::push_back(&mut positions, position1);
        
        let seed = fixtures::alt_random_seed();
        let mut i = 0;
        
        while (i < 100) {
            // Add multiple positions
            let num_adds = (test_utils::lcg_random(seed, i) % 5) + 1;
            let mut j = 0;
            
            while (j < num_adds) {
                let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
                let (add_a, add_b) = test_utils::random_liquidity_amounts(
                    seed,
                    i * 10 + j,
                    reserve_a / 20
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
                        test_scenario::ctx(&mut scenario)
                    );
                    vector::push_back(&mut positions, new_position);
                };
                
                j = j + 1;
            };
            
            // Verify share conservation after additions
            let total_liquidity = pool::get_total_liquidity(&pool);
            let mut sum_of_shares = 0u64;
            
            let positions_len = vector::length(&positions);
            j = 0;
            while (j < positions_len) {
                let pos = vector::borrow(&positions, j);
                sum_of_shares = sum_of_shares + position::liquidity(pos);
                j = j + 1;
            };
            
            assert!(sum_of_shares + 1000 == total_liquidity, 0);
            
            // Remove some positions completely (if we have more than 1)
            if (vector::length(&positions) > 1) {
                let num_removes = (test_utils::lcg_random(seed, i + 100) % 3) + 1;
                let mut k = 0;
                
                while (k < num_removes && vector::length(&positions) > 1) {
                    let pos_index = (test_utils::lcg_random(seed, i * 10 + k + 50) % vector::length(&positions)) as u64;
                    let mut pos = vector::remove(&mut positions, pos_index);
                    
                    let liquidity = position::liquidity(&pos);
                    let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
                        &mut pool,
                        &mut pos,
                        liquidity, // Remove all
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        test_scenario::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(coin_a);
                    coin::burn_for_testing(coin_b);
                    
                    // Position should be destroyed after full removal
                    position::destroy_for_testing(pos);
                    
                    k = k + 1;
                };
            };
            
            // Verify share conservation after removals
            let total_liquidity = pool::get_total_liquidity(&pool);
            let mut sum_of_shares = 0u64;
            
            let positions_len = vector::length(&positions);
            j = 0;
            while (j < positions_len) {
                let pos = vector::borrow(&positions, j);
                sum_of_shares = sum_of_shares + position::liquidity(pos);
                j = j + 1;
            };
            
            assert!(sum_of_shares + 1000 == total_liquidity, 1);
            
            i = i + 1;
        };
        
        // Cleanup remaining positions
        while (vector::length(&positions) > 0) {
            let pos = vector::pop_back(&mut positions);
            position::destroy_for_testing(pos);
        };
        
        vector::destroy_empty(positions);
        
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: SHARE CONSERVATION WITH VARYING POOL SIZES
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_share_conservation_varying_pool_sizes() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        let seed = fixtures::default_random_seed();
        let mut test_iteration = 0;
        
        // Test with different initial pool sizes
        while (test_iteration < 10) {
            // Generate random initial liquidity
            let max_amount = fixtures::max_random_amount();
            let initial_a = test_utils::random_amount(seed, test_iteration * 100, max_amount);
            let initial_b = test_utils::random_amount(seed, test_iteration * 100 + 1, max_amount);
            
            // Skip if amounts are too small
            if (initial_a < 100000 || initial_b < 100000) {
                test_iteration = test_iteration + 1;
                continue
            };
            
            // Create pool with random initial liquidity
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let (_pool_id, position1) = test_utils::create_initialized_pool<USDC, BTC>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                initial_a,
                initial_b,
                fixtures::admin(),
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::next_tx(&mut scenario, fixtures::admin());
            
            let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let mut positions = vector::empty<position::LPPosition>();
            vector::push_back(&mut positions, position1);
            
            // Perform random operations
            let mut i = 0;
            while (i < 50) {
                let operation = test_utils::lcg_random(seed, test_iteration * 1000 + i) % 2;
                
                if (operation == 0) {
                    // Add liquidity
                    let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
                    let (add_a, add_b) = test_utils::random_liquidity_amounts(
                        seed,
                        test_iteration * 1000 + i + 1,
                        reserve_a / 10
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
                            test_scenario::ctx(&mut scenario)
                        );
                        vector::push_back(&mut positions, new_position);
                    };
                } else if (vector::length(&positions) > 1) {
                    // Remove partial liquidity
                    let pos_index = (test_utils::lcg_random(seed, test_iteration * 1000 + i + 2) % vector::length(&positions)) as u64;
                    let mut pos = vector::remove(&mut positions, pos_index);
                    
                    let liquidity = position::liquidity(&pos);
                    if (liquidity > 2000) {
                        let remove_amount = liquidity / 5; // Remove 20%
                        let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
                            &mut pool,
                            &mut pos,
                            remove_amount,
                            0,
                            0,
                            test_utils::far_future(),
                            &clock,
                            test_scenario::ctx(&mut scenario)
                        );
                        coin::burn_for_testing(coin_a);
                        coin::burn_for_testing(coin_b);
                    };
                    
                    vector::push_back(&mut positions, pos);
                };
                
                // Verify share conservation
                let total_liquidity = pool::get_total_liquidity(&pool);
                let mut sum_of_shares = 0u64;
                
                let positions_len = vector::length(&positions);
                let mut j = 0;
                while (j < positions_len) {
                    let pos = vector::borrow(&positions, j);
                    sum_of_shares = sum_of_shares + position::liquidity(pos);
                    j = j + 1;
                };
                
                assert!(sum_of_shares + 1000 == total_liquidity, 0);
                
                i = i + 1;
            };
            
            // Cleanup
            while (vector::length(&positions) > 0) {
                let pos = vector::pop_back(&mut positions);
                position::destroy_for_testing(pos);
            };
            
            vector::destroy_empty(positions);
            test_scenario::return_shared(pool);
            clock::destroy_for_testing(clock);
            
            test_iteration = test_iteration + 1;
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: SHARE CONSERVATION AFTER INCREASE LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_share_conservation_increase_liquidity() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        // Create pool with initial liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, mut position1) = test_utils::create_initialized_pool<USDC, BTC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            retail_a,
            retail_b,
            fixtures::admin(),
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        let seed = fixtures::default_random_seed();
        let mut i = 0;
        
        while (i < 100) {
            // Increase liquidity on existing position
            let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
            let (add_a, add_b) = test_utils::random_liquidity_amounts(
                seed,
                i,
                reserve_a / 20
            );
            
            if (add_a > 10000 && add_b > 10000) {
                let liquidity_before = position::liquidity(&position1);
                let total_liquidity_before = pool::get_total_liquidity(&pool);
                
                // Increase liquidity
                let coin_a = test_utils::mint_coin<USDC>(add_a, test_scenario::ctx(&mut scenario));
                let coin_b = test_utils::mint_coin<BTC>(add_b, test_scenario::ctx(&mut scenario));
                
                let (refund_a, refund_b) = pool::increase_liquidity(
                    &mut pool,
                    &mut position1,
                    coin_a,
                    coin_b,
                    0,
                    &clock,
                    test_utils::far_future(),
                    test_scenario::ctx(&mut scenario)
                );
                
                coin::burn_for_testing(refund_a);
                coin::burn_for_testing(refund_b);
                
                let liquidity_after = position::liquidity(&position1);
                let total_liquidity_after = pool::get_total_liquidity(&pool);
                
                // Verify share conservation
                // Position liquidity increase should match total liquidity increase
                let position_increase = liquidity_after - liquidity_before;
                let total_increase = total_liquidity_after - total_liquidity_before;
                
                assert!(position_increase == total_increase, 0);
                
                // Verify total shares still equal total_liquidity (minus burned minimum)
                assert!(liquidity_after + 1000 == total_liquidity_after, 1);
            };
            
            i = i + 1;
        };
        
        // Cleanup
        position::destroy_for_testing(position1);
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
