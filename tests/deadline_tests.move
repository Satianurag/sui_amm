#[test_only]
module sui_amm::deadline_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::pool::{Self as pool, LiquidityPool};
    use sui_amm::position::{LPPosition};
    use std::option;

    struct USDT has drop {}
    struct USDC has drop {}

    const ADMIN: address = @0x1;
    const ALICE: address = @0x2;
    const BOB: address = @0x3;

    // ========== TEST [V3]: FEE CLAIM DEADLINE ENFORCEMENT ========== //

    #[test]
    #[expected_failure(abort_code = 0, location = sui_amm::slippage_protection)]
    fun test_claim_fees_expired_deadline() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // 1. Setup
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 0, 0, ts::ctx(scenario));
            pool::share(pool);
        };

        // 2. Alice adds liquidity
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            let coin_a = coin::mint_for_testing<USDT>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);
            
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, ALICE);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 3. Bob swaps to generate fees
        ts::next_tx(scenario, BOB);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            let coin_in = coin::mint_for_testing<USDT>(100000, ctx);
            
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 18446744073709551615, ctx);
            
            transfer::public_transfer(coin_out, BOB);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 4. Alice tries to claim fees with EXPIRED deadline
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = ts::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            // Let's increment clock
            clock::increment_for_testing(&mut clock, 1000);
            let now = clock::timestamp_ms(&clock); // 1000
            let expired_deadline = now - 1; // 999
            
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees(
                pool,
                position,
                &clock,
                expired_deadline,
                ctx
            );
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(scenario, position_val);
            ts::return_shared(pool_val);
        };

        ts::end(scenario_val);
    }
}
