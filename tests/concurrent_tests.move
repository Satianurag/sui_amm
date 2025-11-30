#[test_only]
module sui_amm::concurrent_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position;
    use sui_amm::factory;

    struct WETH has drop {}
    struct WBTC has drop {}

    #[test]
    fun test_concurrent_swaps_different_directions() {
        let owner = @0xA;
        let trader1 = @0xB;
        let trader2 = @0xC;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        // Create pool
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<WETH>(10000000, ctx);
            let coin_b = coin::mint_for_testing<WBTC>(10000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Trader1 swaps A->B
        test_scenario::next_tx(scenario, trader1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_in = coin::mint_for_testing<WETH>(10000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 999999999, ctx);
            
            assert!(coin::value(&coin_out) > 0, 0);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Trader2 swaps B->A immediately after
        test_scenario::next_tx(scenario, trader2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_in = coin::mint_for_testing<WBTC>(10000, ctx);
            let coin_out = pool::swap_b_to_a(pool, coin_in, 0, option::none(), &clock, 999999999, ctx);
            
            assert!(coin::value(&coin_out) > 0, 1);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_concurrent_liquidity_operations() {
        let lp1 = @0xB;
        let lp2 = @0xC;
        let scenario_val = test_scenario::begin(lp1);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, lp1);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        // LP1 creates pool
        test_scenario::next_tx(scenario, lp1);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<WETH>(5000000, ctx);
            let coin_b = coin::mint_for_testing<WBTC>(5000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, lp1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // LP2 adds liquidity
        test_scenario::next_tx(scenario, lp2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<WETH>(1000000, ctx);
            let coin_b = coin::mint_for_testing<WBTC>(1000000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            
            assert!(position::liquidity(&position) > 0, 0);
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, lp2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // LP1 performs swap while LP2's liquidity is in
        test_scenario::next_tx(scenario, lp1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_in = coin::mint_for_testing<WETH>(5000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 999999999, ctx);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_multiple_lps_concurrent_operations() {
        let owner = @0xA;
        let lp1 = @0xB;
        let lp2 = @0xC;
        let trader = @0xD;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        // Create pool
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<WETH>(10000000, ctx);
            let coin_b = coin::mint_for_testing<WBTC>(10000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // LP1 adds liquidity
        test_scenario::next_tx(scenario, lp1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<WETH>(500000, ctx);
            let coin_b = coin::mint_for_testing<WBTC>(500000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, lp1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Trader executes swap
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_in = coin::mint_for_testing<WETH>(10000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 999999999, ctx);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // LP2 adds liquidity after swap
        test_scenario::next_tx(scenario, lp2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<WETH, WBTC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<WETH>(500000, ctx);
            let coin_b = coin::mint_for_testing<WBTC>(500000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, lp2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
