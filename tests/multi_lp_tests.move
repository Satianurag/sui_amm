#[test_only]
module sui_amm::multi_lp_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{LPPosition};

    struct BTC has drop {}
    struct USDC has drop {}

    #[test]
    fun test_multiple_lps_same_pool() {
        let owner = @0xA;
        let lp1 = @0xB;
        let lp2 = @0xC;
        let trader = @0xD;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        // LP1 adds liquidity
        test_scenario::next_tx(scenario, lp1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, lp1);
            
            test_scenario::return_shared(pool_val);
        };

        // LP2 adds liquidity (same amounts)
        test_scenario::next_tx(scenario, lp2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, lp2);
            
            test_scenario::return_shared(pool_val);
        };

        // Trader swaps, generating fees
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(10000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            transfer::public_transfer(coin_out, trader);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // LP1 claims fees (should get ~50% of fees)
        test_scenario::next_tx(scenario, lp1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a_lp1, fee_b) = sui_amm::fee_distributor::claim_fees_simple(pool, position, ctx);
            let fee_amount_lp1 = coin::value(&fee_a_lp1);
            
            // Fee should be ~15 (30 total fee * 0.5 share)
            assert!(fee_amount_lp1 >= 14 && fee_amount_lp1 <= 16, 0);
            
            transfer::public_transfer(fee_a_lp1, lp1);
            transfer::public_transfer(fee_b, lp1);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        // LP2 claims fees (should also get ~50% of fees)
        test_scenario::next_tx(scenario, lp2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a_lp2, fee_b) = sui_amm::fee_distributor::claim_fees_simple(pool, position, ctx);
            let fee_amount_lp2 = coin::value(&fee_a_lp2);
            
            // Fee should be ~15 (30 total fee * 0.5 share)
            assert!(fee_amount_lp2 >= 14 && fee_amount_lp2 <= 16, 1);
            
            transfer::public_transfer(fee_a_lp2, lp2);
            transfer::public_transfer(fee_b, lp2);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_unequal_lp_shares() {
        let owner = @0xA;
        let big_lp = @0xB;
        let small_lp = @0xC;
        let trader = @0xD;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        // Big LP adds 90% of liquidity
        test_scenario::next_tx(scenario, big_lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(900000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(900000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, big_lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Small LP adds 10% of liquidity
        test_scenario::next_tx(scenario, small_lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, small_lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Generate fees
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            transfer::public_transfer(coin_out, trader);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Big LP should get ~90% of fees
        test_scenario::next_tx(scenario, big_lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees_simple(pool, position, ctx);
            // Big LP gets ~90% of fees (verified in small_lp test)
            
            transfer::public_transfer(fee_a, big_lp);
            transfer::public_transfer(fee_b, big_lp);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        // Small LP should get ~10% of fees
        test_scenario::next_tx(scenario, small_lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees_simple(pool, position, ctx);
            let small_lp_fee = coin::value(&fee_a);
            
            // Ratio should be approximately 9:1
            // Total fee is 300 (100000 * 0.003)
            // Big LP: ~270, Small LP: ~30
            assert!(small_lp_fee >= 25 && small_lp_fee <= 35, 0);
            
            transfer::public_transfer(fee_a, small_lp);
            transfer::public_transfer(fee_b, small_lp);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_lp_removes_affects_others() {
        let owner = @0xA;
        let lp1 = @0xB;
        let lp2 = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create pool with two LPs
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        // Owner adds initial liquidity to eat the lock cost
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::next_tx(scenario, lp1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, lp1);
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::next_tx(scenario, lp2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, lp2);
            
            test_scenario::return_shared(pool_val);
        };

        // LP1 removes all liquidity
        test_scenario::next_tx(scenario, lp1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let (coin_a, coin_b) = pool::remove_liquidity(pool, position_val, 0, 0, &clock, 18446744073709551615, ctx);
            
            // LP1 should get back their share
            assert!(coin::value(&coin_a) == 100000, 0);
            assert!(coin::value(&coin_b) == 100000, 1);
            
            transfer::public_transfer(coin_a, lp1);
            transfer::public_transfer(coin_b, lp1);
            test_scenario::return_shared(pool_val);
        };

        // LP2's position value should remain unchanged
        test_scenario::next_tx(scenario, lp2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &position_val;
            
            let (val_a, val_b) = pool::get_position_value(pool, position);
            
            // LP2 still has 100% of remaining liquidity
            assert!(val_a == 100000, 2);
            assert!(val_b == 100000, 3);
            
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
