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

    /// Verifies that the K-invariant (constant product formula: x * y = k) is maintained
    /// across a sequence of 1000 random swaps in both directions.
    ///
    /// The K-invariant is the core correctness property of constant product AMMs. After each
    /// swap, K should either increase (due to fees) or remain constant (within rounding tolerance).
    /// It should never decrease, as that would indicate value extraction from the pool.
    ///
    /// This test generates random swap amounts and directions, executing them sequentially
    /// and verifying K is maintained after each operation.
    #[test]
    fun test_k_invariant_1000_random_swaps() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        let (retail_a, retail_b) = fixtures::retail_liquidity();
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (_pool_id, position) = test_utils::create_initialized_pool<USDC, BTC>(
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
        
        // Execute 1000 random swaps to verify K-invariant holds across diverse scenarios
        let seed = fixtures::default_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        while (i < iterations) {
            let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
            let k_before = test_utils::get_k_invariant(&snapshot_before);
            
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            let is_a_to_b = (test_utils::lcg_random(seed, i * 2) % 2) == 0;
            
            // Execute swap in randomly chosen direction with safe amount
            if (is_a_to_b) {
                let amount_in = test_utils::random_safe_swap_amount(seed, i, reserve_a);
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
                let amount_in = test_utils::random_safe_swap_amount(seed, i + 1, reserve_b);
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
            
            let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
            let k_after = test_utils::get_k_invariant(&snapshot_after);
            
            // Verify K-invariant is maintained: K_after >= K_before (within rounding tolerance)
            // This is the fundamental correctness property of constant product AMMs
            assertions::assert_k_invariant_maintained(
                &snapshot_before,
                &snapshot_after,
                fixtures::standard_tolerance_u128()
            );
            
            assert!(k_after + fixtures::standard_tolerance_u128() >= k_before, 0);
            
            i = i + 1;
        };
        
        transfer::public_transfer(position, fixtures::admin());
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    /// Verifies that the K-invariant holds across pools initialized with randomized token amounts.
    ///
    /// This test creates multiple pools with different initial liquidity amounts (ranging from
    /// small to near-maximum values) and verifies that K is maintained after swaps regardless
    /// of the initial pool size. This ensures the constant product formula works correctly
    /// across the full range of possible pool configurations.
    #[test]
    fun test_k_invariant_randomized_amounts() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        let seed = fixtures::default_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        while (i < iterations) {
            let max_amount = fixtures::near_u64_max();
            let initial_a = test_utils::random_amount(seed, i * 3, max_amount);
            let initial_b = test_utils::random_amount(seed, i * 3 + 1, max_amount);
            
            // Skip pools with insufficient liquidity to avoid edge cases
            if (initial_a < 10000 || initial_b < 10000) {
                i = i + 1;
                continue
            };
            

            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let (_pool_id, position) = test_utils::create_initialized_pool<USDC, BTC>(
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
            
            let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
            
            let (reserve_a, _reserve_b) = pool::get_reserves(&pool);
            let amount_in = test_utils::random_safe_swap_amount(seed, i * 3 + 2, reserve_a);
            
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
            
            // Verify K-invariant holds regardless of initial pool size
            assertions::assert_k_invariant_maintained(
                &snapshot_before,
                &snapshot_after,
                fixtures::standard_tolerance_u128()
            );
            

            transfer::public_transfer(position, fixtures::admin());
            test_scenario::return_shared(pool);
            clock::destroy_for_testing(clock);
            
            i = i + 1;
        };
        
        test_scenario::end(scenario);
    }

    /// Verifies that the K-invariant is maintained across different fee tiers.
    ///
    /// This test creates pools with randomized fee configurations (5, 30, or 100 basis points)
    /// and verifies that K is maintained after swaps regardless of the fee tier. Different fee
    /// tiers affect how much K increases per swap (higher fees = larger K increase), but K
    /// should never decrease regardless of the fee configuration.
    #[test]
    fun test_k_invariant_randomized_fee_tiers() {
        let mut scenario = test_scenario::begin(fixtures::admin());
        
        let seed = fixtures::alt_random_seed();
        let iterations = fixtures::property_test_iterations();
        let mut i = 0;
        
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        while (i < iterations) {
            // Randomly select from three fee tiers representing different pool types
            let fee_selector = test_utils::lcg_random(seed, i) % 3;
            let fee_bps = if (fee_selector == 0) {
                5
            } else if (fee_selector == 1) {
                30
            } else {
                100
            };
            

            let (_pool_id, position) = test_utils::create_initialized_pool<USDC, BTC>(
                fee_bps,
                100, // protocol_fee_bps
                0,   // creator_fee_bps
                initial_a,
                initial_b,
                fixtures::admin(),
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::next_tx(&mut scenario, fixtures::admin());
            
            let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            // Execute 10 swaps per fee tier to verify K-invariant holds
            let mut j = 0;
            while (j < 10) {
                let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                

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
                        test_scenario::ctx(&mut scenario)
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
                        test_scenario::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(coin_out);
                };
                
                let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
                
                // Verify K-invariant holds regardless of fee tier configuration
                assertions::assert_k_invariant_maintained(
                    &snapshot_before,
                    &snapshot_after,
                    fixtures::standard_tolerance_u128()
                );
                
                j = j + 1;
            };
            
            transfer::public_transfer(position, fixtures::admin());
            test_scenario::return_shared(pool);
            clock::destroy_for_testing(clock);
            
            i = i + 1;
        };
        
        test_scenario::end(scenario);
    }

    /// Verifies that the K-invariant behaves correctly across mixed pool operations.
    ///
    /// This test randomly interleaves three types of operations: swaps, adding liquidity,
    /// and removing liquidity. Each operation should affect K predictably:
    /// - Swaps: K should increase (fees) or stay constant (within tolerance)
    /// - Add liquidity: K should increase proportionally
    /// - Remove liquidity: K should decrease proportionally
    ///
    /// This ensures the constant product formula is maintained across all pool operations.
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
        
        let mut pool = test_scenario::take_shared<pool::LiquidityPool<USDC, BTC>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        let seed = fixtures::default_random_seed();
        let mut i = 0;
        
        let iterations = fixtures::property_test_iterations();
        while (i < iterations) {
            let operation = test_utils::lcg_random(seed, i) % 3;
            
            if (operation == 0) {
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
                
                // Swaps should maintain or increase K due to fees
                assertions::assert_k_invariant_maintained(
                    &snapshot_before,
                    &snapshot_after,
                    fixtures::standard_tolerance_u128()
                );
            } else if (operation == 1) {
                let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                
                let (reserve_a, reserve_b) = pool::get_reserves(&pool);
                
                let add_a = test_utils::random_amount(seed, i + 2, reserve_a / 10);
                
                // Calculate proportional amount B to maintain price ratio
                let add_b = if (reserve_a > 0) {
                    ((add_a as u128) * (reserve_b as u128) / (reserve_a as u128)) as u64
                } else {
                    test_utils::random_amount(seed, i + 3, reserve_b / 10)
                };
                
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
                    
                    // Adding liquidity should increase K proportionally
                    assertions::assert_k_increased(&snapshot_before, &snapshot_after);
                    
                    transfer::public_transfer(new_position, fixtures::admin());
                };
            } else {
                let liquidity = position::liquidity(&position);
                if (liquidity > 2000) {
                    let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
                    
                    let remove_amount = liquidity / 10;
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
                    
                    // Removing liquidity should decrease K proportionally
                    assertions::assert_k_decreased(&snapshot_before, &snapshot_after);
                };
            };
            
            i = i + 1;
        };
        
        transfer::public_transfer(position, fixtures::admin());
        test_scenario::return_shared(pool);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
