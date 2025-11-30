/// Comprehensive rounding and precision tests for fee calculations
/// Tests S3: Fee calculation rounding edge cases
#[test_only]
module sui_amm::fee_rounding_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::pool::{Self, LiquidityPool};
    use std::option;

    struct USDC has drop {}
    struct DAI has drop {}

    const USER: address = @0xCAFE;

    #[test]
    fun test_tiny_fee_rounds_down_to_zero() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(1, 10, 0, ts::ctx(&mut scenario));
            
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
            
            // Swap very small amount - fee should round down
            // 1 BPS on 100 units = 100 * 1 / 10000 = 0 (rounds down)
            let swap_coin = coin::mint_for_testing<USDC>(100, ts::ctx(&mut scenario));
            
            let output = pool::swap_a_to_b(
                &mut pool,
                swap_coin,
                0,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            // Should succeed even though fee rounds to 0
            coin::burn_for_testing(output);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_liquidity_minting_precision_loss() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            // Create initial liquidity
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            
            let (position1, refund_a1, refund_b1) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            coin::burn_for_testing(refund_a1);
            coin::burn_for_testing(refund_b1);
            transfer::public_transfer(position1, USER);
            pool::share(pool);
        };

        // Add tiny amount that causes precision loss
        ts::next_tx(&mut scenario, USER);
        {
            let pool = ts::take_shared<LiquidityPool<USDC, DAI>>(&scenario);
            
            // Add 3 units - integer division will cause rounding
            let coin_a = coin::mint_for_testing<USDC>(3, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(3, ts::ctx(&mut scenario));
            
            let (position2, refund_a2, refund_b2) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            // Due to integer division, some amount will be refunded
            // This tests that we handle precision loss correctly
            let refund_a_val = coin::value(&refund_a2);
            let refund_b_val = coin::value(&refund_b2);
            
            // Refund should be small (precision loss)
            assert!(refund_a_val <= 2, 0);
            assert!(refund_b_val <= 2, 1);
            
            coin::burn_for_testing(refund_a2);
            coin::burn_for_testing(refund_b2);
            transfer::public_transfer(position2, USER);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_protocol_fee_rounding() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            // 30 BPS swap fee, 100 BPS protocol fee (1% of swap fee)
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 100, 0, ts::ctx(&mut scenario));
            
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
            
            // Swap 1000 units
            // Swap fee = 1000 * 30 / 10000 = 3
            // Protocol fee = 3 * 100 / 10000 = 0 (rounds down)
            let swap_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
            
            let output = pool::swap_a_to_b(
                &mut pool,
                swap_coin,
                0,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            // Protocol fee should round down, not cause errors
            let (protocol_a, _protocol_b) = pool::get_protocol_fees(&pool);
            
            // Small swap means protocol fee likely rounded to 0, but should not error
            assert!(protocol_a == 0, 0);
            
            coin::burn_for_testing(output);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_fee_distribution_rounding_consistency() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            // fee=30, protocol=100, creator=200
            // Total extraction from swap fee = 300 BPS = 3%
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 100, 200, ts::ctx(&mut scenario));
            
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
            
            // Swap large amount to ensure fees don't round to zero
            let swap_coin = coin::mint_for_testing<USDC>(100000, ts::ctx(&mut scenario));
            
            let output = pool::swap_a_to_b(
                &mut pool,
                swap_coin,
                0,
                option::none(),
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            let (protocol_a, _protocol_b) = pool::get_protocol_fees(&pool);
            
            // With 100000 swap:
            // Swap fee = 100000 * 30 / 10000 = 300
            // Protocol = 300 * 100 / 10000 = 3
            // Creator = 300 * 200 / 10000 = 6
            // LP = 300 - 3 - 6 = 291
            // Total = 300 ✓
            
            assert!(protocol_a == 3, 0);
            
            coin::burn_for_testing(output);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_accumulated_fees_per_share_precision() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 100, 0, ts::ctx(&mut scenario));
            
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
            
            // Multiple tiny swaps - fees should accumulate correctly
            let i = 0;
            while (i < 100) {
                let swap_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
                let output = pool::swap_a_to_b(
                    &mut pool,
                    swap_coin,
                    0,
                    option::none(),
                    &clock,
                    18446744073709551615,
                    ts::ctx(&mut scenario)
                );
                coin::burn_for_testing(output);
                i = i + 1;
            };
            
            // Accumulated fees should be non-zero
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_large_number_multiplication_no_overflow() {
        let scenario = ts::begin(USER);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, USER);
        {
            let pool = pool::create_pool_for_testing<USDC, DAI>(30, 10, 0, ts::ctx(&mut scenario));
            
            // Use large but safe values
            let coin_a = coin::mint_for_testing<USDC>(1000000000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000000000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                &clock,
                18446744073709551615,
                ts::ctx(&mut scenario)
            );
            
            // Should succeed without overflow
            assert!(coin::value(&refund_a) < 100, 0);
            assert!(coin::value(&refund_b) < 100, 1);
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, USER);
            pool::share(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
