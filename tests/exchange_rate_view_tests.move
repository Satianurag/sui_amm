#[test_only]
module sui_amm::exchange_rate_view_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};

    struct ETH has drop {}
    struct USDT has drop {}
    struct USDC has drop {}
    struct DAI has drop {}

    #[test]
    fun test_get_exchange_rate_b_to_a() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool_for_testing<ETH, USDT>(30, 10, 0, ctx);
            
            // Empty pool should return 0
            let rate = pool::get_exchange_rate_b_to_a(&pool);
            assert!(rate == 0, 0);
            
            pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_get_exchange_rate_b_to_a_with_liquidity() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let pool = pool::create_pool_for_testing<ETH, USDT>(30, 10, 0, ctx);
            
            // Add liquidity: 2M ETH and 4M USDT (ratio 1:2)
            let coin_a = coin::mint_for_testing<ETH>(2000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(4000000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                999999999,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            sui::transfer::public_transfer(position, owner);
            
            // Get B to A rate (USDT to ETH)
            let rate_b_to_a = pool::get_exchange_rate_b_to_a(&pool);
            
            // With 2M ETH and 4M USDT, B to A rate should be ~0.5e9 (ratio 2:1)
            assert!(rate_b_to_a > 400_000_000, 0); // Greater than 0.4
            assert!(rate_b_to_a < 600_000_000, 1); // Less than 0.6
            
            // Compare with A to B rate
            let rate_a_to_b = pool::get_exchange_rate(&pool);
            
            // Rates should be reciprocal (approximately)
            // rate_a_to_b * rate_b_to_a should be close to 1e18
            let product = (rate_a_to_b as u128) * (rate_b_to_a as u128);
            assert!(product > 900_000_000_000_000_000, 2); // > 0.9e18
            assert!(product < 1_100_000_000_000_000_000, 3); // < 1.1e18
            
            clock::destroy_for_testing(clock);
            pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_get_effective_rate() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let pool = pool::create_pool_for_testing<ETH, USDT>(30, 10, 0, ctx);
            
            // Add liquidity
            let coin_a = coin::mint_for_testing<ETH>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(10000000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                999999999,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            sui::transfer::public_transfer(position, owner);
            
            // Test effective rate for A to B
            let amount_in = 1000;
            let effective_rate = pool::get_effective_rate(&pool, amount_in, true);
            
            // Effective rate should be positive
            assert!(effective_rate > 0, 0);
            
            // Effective rate should be less than spot rate due to slippage and fees
            let spot_rate = pool::get_exchange_rate(&pool);
            assert!(effective_rate < spot_rate, 1);
            
            // Test with zero amount
            let zero_rate = pool::get_effective_rate(&pool, 0, true);
            assert!(zero_rate == 0, 2);
            
            clock::destroy_for_testing(clock);
            pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_get_price_impact_for_amount() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let pool = pool::create_pool_for_testing<ETH, USDT>(30, 10, 0, ctx);
            
            // Add liquidity
            let coin_a = coin::mint_for_testing<ETH>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDT>(10000000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                999999999,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            sui::transfer::public_transfer(position, owner);
            
            // Test price impact for small amount
            let small_amount = 1000;
            let small_impact = pool::get_price_impact_for_amount(&pool, small_amount, true);
            
            // Small trade should have low impact
            assert!(small_impact < 100, 0); // Less than 1%
            
            // Test price impact for large amount
            let large_amount = 1000000;
            let large_impact = pool::get_price_impact_for_amount(&pool, large_amount, true);
            
            // Large trade should have higher impact
            assert!(large_impact > small_impact, 1);
            
            // Test with zero amount
            let zero_impact = pool::get_price_impact_for_amount(&pool, 0, true);
            assert!(zero_impact == 0, 2);
            
            clock::destroy_for_testing(clock);
            pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_stable_pool_get_exchange_rate_b_to_a() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = stable_pool::create_pool<USDC, DAI>(30, 10, 0, 100, ctx);
            
            // Empty pool should return 0
            let rate = stable_pool::get_exchange_rate_b_to_a(&pool);
            assert!(rate == 0, 0);
            
            stable_pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_stable_pool_get_effective_rate() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let pool = stable_pool::create_pool<USDC, DAI>(30, 10, 0, 100, ctx);
            
            // Add liquidity
            let coin_a = coin::mint_for_testing<USDC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<DAI>(10000000, ctx);
            
            let (position, refund_a, refund_b) = stable_pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                999999999,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            sui::transfer::public_transfer(position, owner);
            
            // Test effective rate
            let amount_in = 1000;
            let effective_rate = stable_pool::get_effective_rate(&pool, amount_in, true);
            
            // Effective rate should be positive
            assert!(effective_rate > 0, 0);
            
            // For stable pools, effective rate should be close to 1:1 (1e9)
            assert!(effective_rate > 900_000_000, 1); // > 0.9
            assert!(effective_rate < 1_100_000_000, 2); // < 1.1
            
            clock::destroy_for_testing(clock);
            stable_pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_stable_pool_get_price_impact_for_amount() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let pool = stable_pool::create_pool<USDC, DAI>(30, 10, 0, 100, ctx);
            
            // Add liquidity
            let coin_a = coin::mint_for_testing<USDC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<DAI>(10000000, ctx);
            
            let (position, refund_a, refund_b) = stable_pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                999999999,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            sui::transfer::public_transfer(position, owner);
            
            // Test price impact
            let amount_in = 1000;
            let impact = stable_pool::get_price_impact_for_amount(&pool, amount_in, true);
            
            // Stable pools should have very low price impact for normal trades
            assert!(impact < 50, 0); // Less than 0.5%
            
            // Test with zero amount
            let zero_impact = stable_pool::get_price_impact_for_amount(&pool, 0, true);
            assert!(zero_impact == 0, 1);
            
            clock::destroy_for_testing(clock);
            stable_pool::share(pool);
        };

        test_scenario::end(scenario_val);
    }
}
