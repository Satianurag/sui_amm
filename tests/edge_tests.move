#[test_only]
module sui_amm::edge_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::slippage_protection;

    struct BTC has drop {}
    struct USDC has drop {}

    #[test]
    #[expected_failure(abort_code = slippage_protection::EExcessiveSlippage)] // ESlippageExceeded
    fun test_swap_with_price_limit_exceeded() {
        let owner = @0xA;
        let user = @0xB;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool); 
        };

        // 2. Add Liquidity
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            test_scenario::return_shared(pool_val);
        };

        // 3. Swap with strict price limit
        // Current price is 1:1 (1000000:1000000)
        // We set max_price to 0.5 (500_000_000 scaled by 1e9)
        // Price = amount_in / amount_out. 
        // If we swap 1000 BTC, we get ~996 USDC. Price ~ 1.004.
        // Limit 0.5 means we want to pay at most 0.5 BTC per USDC (i.e. get at least 2 USDC per BTC).
        // Wait, max_price definition in slippage_protection:
        // "Maximum amount of input tokens per 1 output token"
        // Price = amount_in / amount_out.
        // If Price <= max_price, trade executes.
        // Current price ~ 1.
        // If we set max_price = 0.5 (500_000_000), then 1 <= 0.5 is False. Abort.
        
        test_scenario::next_tx(scenario, user);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Set max price to 0.5 (500_000_000)
            let limit = option::some(500_000_000);
            
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, limit, &clock, 1000, ctx);
            
            transfer::public_transfer(coin_out, user);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_swap_with_price_limit_pass() {
        let owner = @0xA;
        let user = @0xB;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool); 
        };

        // 2. Add Liquidity
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            test_scenario::return_shared(pool_val);
        };

        // 3. Swap with loose price limit
        // Current price ~ 1.
        // Set max_price = 2.0 (2_000_000_000).
        // 1 <= 2.0 is True. Pass.
        
        test_scenario::next_tx(scenario, user);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Set max price to 2.0
            let limit = option::some(2_000_000_000);
            
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, limit, &clock, 1000, ctx);
            
            assert!(coin::value(&coin_out) > 0, 0);
            
            transfer::public_transfer(coin_out, user);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
