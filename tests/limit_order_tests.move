/// Tests for limit orders module
#[test_only]
module sui_amm::limit_order_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use sui::object;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::limit_orders::{Self, OrderRegistry};

    struct BTC has drop {}
    public struct USDC has drop {}

    #[test]
    fun test_create_limit_order() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Initialize
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            limit_orders::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        // Add liquidity to pool
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Create limit order
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<OrderRegistry>(scenario);
            let registry = &mut registry_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Create order with target price and expiry
            let order_id = limit_orders::create_limit_order<BTC, USDC>(
                registry,
                pool_id,
                true, // is_a_to_b
                coin_in,
                2_000_000_000, // target_price (2:1 scaled by 1e9)
                500, // min_amount_out
                &clock,
                1000000, // expiry
                ctx
            );

            // Verify order was created
            let user_orders = limit_orders::get_user_orders(registry, owner);
            assert!(std::vector::length(&user_orders) == 1, 0);
            
            let pool_orders = limit_orders::get_pool_orders(registry, pool_id);
            assert!(std::vector::length(&pool_orders) == 1, 1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = limit_orders::EOrderExpired)]
    fun test_create_expired_order() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            limit_orders::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<OrderRegistry>(scenario);
            let registry = &mut registry_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            // Set clock to future
            clock::set_for_testing(&mut clock, 2000);

            let pool_id = object::id(pool);
            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Try to create order with expiry in the past - should fail
            let _order_id = limit_orders::create_limit_order<BTC, USDC>(
                registry,
                pool_id,
                true,
                coin_in,
                2_000_000_000,
                500,
                &clock,
                1000, // expiry before current time
                ctx
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = limit_orders::EInvalidPrice)]
    fun test_zero_target_price() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            limit_orders::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<OrderRegistry>(scenario);
            let registry = &mut registry_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Zero target price - should fail
            let _order_id = limit_orders::create_limit_order<BTC, USDC>(
                registry,
                pool_id,
                true,
                coin_in,
                0, // invalid
                500,
                &clock,
                1000000,
                ctx
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }
}
