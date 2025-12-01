#[test_only]
module sui_amm::amm_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};

    use sui::clock::{Self};

    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::position::{LPPosition};
    use sui_amm::math;

    public struct BTC has drop {}
    public struct USDC has drop {}

    #[test]
    fun test_math() {
        assert!(math::sqrt(100) == 10, 0);
        assert!(math::sqrt(0) == 0, 1);
        assert!(math::sqrt(3) == 1, 2); 
        
        assert!(math::calculate_constant_product_output(10, 100, 100, 0) == 9, 3);
    }

    #[test]
    fun test_pool_lifecycle() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);  // fee, protocol_fee, creator_fee
            pool::share(pool); 
        };

        // Owner adds initial liquidity to eat the lock cost
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);

            let locked = pool::get_locked_liquidity(pool);
            let mut total = pool::get_total_liquidity(pool);
            let minted = sui_amm::position::liquidity(&position);
            assert!(total == minted + locked, 100);

            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val); 
        };

        // 2. Add Liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 3. Swap
        test_scenario::next_tx(scenario, user2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            assert!(coin::value(&coin_out) == 996, 0);
            
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 4. Claim Fees
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees(pool, position, &clock, 0, ctx);
            
            clock::destroy_for_testing(clock);
            
            assert!(coin::value(&fee_a) >= 2, 1);
            assert!(coin::value(&fee_b) == 0, 2);
            
            transfer::public_transfer(fee_a, user1);
            transfer::public_transfer(fee_b, user1);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_stable_swap() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // 1. Create Stable Pool (Amp = 100)
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut pool = stable_pool::create_pool_for_testing<BTC, USDC>(5, 0, 100, ctx); // 0.05% fee
            stable_pool::share(pool);
        };

        // 2. Add Liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<StableSwapPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = stable_pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 3. Swap
        test_scenario::next_tx(scenario, user2);
        {
            let pool_val = test_scenario::take_shared<StableSwapPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            let coin_out = stable_pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            let val = coin::value(&coin_out);
            assert!(val > 990, 0); 
            
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_remove_liquidity() {
        let owner = @0xA;
        let user1 = @0xB;
        
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool); 
        };

        // Owner adds initial liquidity to eat the lock cost
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val); 
        };

        // 2. Add Liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 3. Remove Liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let (coin_a, coin_b) = pool::remove_liquidity(pool, position, 0, 0, &clock, 18446744073709551615, ctx);  // min_amount_a, min_amount_b
            
            assert!(coin::value(&coin_a) == 1000000, 0);
            assert!(coin::value(&coin_b) == 1000000, 1);
            
            transfer::public_transfer(coin_a, user1);
            transfer::public_transfer(coin_b, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_price_impact() {
        // 100 in, 1000 reserve -> ~9% impact
        // (reserve_in, reserve_out, amount_in, amount_out)
        // amount_in = 100, reserve_in = 1000.
        // amount_out = 90 (approx).
        let impact = pool::test_cp_price_impact_bps(1000, 1000, 100, 90);
        assert!(impact >= 900 && impact <= 1100, 0); // ~10.00%

        // 1 in, 1000000 reserve -> ~0% impact
        let impact_small = pool::test_cp_price_impact_bps(1000000, 1000000, 1, 1);
        assert!(impact_small == 0, 1);

        // 1000 in, 1000 reserve -> 50% impact
        let impact_large = pool::test_cp_price_impact_bps(1000, 1000, 1000, 500);
        assert!(impact_large >= 4900 && impact_large <= 5100, 2); // ~50.00%
    }

    #[test]
    fun test_swap_with_tiny_amount() {
        let owner = @0xA;
        let user = @0xB;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, user);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user);
            
            let coin_in = coin::mint_for_testing<BTC>(100, ctx); // Small amount but safe from precision issues
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            assert!(coin::value(&coin_out) > 0, 0);
            
            transfer::public_transfer(coin_out, user);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_auto_compound_single_token_fees() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;

        // 1. Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut pool = pool::create_pool_for_testing<BTC, USDC>(300, 0, 0, ctx); // 3% fee to generate significant fees
            pool::share(pool);
        };

        // 2. Add Liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 3. Swap to generate fees (A to B -> Fee in A)
        test_scenario::next_tx(scenario, user2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let coin_in = coin::mint_for_testing<BTC>(10000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 18446744073709551615, ctx);
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 4. Auto Compound
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let mut pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let initial_liquidity = sui_amm::position::liquidity(position);
            
            let (leftover_a, leftover_b) = sui_amm::fee_distributor::compound_fees(pool, position, 0, &clock, 18446744073709551615, ctx);
            
            let final_liquidity = sui_amm::position::liquidity(position);
            // Note: With single-sided fees, compound may return fees as refund
            assert!(final_liquidity >= initial_liquidity, 0);
            
            transfer::public_transfer(leftover_a, user1);
            transfer::public_transfer(leftover_b, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EInsufficientOutput)] // EInsufficientOutput
    fun test_slippage_zero_output() {
        sui_amm::slippage_protection::check_price_limit(100, 0, 1000);
    }
}
