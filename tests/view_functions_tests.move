#[test_only]
module sui_amm::view_functions_tests {
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
    fun test_get_position_value() {
        let owner = @0xA;
        let lp = @0xB;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, lp);
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
            transfer::public_transfer(position, lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Check position value
        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &position_val;
            
            let (val_a, val_b) = pool::get_position_value(pool, position);
            
            // 100,000 minted, but 1000 locked permanently.
            // So user gets 99,000.
            assert!(val_a == 99000, 0);
            assert!(val_b == 99000, 1);
            
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_get_accumulated_fees() {
        let owner = @0xA;
        let lp = @0xB;
        let trader = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, lp);
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
            transfer::public_transfer(position, lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Generate fees
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

        // Check accumulated fees
        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &position_val;
            
            let (fee_a, fee_b) = pool::get_accumulated_fees(pool, position);
            
            // Should have accumulated ~30 BTC in fees (10000 * 0.003)
            assert!(fee_a >= 28 && fee_a <= 32, 0);
            assert!(fee_b == 0, 1);
            
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_get_protocol_fees() {
        let owner = @0xA;
        let lp = @0xB;
        let trader = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create pool with 10% protocol fee
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 1000, 0, ctx); // 10% of 0.3% fee
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, lp);
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
            transfer::public_transfer(position, lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Generate fees with smaller swap to avoid price impact limit
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            // Smaller swap to stay under 10% price impact
            let coin_in = coin::mint_for_testing<BTC>(5000, ctx); 
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            transfer::public_transfer(coin_out, trader);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Check protocol fees
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            
            let (protocol_fee_a, protocol_fee_b) = pool::get_protocol_fees(pool);
            
            // Fee = 5000 * 0.003 = 15
            // Protocol = 15 * 0.1 = 1.5  
            assert!(protocol_fee_a >= 1 && protocol_fee_a <= 2, 0);
            assert!(protocol_fee_b == 0, 1);
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_impermanent_loss_calculation() {
        let owner = @0xA;
        let lp = @0xB;
        let trader = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
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

        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Initial IL should be 0
        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &position_val;
            
            let il = pool::get_impermanent_loss(pool, position);
            assert!(il == 0, 0);
            
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        // Change price by large swap
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<USDC>(50000, ctx);
            let coin_out = pool::swap_b_to_a(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            transfer::public_transfer(coin_out, trader);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // IL should now be > 0
        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &position_val;
            
            let il = pool::get_impermanent_loss(pool, position);
            assert!(il > 0, 1); // Should have some IL after price change
            
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
