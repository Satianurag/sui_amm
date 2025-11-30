#[test_only]
module sui_amm::il_tests {
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
    fun test_impermanent_loss() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        test_scenario::next_tx(scenario, owner);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool); 
            clock::destroy_for_testing(clock);
        };

        // Owner adds initial liquidity to eat the lock cost
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val); 
        };

        // 2. Add Liquidity (Initial Price: 1 BTC = 1000 USDC)
        // 100 BTC, 100,000 USDC
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx); // 1,000,000
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx); // 1,000,000

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            
            // Check initial IL is 0
            let il = pool::get_impermanent_loss(pool, &position);
            assert!(il == 0, 0);

            transfer::public_transfer(position, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 3. Change Price (Swap to double price of BTC)
        // To double BTC price (in terms of USDC), we need to buy BTC.
        // New State: 1 BTC = 4000 USDC (4x price) -> IL should be significant.
        // Or simpler: 1 BTC = 2000 USDC.
        // k = 100 * 100,000 = 10,000,000.
        // New Price = 2000.
        // y / x = 2000. y * x = 10,000,000.
        // (2000x) * x = 10,000,000 -> 2000x^2 = 10,000,000 -> x^2 = 5000 -> x = ~70.71
        // y = 2000 * 70.71 = 141,420.
        // So we need to swap to reach this state.
        
        test_scenario::next_tx(scenario, user2);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            // Swap USDC for BTC to increase BTC price
            // We want to put in USDC to take out BTC.
            // Let's just do a large swap.
            let coin_in = coin::mint_for_testing<USDC>(50000, ctx); // 50,000 USDC
            
            let coin_out = pool::swap_b_to_a(pool, coin_in, 0, option::none(), &clock, 100000, ctx);
            
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // 4. Check IL
        test_scenario::next_tx(scenario, user1);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &position_val;
            
            let il = pool::get_impermanent_loss(pool, position);
            
            // Expected IL for 2x price change is ~5.7% (570 bps)
            // For 4x price change is ~20% (2000 bps)
            // We did a large swap, let's just assert it's > 0.
            assert!(il > 0, 1);
            
            // std::debug::print(&il); 

            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
