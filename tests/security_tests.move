/// Comprehensive security tests for critical fixes
#[test_only]
module sui_amm::security_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self, LPPosition};
    use sui_amm::fee_distributor::{Self, FeeRegistry};
    use std::option;

    // Test coins
    struct USDC has drop {}
    struct ETH has drop {}

    const ADMIN: address = @0x1;
    const ALICE: address = @0x2;
    const BOB: address = @0x3;

    // ========== CRITICAL TEST [V1]: Auto-Compound Slippage Protection ========== //
    
    #[test]
    fun test_autocompound_requires_slippage_params() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));
        
        // Create fee registry
        ts::next_tx(scenario, ADMIN);
        {
            fee_distributor::test_init(ts::ctx(scenario));
        };

        // Create pool with liquidity
        ts::next_tx(scenario, ALICE);
        {
            let pool = pool::create_pool<USDC, ETH>(30, 10, 5, ts::ctx(scenario));
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(scenario));
            let coin_b = coin::mint_for_testing<ETH>(1000000, ts::ctx(scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            transfer::public_transfer(position, ALICE);
            pool::share(pool);
        };

        // Simulate trades to accumulate fees
        ts::next_tx(scenario, BOB);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDC, ETH>>(scenario);
            let pool = &mut pool_val;
            let coin_in = coin::mint_for_testing<USDC>(10000, ts::ctx(scenario));
            
            let coin_out = pool::swap_a_to_b(
                pool,
                coin_in,
                0,
                option::none(),
                &clock,
                1000000000000,
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(coin_out);
            ts::return_shared(pool_val);
        };

        // Test auto_compound with slippage protection
        ts::next_tx(scenario, ALICE);
        {
            let registry_val = ts::take_shared<FeeRegistry>(scenario);
            let registry = &mut registry_val;
            let pool_val = ts::take_shared<LiquidityPool<USDC, ETH>>(scenario);
            let pool = &mut pool_val;
            let position_val = ts::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            
            // This should work with adequate slippage params
            let (leftover_a, leftover_b) = fee_distributor::auto_compound_with_deadline(
                registry,
                pool,
                position,
                1,  // min_out_a - acceptable slippage
                1,  // min_out_b - acceptable slippage
                &clock,
                2000000000000,
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(leftover_a);
            coin::burn_for_testing(leftover_b);
            
            ts::return_to_sender(scenario, position_val);
            ts::return_shared(pool_val);
            ts::return_shared(registry_val);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    // ========== CRITICAL TEST [V2]: Precision Loss Fix ========== //
    
    #[test]
    fun test_small_liquidity_removal_precision() {
        let scenario_val = ts::begin(ALICE);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));
        
        // Create pool
        ts::next_tx(scenario, ALICE);
        {
            let pool = pool::create_pool<USDC, ETH>(30, 10, 5, ts::ctx(scenario));
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(scenario));
            let coin_b = coin::mint_for_testing<ETH>(1000000, ts::ctx(scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            transfer::public_transfer(position, ALICE);
            pool::share(pool);
        };

        // Remove small amount (dust) - should not zero out min_a/min_b
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDC, ETH>>(scenario);
            let pool = &mut pool_val;
            let position_val = ts::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            
            let initial_liquidity = position::liquidity(position);
            let initial_min_a = position::min_a(position);
            let initial_min_b = position::min_b(position);
            
            // Remove tiny amount (0.1% of liquidity)
            let remove_amount = initial_liquidity / 1000;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(
                pool,
                position,
                remove_amount,
                0, // min amounts
                0,
                ts::ctx(scenario)
            );
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            // CRITICAL: Verify min_a and min_b were reduced properly, not zeroed
            let new_min_a = position::min_a(position);
            let new_min_b = position::min_b(position);
            
            assert!(new_min_a > 0, 0); // Should NOT be zero
            assert!(new_min_b > 0, 1); // Should NOT be zero
            assert!(new_min_a < initial_min_a, 2); // Should be reduced
            assert!(new_min_b < initial_min_b, 3); // Should be reduced
            
            ts::return_to_sender(scenario, position_val);
            ts::return_shared(pool_val);
        };

        // Remove more liquidity - should still work (not locked)
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDC, ETH>>(scenario);
            let pool = &mut pool_val;
            let position_val = ts::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            
            let remove_amount = position::liquidity(position) / 2;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(
                pool,
                position,
                remove_amount,
                0,
                0,
                ts::ctx(scenario)
            );
            
            // Should succeed without error
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            ts::return_to_sender(scenario, position_val);
            ts::return_shared(pool_val);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    // ========== CRITICAL TEST [L2]: High-Value Token Protection ========== //
    
    #[test]
    #[expected_failure(abort_code = pool::EInsufficientLiquidity)]
    fun test_reject_insufficient_initial_liquidity() {
        let scenario_val = ts::begin(ALICE);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ALICE);
        {
            let pool = pool::create_pool<USDC, ETH>(30, 10, 5, ts::ctx(scenario));
            
            // Try to create pool with very low liquidity (would burn 50%+)
            // Total liquidity = sqrt(5000 * 5000) = 5000
            // Burn = 1000, so creator gets 4000 (20% loss)
            // Should FAIL since 5000 < 100,000 required
            let coin_a = coin::mint_for_testing<USDC>(5000, ts::ctx(scenario));
            let coin_b = coin::mint_for_testing<ETH>(5000, ts::ctx(scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                ts::ctx(scenario)
            );
            
            // Should not reach here
            transfer::public_transfer(position, ALICE);
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            pool::share(pool);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_accept_adequate_initial_liquidity() {
        let scenario_val = ts::begin(ALICE);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ALICE);
        {
            let pool = pool::create_pool<USDC, ETH>(30, 10, 5, ts::ctx(scenario));
            
            // Adequate initial liquidity
            // sqrt(1000000 * 1000000) = 1000000 > 100000 minimum
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(scenario));
            let coin_b = coin::mint_for_testing<ETH>(1000000, ts::ctx(scenario));
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                0,
                ts::ctx(scenario)
            );
            
            // Creator loses <0.1% (1000 out of 1000000)
            let liquidity = position::liquidity(&position);
            assert!(liquidity > 990000, 0); // Got at least 99% back
            
            transfer::public_transfer(position, ALICE);
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            pool::share(pool);
        };

        ts::end(scenario_val);
    }
}
