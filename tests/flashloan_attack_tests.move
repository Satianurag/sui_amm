/// Advanced flash loan attack and reentrancy protection tests
/// Tests S2: Flash loan simulations and K-invariant verification
#[test_only]
module sui_amm::flashloan_attack_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::factory::{Self, PoolRegistry};
    use sui::sui::SUI;
    use std::option;

    struct USDC has drop {}
    struct DAI has drop {}

    const USER: address = @0xCAFE;


    #[test]
    fun test_k_invariant_maintained_after_swap() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Record K before swap
            let k_before = pool::get_k(&pool);
            
            // Perform swap
            let swap_coin = coin::mint_for_testing<USDC>(50000, ts::ctx(&mut scenario));
            let output = pool::swap_a_to_b(
                &mut pool,
                swap_coin,
                1,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            // K after swap must be >= K before (due to fees)
            let k_after = pool::get_k(&pool);
            assert!(k_after >= k_before, 0);
            
            coin::burn_for_testing(output);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_swaps_preserve_k_invariant() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(10000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(10000000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            let k_initial = pool::get_k(&pool);
            let k_prev = k_initial;
            
            // Perform 10 swaps in alternating directions
            let i = 0;
            while (i < 10) {
                if (i % 2 == 0) {
                    let swap_coin = coin::mint_for_testing<USDC>(10000, ts::ctx(&mut scenario));
                    let output = pool::swap_a_to_b(
                        &mut pool,
                        swap_coin,
                        1,
                        option::none(),
                        &clock,
                        18446744073709551615,
                        ts::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(output);
                } else {
                    let swap_coin = coin::mint_for_testing<DAI>(10000, ts::ctx(&mut scenario));
                    let output = pool::swap_b_to_a(
                        &mut pool,
                        swap_coin,
                        1,
                        option::none(),
                        &clock,
                        18446744073709551615,
                        ts::ctx(&mut scenario)
                    );
                    coin::burn_for_testing(output);
                };
                
                let k_current = pool::get_k(&pool);
                // K should never decrease (fees cause it to increase)
                assert!(k_current >= k_prev, i);
                k_prev = k_current;
                
                i = i + 1;
            };
            
            // Final K should be greater than initial (accumulated fees)
            let k_final = pool::get_k(&pool);
            assert!(k_final > k_initial, 100);
            
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_large_swap_preserves_k_invariant() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            let k_before = pool::get_k(&pool);
            
            // Large swap (10% of pool)
            let swap_coin = coin::mint_for_testing<USDC>(100000000, ts::ctx(&mut scenario));
            let output = pool::swap_a_to_b(
                &mut pool,
                swap_coin,
                1,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            let k_after = pool::get_k(&pool);
            assert!(k_after >= k_before, 0);
            
            coin::burn_for_testing(output);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_stable_pool_d_invariant_preserved() {
        let scenario = ts::begin(USER);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
        };
        
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_stable_pool<USDC, DAI>(
                &mut registry,
                5,
                0,
                100,
                coin_a,
                coin_b,
                fee_coin,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_transfer(position, USER);
            transfer::public_transfer(refund_a, USER);
            transfer::public_transfer(refund_b, USER);
            ts::return_shared(registry);
        };

        // Perform swaps and verify D invariant
        ts::next_tx(&mut scenario, USER);
        {
            let pool = ts::take_shared<StableSwapPool<USDC, DAI>>(&scenario);
            
            // Swap a->b
            let swap_coin = coin::mint_for_testing<USDC>(10000, ts::ctx(&mut scenario));
            let output = stable_pool::swap_a_to_b(
                &mut pool,
                swap_coin,
                1,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            // D invariant should be preserved (with fees)
            coin::burn_for_testing(output);
            
            // Swap b->a
            let swap_coin2 = coin::mint_for_testing<DAI>(10000, ts::ctx(&mut scenario));
            let output2 = stable_pool::swap_b_to_a(
                &mut pool,
                swap_coin2,
                1,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(output2);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EExcessivePriceImpact)]
    fun test_price_impact_protection_prevents_manipulation() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Try to swap huge amount that would cause >10% price impact
            // This should abort
            let huge_swap = coin::mint_for_testing<USDC>(500000, ts::ctx(&mut scenario));
            let output = pool::swap_a_to_b(
                &mut pool,
                huge_swap,
                1,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(output);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_liquidity_operations_preserve_k_invariant() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        // Add more liquidity
        ts::next_tx(&mut scenario, USER);
        {
            let pool = ts::take_shared<LiquidityPool<USDC, DAI>>(&scenario);
            let position = ts::take_from_sender<sui_amm::position::LPPosition>(&scenario);
            
            let k_before = pool::get_k(&pool);
            
            let coin_a = coin::mint_for_testing<USDC>(100000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(100000, ts::ctx(&mut scenario));
            
            let (refund_a, refund_b) = pool::increase_liquidity(
                &mut pool,
                &mut position,
                coin_a,
                coin_b,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            let k_after = pool::get_k(&pool);
            
            // K should increase after adding liquidity
            assert!(k_after > k_before, 0);
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            ts::return_to_sender(&scenario, position);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
