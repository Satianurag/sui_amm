#[test_only]
module sui_amm::il_verification_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{LPPosition};
    use std::option;

    struct BTC has drop {}
    public struct USDC has drop {}

    const ADMIN: address = @0xA;
    const LP: address = @0xB;
    const TRADER: address = @0xC;

    #[test]
    fun test_il_2x_price_change() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        ts::next_tx(scenario, ADMIN);
        {
            let ctx = ts::ctx(scenario);
            let lpool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::set_risk_params_for_testing(&mut lpool, 10000, 10000);
            pool::share(lpool);
        };

        // 2. Add Liquidity
        ts::next_tx(scenario, ADMIN);
        {
            let lpool = ts::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            // Add liquidity (1 BTC = 50,000 USDC)
            let coin_a = coin::mint_for_testing<BTC>(1_000_000_000, ctx); // 1 BTC
            let coin_b = coin::mint_for_testing<USDC>(50_000_000_000, ctx); // 50k USDC
            
            let (position, r_a, r_b) = pool::add_liquidity(&mut lpool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            
            transfer::public_transfer(position, LP);
            
            ts::return_shared(lpool);
            clock::destroy_for_testing(clock);
        };

        // 3. Swap to change price
        ts::next_tx(scenario, TRADER);
        {
            let lpool = ts::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            // Swap 20,000 USDC for BTC to push price up
            let coin_in = coin::mint_for_testing<USDC>(20_000_000_000, ctx);
            let coin_out = pool::swap_b_to_a<BTC, USDC>(&mut lpool, coin_in, 0, option::none(), &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(coin_out);
            
            ts::return_shared(lpool);
            clock::destroy_for_testing(clock);
        };

        // 4. Check IL
        ts::next_tx(scenario, LP);
        {
            let lpool = ts::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let position = ts::take_from_sender<LPPosition>(scenario);
            
            let il_bps = pool::get_impermanent_loss<BTC, USDC>(&lpool, &position);
            
            // Expected IL for significant price change
            assert!(il_bps > 0, 0);
            
            ts::return_shared(lpool);
            ts::return_to_sender(scenario, position);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_il_verification_known_values() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // 1. Create Pool
        ts::next_tx(scenario, ADMIN);
        {
            let ctx = ts::ctx(scenario);
            let lpool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::set_risk_params_for_testing(&mut lpool, 10000, 10000);
            pool::share(lpool);
        };

        // 2. Add Liquidity
        ts::next_tx(scenario, ADMIN);
        {
            let lpool = ts::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            // Add liquidity (1 BTC = 50,000 USDC)
            let coin_a = coin::mint_for_testing<BTC>(1_000_000_000, ctx); // 1 BTC
            let coin_b = coin::mint_for_testing<USDC>(50_000_000_000, ctx); // 50k USDC
            
            let (position, r_a, r_b) = pool::add_liquidity(&mut lpool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            
            transfer::public_transfer(position, LP);
            
            ts::return_shared(lpool);
            clock::destroy_for_testing(clock);
        };

        // 3. Swap to change price (0.5x)
        ts::next_tx(scenario, TRADER);
        {
            let lpool = ts::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            // Swap in ~0.414 BTC
            let coin_in = coin::mint_for_testing<BTC>(414_213_562, ctx); // 0.4142 BTC
            let coin_out = pool::swap_a_to_b<BTC, USDC>(&mut lpool, coin_in, 0, option::none(), &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(coin_out);
            
            ts::return_shared(lpool);
            clock::destroy_for_testing(clock);
        };

        // 4. Check IL
        ts::next_tx(scenario, LP);
        {
            let lpool = ts::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let position = ts::take_from_sender<LPPosition>(scenario);
            
            let il_bps = pool::get_impermanent_loss<BTC, USDC>(&lpool, &position);
            
            // For 0.5x price change, IL should be ~5.72% (572 bps)
            // Allow some tolerance due to fees and precision
            assert!(il_bps >= 500 && il_bps <= 650, 1);
            
            ts::return_shared(lpool);
            ts::return_to_sender(scenario, position);
        };

        ts::end(scenario_val);
    }
}
