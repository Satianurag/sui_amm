#[test_only]
module sui_amm::test_k_invariant {
    use sui::test_scenario;
    use sui::coin;
    use sui::clock;
    use sui_amm::pool;
    use sui_amm::position;
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: K-INVARIANT NEVER DECREASES ACROSS RANDOM SWAP SEQUENCES
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_k_invariant_1000_random_swaps() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Create pool with standard liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, position) = test_utils::create_initialized_pool<USDC, BTC>(
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
        
        // Run 1000 random swaps
        let seed = fixtures::default_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        while (i < iterations) {
            // Capture K before swap
            let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
            let k_before = test_utils::get_k_invariant(&snapshot_before);
            
            // Generate random swap parameters
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            let is_a_to_b = (test_utils::lcg_random(seed, i * 2) % 2) == 0;
            
            // Execute random swap
            if (is_a_to_b) {
                let amount_in = test_utils::random_safe_swap_amount(seed, i, reserve_a);
                let coin_out = test_utils::swap_a_to_b_helper(
                    &mut pool,
                    amount_in,
                    0, // min_out
                    0, // max_price (no limit)
                    test_utils::far_future(),
                    &clock,
                    ctx
                );
                coin::burn_for_testing(coin_out);
            } else {
                let amount_in = test_utils::random_safe_swap_amount(seed, i + 1, reserve_b);
                let coin_out = test_utils::swap_b_to_a_helper(
                    &mut pool,
                    amount_in,
                    0, // min_out
                    0, // max_price (no limit)
                    test_utils::far_future(),
                    &clock,
                    ctx
                );
                coin::burn_for_testing(coin_out);
            };
            
            // Capture K after swap
            let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
            let k_after = test_utils::get_k_invariant(&snapshot_after);
            
            // Verify K never decreased (with tolerance for rounding)
            assertions::assert_k_invariant_maintained(
                &snapshot_before,
                &snapshot_after,
                fixtures::standard_tolerance_u128()
            );
            
            // Additional check: K should not decrease
            assert!(k_after + fixtures::standard_tolerance_u128() >= k_before, 0);
            
            i = i + 1;
        };
        
        // Cleanup
        transfer::public_transfer(position, fixtures::admin());
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: K-INVARIANT WITH RANDOMIZED TOKEN AMOUNTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_k_invariant_randomized_amounts() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        let ctx = test_scenario::ctx(&mut scenario);
        
        let seed = fixtures::default_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        while (i < iterations) {
            // Generate random initial liquidity (1 to u64::MAX/1000)
            let max_amount = fixtures::near_u64_max();
            let initial_a = test_utils::random_amount(seed, i * 3, max_amount);
            let initial_b = test_utils::random_amount(seed, i * 3 + 1, max_amount);
            
            // Skip if amounts are too small
            if (initial_a < 10000 || initial_b < 10000) {
                i = i + 1;
                continue
            };
            
            // Create pool with random liquidity
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let (_pool_id, position) = test_utils::create_initialized_pool<USDC, BTC>(
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
            
            // Get pool and clock
            let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
            let mut clock = clock::create_for_testing(ctx);
            
            // Capture K before swap
            let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
            
            // Execute random swap
            let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
            let amount_in = test_utils::random_safe_swap_amount(seed, i * 3 + 2, reserve_a);
            
            let coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                amount_in,
                0, // min_out
                0, // max_price (no limit)
                test_utils::far_future(),
                &clock,
                ctx
            );
            coin::burn_for_testing(coin_out);
            
            // Capture K after swap
            let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
            
            // Verify K maintained
            assertions::assert_k_invariant_maintained(
                &snapshot_before,
                &snapshot_after,
                fixtures::standard_tolerance_u128()
            );
            
            // Cleanup
            transfer::public_transfer(position, fixtures::admin());
            test_scenario::return_shared(pool);
            clock::destroy_for_testing(clock);
            
            i = i + 1;
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: K-INVARIANT WITH RANDOMIZED FEE TIERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_k_invariant_randomized_fee_tiers() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        let ctx = test_scenario::ctx(&mut scenario);
        
        let seed = fixtures::alt_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        // Standard liquidity for all tests
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        while (i < iterations) {
            // Randomly select fee tier: 5, 30, or 100 bps
            let fee_selector = test_utils::lcg_random(seed, i) % 3;
            let fee_bps = if (fee_selector == 0) {
                5  // Ultra-low fee
            } else if (fee_selector == 1) {
                30 // Standard fee
            } else {
                100 // High-volatility fee
            };
            
            // Create pool with random fee tier
            let (_pool_id, position) = test_utils::create_initialized_pool<USDC, BTC>(
                &mut scenario,
                fee_bps,
                100, // protocol_fee_bps
                0,   // creator_fee_bps
                initial_a,
                initial_b,
                fixtures::admin(),
                ctx
            );
            
            test_scenario::next_tx(&mut scenario, fixtures::admin());
            
            // Get pool and clock
            let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
            let mut clock = clock::create_for_testing(ctx);
            
            // Execute multiple swaps with this fee tier
            let mut j = 0;
            while (j < 10) {
                // Capture K before swap
                let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                
                // Execute random swap
                let (reserve_a, reserve_b) = pool::get_reserves(&pool);
                let is_a_to_b = (test_utils::lcg_random(seed, i * 10 + j) % 2) == 0;
                
                if (is_a_to_b) {
                    let amount_in = test_utils::random_safe_swap_amount(seed, i * 10 + j, reserve_a);
                    let coin_out = test_utils::swap_a_to_b_helper(
                        &mut pool,
                        amount_in,
                        0, // min_out
                        0, // max_price (no limit)
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
                        0, // min_out
                        0, // max_price (no limit)
                        test_utils::far_future(),
                        &clock,
                        ctx
                    );
                    coin::burn_for_testing(coin_out);
                };
                
                // Capture K after swap
                let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
                
                // Verify K maintained regardless of fee tier
                assertions::assert_k_invariant_maintained(
                    &snapshot_before,
                    &snapshot_after,
                    fixtures::standard_tolerance_u128()
                );
                
                j = j + 1;
            };
            
            // Cleanup
            transfer::public_transfer(position, fixtures::admin());
            test_scenario::return_shared(pool);
            clock::destroy_for_testing(clock);
            
            i = i + 1;
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY TEST: K-INVARIANT WITH MIXED OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_k_invariant_mixed_operations() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        // Create pool with standard liquidity
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, mut position) = test_utils::create_initialized_pool<USDC, BTC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            retail_a,
            retail_b,
            fixtures::admin(),
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, fixtures::admin());
        
        // Get pool and clock
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Run mixed operations: swaps and liquidity changes
        let seed = fixtures::default_random_seed();
        let mut i = 0;
        
        while (i < 100) {
            let operation = test_utils::lcg_random(seed, i) % 3;
            
            if (operation == 0) {
                // Swap operation
                let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                
                let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
                let amount_in = test_utils::random_safe_swap_amount(seed, i + 1, reserve_a);
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
                
                let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
                
                // K should be maintained after swap
                assertions::assert_k_invariant_maintained(
                    &snapshot_before,
                    &snapshot_after,
                    fixtures::standard_tolerance_u128()
                );
            } else if (operation == 1) {
                // Add liquidity operation
                let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                
                let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
                let (add_a, add_b) = test_utils::random_liquidity_amounts(
                    seed,
                    i + 2,
                    reserve_a / 10 // Max 10% of current reserve
                );
                
                if (add_a > 1000 && add_b > 1000) {
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
                    
                    let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
                    
                    // K should increase after adding liquidity
                    assertions::assert_k_increased(&snapshot_before, &snapshot_after);
                    
                    transfer::public_transfer(new_position, fixtures::admin());
                };
            } else {
                // Remove partial liquidity operation (if position has enough)
                let liquidity = position::liquidity(&position);
                if (liquidity > 2000) {
                    let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                    
                    let remove_amount = liquidity / 10; // Remove 10%
                    let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
                        &mut pool,
                        &mut position,
                        remove_amount,
                        0,
                        0,
                        test_utils::far_future(),
                        &clock,
                        test_scenario::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(coin_a);
                    coin::burn_for_testing(coin_b);
                    
                    let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
                    
                    // K should decrease after removing liquidity
                    assertions::assert_k_decreased(&snapshot_before, &snapshot_after);
                };
            };
            
            i = i + 1;
        };
        
        // Cleanup
        transfer::public_transfer(position, fixtures::admin());
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
