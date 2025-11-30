#[test_only]
module sui_amm::stable_pool_deadline_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use std::option;

    struct USDT has drop {}
    struct USDC has drop {}

    const ADMIN: address = @0x1;
    const ALICE: address = @0x2;

    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EDeadlinePassed)]
    fun test_stable_swap_deadline_expired() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // 1. Create Pool
        ts::next_tx(scenario, ADMIN);
        {
            let pool = stable_pool::create_pool_for_testing<USDT, USDC>(30, 0, 100, ts::ctx(scenario));
            stable_pool::share(pool);
        };

        // 2. Add Liquidity
        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = ts::take_shared<StableSwapPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            let coin_a = coin::mint_for_testing<USDT>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
            let (pos, r_a, r_b) = stable_pool::add_liquidity(pool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);
            transfer::public_transfer(pos, ADMIN);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 3. Try swap with expired deadline
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<StableSwapPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            // Advance clock to 1000
            clock::set_for_testing(&mut clock, 1000);
            
            let ctx = ts::ctx(scenario);
            let coin_in = coin::mint_for_testing<USDT>(1000, ctx);
            
            // Deadline is 500 (expired)
            let coin_out = stable_pool::swap_a_to_b<USDT, USDC>(pool, coin_in, 0, option::none(), &clock, 500, ctx);
            
            transfer::public_transfer(coin_out, ALICE);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }
}
