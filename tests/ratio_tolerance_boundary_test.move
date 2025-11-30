#[test_only]
module sui_amm::ratio_tolerance_boundary_test {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use sui::sui::SUI;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::factory;
    use sui_amm::position;

    struct BTC has drop {}
    struct USDC has drop {}

    #[test]
    fun test_ratio_tolerance_boundary() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0,
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

        // Set tolerance to 0.5% (50 bps)
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            pool::set_risk_params_for_testing(pool, 50, 1000); // 50 bps = 0.5%
            test_scenario::return_shared(pool_val);
        };

        // Test exactly 0.5% deviation (should pass)
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            // Current ratio 1:1 (1M:1M)
            // Add 10000 BTC.
            // Ideal USDC = 10000.
            // Max deviation 0.5% = 50 units.
            // Try adding 10050 USDC.
            // diff = 50. max_val = 10050 * 1M (scaled).
            // Actually the check is:
            // val_a = amount_a * reserve_b = 10000 * 1M = 10B
            // val_b = amount_b * reserve_a = 10050 * 1M = 10.05B
            // diff = 0.05B
            // deviation = 0.05B * 10000 / 10.05B = 500 / 10.05 = 49.75 bps <= 50 bps.
            
            let coin_a = coin::mint_for_testing<BTC>(10000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10050, ctx);
            
            let (pos, r_a, r_b) = pool::add_liquidity(
                pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ctx
            );
            
            position::destroy_for_testing(pos);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = pool::EExcessivePriceImpact)]
    fun test_ratio_tolerance_boundary_fail() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0,
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

        // Set tolerance to 0.5% (50 bps)
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            pool::set_risk_params_for_testing(pool, 50, 1000); // 50 bps = 0.5%
            test_scenario::return_shared(pool_val);
        };

        // Test 0.51% deviation (should fail)
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_a = coin::mint_for_testing<BTC>(10000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10052, ctx); // > 0.5%
            
            let (pos, r_a, r_b) = pool::add_liquidity(
                pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ctx
            );
            
            position::destroy_for_testing(pos);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
