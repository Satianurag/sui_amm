#[test_only]
module sui_amm::advanced_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self, LPPosition};
    use sui_amm::admin::{Self, AdminCap};

    struct BTC has drop {}
    struct USDC has drop {}

    #[test]
    fun test_fee_accumulation_precision() {
        let owner = @0xA;
        let lp = @0xB;
        let trader = @0xC;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, lp);
            
            test_scenario::return_shared(pool_val);
        };

        // Perform many small swaps to test fee accumulation precision
        let i = 0;
        while (i < 10) {
            test_scenario::next_tx(scenario, trader);
            {
                let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
                let pool = &mut pool_val;
                let ctx = test_scenario::ctx(scenario);
                let clock = clock::create_for_testing(ctx);

                let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
                let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
                
                coin::burn_for_testing(coin_out);
                clock::destroy_for_testing(clock);
                test_scenario::return_shared(pool_val);
            };
            i = i + 1;
        };

        // Check fees
        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees_simple(pool, position, ctx);
            
            // 10 swaps * 1000 amount * 0.003 fee = 30 total fees
            assert!(coin::value(&fee_a) >= 29 && coin::value(&fee_a) <= 31, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_protocol_fee_withdrawal() {
        let owner = @0xA;
        let lp = @0xB;
        let trader = @0xC;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            // 10% protocol fee
            let pool = pool::create_pool<BTC, USDC>(30, 1000, 0, ctx);
            pool::share(pool);
            admin::test_init(ctx);
        };

        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
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
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Admin withdraws protocol fees
        test_scenario::next_tx(scenario, owner);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            
            let (fee_a, fee_b) = admin::withdraw_protocol_fees_from_pool(&admin_cap, pool, ctx);
            
            // Total fee = 30. Protocol share = 10% = 3.
            assert!(coin::value(&fee_a) >= 2 && coin::value(&fee_a) <= 4, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_auto_compound_increases_position() {
        let owner = @0xA;
        let lp = @0xB;
        let trader = @0xC;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
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

            let coin_in = coin::mint_for_testing<BTC>(50000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Auto compound
        test_scenario::next_tx(scenario, lp);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let liquidity_before = position::liquidity(position);
            
            // Fixed: Removed slippage args (0, 0) as test-only auto_compound doesn't take them
            let (coin_a, coin_b) = sui_amm::fee_distributor::auto_compound(pool, position, &clock, ctx);
            
            // Handle returned coins (dust)
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            let liquidity_after = position::liquidity(position);
            assert!(liquidity_after > liquidity_before, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_k_invariant_increases_with_fees() {
        let owner = @0xA;
        let trader = @0xB;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            test_scenario::return_shared(pool_val);
        };

        let k_before: u128; // Will be set after reading pool state

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            k_before = pool::get_k(pool);
            test_scenario::return_shared(pool_val);
        };

        // Swap
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(50000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // K should increase proportionally
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let k_after = pool::get_k(pool);
            
            assert!(k_after > k_before, 0);
            
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_k_invariant_maintained_through_operations() {
        let owner = @0xA;
        let trader = @0xB;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            test_scenario::return_shared(pool_val);
        };

        let k0: u128;
        let k1: u128;
        let k2: u128;
        
        // Initial K
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            k0 = pool::get_k(pool);
            test_scenario::return_shared(pool_val);
        };

        // Swap 1
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(50000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            
            k1 = pool::get_k(pool);
            test_scenario::return_shared(pool_val);
        };

        // Swap 2
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<USDC>(50000, ctx);
            let coin_out = pool::swap_b_to_a(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            
            k2 = pool::get_k(pool);
            test_scenario::return_shared(pool_val);
        };

        // K should never decrease
        assert!(k1 >= k0, 0);
        assert!(k2 >= k1, 1);

        test_scenario::end(scenario_val);
    }
}
