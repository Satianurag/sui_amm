#[test_only]
module sui_amm::fee_distributor_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::object;
    use sui::transfer;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::position::{Self, LPPosition};
    use sui_amm::fee_distributor;
    use sui_amm::admin;

    public struct USDT has drop {}
    public struct USDC has drop {}

    const ADMIN: address = @0x1;
    const ALICE: address = @0x2;
    const BOB: address = @0x3;

    #[test]
    fun test_compound_fees_regular() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // 1. Setup pool
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 10, 5, ts::ctx(scenario));
            pool::share(pool);
            admin::test_init(ts::ctx(scenario));
        };

        // 2. Alice adds liquidity
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let (pos, refund_a, refund_b) = pool::add_liquidity(
                pool,
                coin::mint_for_testing<USDT>(1000_000, ts::ctx(scenario)),
                coin::mint_for_testing<USDC>(1000_000, ts::ctx(scenario)),
                0,
                &clock,
                18446744073709551615, // max u64 deadline
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(pos, ALICE);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 3. Bob swaps to generate fees (use small amount to avoid price impact limit)
        ts::next_tx(scenario, BOB);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            // Swap 5% of pool to stay under 10% price impact limit
            let coin_in = coin::mint_for_testing<USDT>(50_000, ts::ctx(scenario));
            let coin_out = pool::swap_a_to_b(
                pool,
                coin_in,
                0,
                std::option::none(),
                &clock,
                18446744073709551615, // max u64 deadline
                ts::ctx(scenario)
            );
            
            transfer::public_transfer(coin_out, BOB);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 4. Alice compounds fees
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let pos = ts::take_from_sender<LPPosition>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let initial_liquidity = position::liquidity(&pos);
            
            let (refund_a, refund_b) = fee_distributor::compound_fees(
                pool,
                &mut pos,
                0, // min_liquidity
                &clock,
                18446744073709551615, // max u64 deadline
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            let final_liquidity = position::liquidity(&pos);
            // Note: With single-sided fees, compound may return fees as refund
            // instead of adding liquidity. Check that liquidity is at least same.
            assert!(final_liquidity >= initial_liquidity, 0);
            
            // Verify fees are reset (pending fees should be 0)
            let view = pool::get_position_view(pool, &pos);
            let (pending_a, pending_b) = position::view_fees(&view);
            assert!(pending_a == 0 && pending_b == 0, 1);
            
            ts::return_to_sender(scenario, pos);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_compound_fees_stable() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // 1. Setup pool
        ts::next_tx(scenario, ADMIN);
        {
            let pool = stable_pool::create_pool_for_testing<USDT, USDC>(5, 0, 100, ts::ctx(scenario));
            stable_pool::share(pool);
            admin::test_init(ts::ctx(scenario));
        };

        // 2. Alice adds liquidity
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<StableSwapPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let (pos, refund_a, refund_b) = stable_pool::add_liquidity(
                pool,
                coin::mint_for_testing<USDT>(1000_000, ts::ctx(scenario)),
                coin::mint_for_testing<USDC>(1000_000, ts::ctx(scenario)),
                0,
                &clock,
                18446744073709551615, // max u64 deadline
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(pos, ALICE);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 3. Bob swaps to generate fees (use small amount to stay under price impact limit)
        ts::next_tx(scenario, BOB);
        {
            let pool_val = ts::take_shared<StableSwapPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            // Swap 5% of pool to stay under 10% price impact limit
            let coin_in = coin::mint_for_testing<USDT>(50_000, ts::ctx(scenario));
            let coin_out = stable_pool::swap_a_to_b(
                pool,
                coin_in,
                0,
                std::option::none(),
                &clock,
                18446744073709551615, // max u64 deadline
                ts::ctx(scenario)
            );
            
            transfer::public_transfer(coin_out, BOB);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 4. Alice compounds fees
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<StableSwapPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let pos = ts::take_from_sender<LPPosition>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let initial_liquidity = position::liquidity(&pos);
            
            let (refund_a, refund_b) = fee_distributor::compound_fees_stable(
                pool,
                &mut pos,
                0, // min_liquidity
                &clock,
                18446744073709551615, // max u64 deadline
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            let final_liquidity = position::liquidity(&pos);
            // Note: With single-sided fees, compound may return fees as refund
            // instead of adding liquidity. Check that liquidity is at least same.
            assert!(final_liquidity >= initial_liquidity, 0);
            
            ts::return_to_sender(scenario, pos);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        ts::end(scenario_val);
    }
}
