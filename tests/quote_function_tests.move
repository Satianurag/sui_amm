#[test_only]
module sui_amm::quote_function_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use sui::sui::SUI;
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::factory;

    struct ETH has drop {}
    struct USDT has drop {}
    struct USDC has drop {}
    struct DAI has drop {}

    #[test]
    fun test_quote_matches_actual_swap() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<ETH>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(10000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Get quote and compare with actual swap
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<ETH, USDT>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let swap_amount = 1000;
            let quoted_output = pool::get_quote_a_to_b(pool, swap_amount);
            
            // Execute actual swap
            let coin_in = coin::mint_for_testing<ETH>(swap_amount, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 999999999, ctx);
            
            let actual_output = coin::value(&coin_out);
            
            // Quote should match actual output
            assert!(quoted_output == actual_output, 0);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_quote_with_zero_liquidity() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            let pool = pool::create_pool_for_testing<ETH, USDT>(30, 10, 0, ctx);
            
            // Empty pool should return 0
            let quote = pool::get_quote_a_to_b(&pool, 1000);
            assert!(quote == 0, 0);
            
            pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_quote_with_zero_input() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<ETH>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<ETH, USDT>>(scenario);
            let pool = &pool_val;
            
            // Zero input should return 0
            let quote = pool::get_quote_a_to_b(pool, 0);
            assert!(quote == 0, 0);
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_quote_bidirectional() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<ETH>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(10000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<ETH, USDT>>(scenario);
            let pool = &pool_val;
            
            let amount = 1000;
            let quote_a_to_b = pool::get_quote_a_to_b(pool, amount);
            let quote_b_to_a = pool::get_quote_b_to_a(pool, amount);
            
            // Both should be positive
            assert!(quote_a_to_b > 0, 0);
            assert!(quote_b_to_a > 0, 1);
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_exchange_rate_calculation() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<ETH>(2000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(4000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool<ETH, USDT>(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<ETH, USDT>>(scenario);
            let pool = &pool_val;
            
            let rate = pool::get_exchange_rate(pool);
            
            // With 2M ETH and 4M USDT, rate should be ~2e9 (ratio 1:2)
            assert!(rate > 1_500_000_000, 0); // Greater than 1.5
            assert!(rate < 2_500_000_000, 1); // Less than 2.5
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_stable_pool_quotes() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let usdc = coin::mint_for_testing<USDC>(10000000, ctx);
            let usdt = coin::mint_for_testing<DAI>(10000000, ctx); // Changed DAI to USDT as per user's implied intent
            
            let (position, refund_a, refund_b) = factory::create_stable_pool(
                registry,
                30,
                100,
                usdc,
                usdt,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<StableSwapPool<USDC, DAI>>(scenario);
            let pool = &pool_val;
            
            let amount = 1000;
            let quote = stable_pool::get_quote_a_to_b(pool, amount);
            
            // StableSwap should give close to 1:1 quote
            // With fees, expect slightly less than input
            assert!(quote > 900, 0); // At least 90% of input
            assert!(quote < amount, 1); // Less than input due to fees
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
