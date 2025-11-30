#[test_only]
module sui_amm::slippage_edge_tests {
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
    #[expected_failure(abort_code = slippage_protection::EDeadlinePassed)]
    fun test_deadline_exactly_passed() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
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
            transfer::public_transfer(position, owner);
            
            test_scenario::return_shared(pool_val);
        };

        // Try swap with deadline already passed
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            clock::set_for_testing(&mut clock, 5000); // Clock at 5000ms
            
            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Deadline is 4999ms (already passed)
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 4999, ctx);
            
            transfer::public_transfer(coin_out, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_deadline_exactly_at_timestamp() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
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
            transfer::public_transfer(position, owner);
            
            test_scenario::return_shared(pool_val);
        };

        // Swap with deadline exactly at current timestamp (should pass)
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            clock::set_for_testing(&mut clock, 5000);
            
            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Deadline exactly at 5000ms (should pass: timestamp <= deadline)
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 5000, ctx);
            
            transfer::public_transfer(coin_out, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_deadline_far_future() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
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
            transfer::public_transfer(position, owner);
            
            test_scenario::return_shared(pool_val);
        };

        // Swap with very far future deadline
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            
            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            // Deadline very far in future (max u64)
            let max_deadline = 18446744073709551615;
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, max_deadline, ctx);
            
            transfer::public_transfer(coin_out, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }


    #[test]
    fun test_check_slippage_exact_min() {
        // Should pass when output exactly equals min
        slippage_protection::check_slippage(1000, 1000);
    }

    #[test]
    #[expected_failure(abort_code = slippage_protection::EExcessiveSlippage)] // EExcessiveSlippage
    fun test_check_slippage_below_min() {
        slippage_protection::check_slippage(999, 1000);
    }

    #[test]
    fun test_check_price_limit_exact() {
        // Price exactly at limit (should pass)
        slippage_protection::check_price_limit(
            1000,           // amount_in
            1000,           // amount_out
            1_000_000_000   // max_price (1:1 ratio scaled by 1e9)
        );
    }

    #[test]
    #[expected_failure(abort_code = slippage_protection::EExcessiveSlippage)] // EExcessiveSlippage
    fun test_global_slippage_cap_exceeded() {
        slippage_protection::check_price_limit(
            1100,           // amount_in (more than expected)
            1000,           // amount_out
            1_000_000_000   // max_price (expecting 1:1)
        );
    }

    #[test]
    #[expected_failure(abort_code = slippage_protection::EExcessiveSlippage)] // EExcessiveSlippage
    fun test_check_price_limit_exceeded() {
        slippage_protection::check_price_limit(
            1100,           // amount_in (more than expected)
            1000,           // amount_out
            1_000_000_000   // max_price (expecting 1:1)
        );
    }
}
