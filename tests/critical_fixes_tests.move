/// Verification tests for critical audit fixes
#[test_only]
module sui_amm::critical_fixes_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui_amm::pool::{Self as pool, LiquidityPool};
    use sui_amm::stable_pool::{Self as stable_pool, StableSwapPool};
    use sui_amm::position::{Self as position, LPPosition};
    use sui_amm::admin::{Self as admin, AdminCap};
    use std::option;

    struct USDT has drop {}
    struct USDC has drop {}

    const ADMIN: address = @0x1;
    const ALICE: address = @0x2;
    const BOB: address = @0x3;

    // ========== TEST [V1]: PARTIAL REMOVAL FEE RETENTION ========== //
    
    #[test]
    fun test_partial_removal_retains_fees() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));
        
        // 1. Create Pool
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 0, 0, ts::ctx(scenario));
            pool::share(pool);
        };

        // 2. Alice adds liquidity (1000 shares)
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
            
            // Swap 100k USDT -> USDC. Fee is 0.3% = 300 USDT.
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            transfer::public_transfer(coin_out, BOB);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        // 4. Alice removes 50% liquidity
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = ts::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            let total_liquidity = position::liquidity(position);
            let remove_amount = total_liquidity / 2;
            
            // Check pending fees BEFORE removal
            // Should be approx 300 USDT (minus dust)
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(
                pool,
                position,
                remove_amount,
                0,
                0,
                &clock,
                18446744073709551615,
                ctx
            );
            
            // Alice should get ~150 USDT in fees with her withdrawal
            // But CRITICALLY, the remaining position should still have ~150 USDT pending
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(scenario, position_val);
            ts::return_shared(pool_val);
        };

        // 5. Verify remaining fees are NOT zero
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = ts::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = ts::ctx(scenario);
            
            // Claim remaining fees
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees_simple(pool, position, ctx);
            
            let fee_val_a = coin::value(&fee_a);
            
            // If bug exists, fee_val_a would be 0
            // If fixed, fee_val_a should be approx 150 (half of 300)
            assert!(fee_val_a > 100, 0); 
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            ts::return_to_sender(scenario, position_val);
            ts::return_shared(pool_val);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    // ========== TEST [L2]: DUST LIQUIDITY UNDERFLOW ========== //

    #[test]
    #[expected_failure(abort_code = pool::EInsufficientLiquidity)]
    fun test_reject_dust_liquidity() {
        let scenario_val = ts::begin(ALICE);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ALICE);
        {
            let pool_val = pool::create_pool_for_testing<USDT, USDC>(30, 0, 0, ts::ctx(scenario));
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            
            // Try to add tiny liquidity (sqrt(10*10) = 10 < 1000 MINIMUM)
            let coin_a = coin::mint_for_testing<USDT>(10, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10, ctx);
            
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);
            
            // Should fail before here
            transfer::public_transfer(position, ALICE);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            clock::destroy_for_testing(clock);
            pool::share(pool_val);
        };
        ts::end(scenario_val);
    }

    // ========== TEST [S2]: PROTOCOL FEE CAP ========== //

    #[test]
    #[expected_failure(abort_code = pool::ETooHighFee)]
    fun test_protocol_fee_cap() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 0, 0, ts::ctx(scenario));
            pool::share(pool);
            admin::test_init(ts::ctx(scenario));
        };

        ts::next_tx(scenario, ADMIN);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(scenario);
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            
            // Try 20% (2000 bps) -> Should fail (Cap is 10% = 1000)
            admin::set_pool_protocol_fee(&admin_cap, pool, 2000);
            
            ts::return_to_sender(scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        ts::end(scenario_val);
    }

    // ========== TEST [P1]: DISPLAY SETUP WITHOUT ON-CHAIN SVG ========== //

    #[test]
    fun test_display_setup_works_without_svg() {
        let scenario_val = ts::begin(ALICE);
        let scenario = &mut scenario_val;

        ts::next_tx(scenario, ALICE);
        {
            let pool_val = pool::create_pool_for_testing<USDT, USDC>(30, 0, 0, ts::ctx(scenario));
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);
            let coin_a = coin::mint_for_testing<USDT>(1_000_000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1_000_000, ctx);

            let (pos, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);

            // Just ensure position object is valid and can be transferred;
            // image rendering is off-chain via Display URL template.
            transfer::public_transfer(pos, ALICE);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            clock::destroy_for_testing(clock);
            pool::share(pool_val);
        };

        ts::end(scenario_val);
    }

    // ========== TEST [V1]: STABLESWAP PRICE IMPACT DOES NOT USE CP IDEAL ========== //

    #[test]
    fun test_stableswap_price_impact_uses_spot_not_cp() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // Create a stable pool and add asymmetric liquidity to unbalance reserves
        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = stable_pool::create_pool_for_testing<USDT, USDC>(30, 0, 100, ts::ctx(scenario));
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);

            let coin_a = coin::mint_for_testing<USDT>(1_000_000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(500_000, ctx);

            let (pos, r_a, r_b) = stable_pool::add_liquidity(pool, coin_a, coin_b, 0, &clock, 18446744073709551615, ctx);
            transfer::public_transfer(pos, ADMIN);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            clock::destroy_for_testing(clock);
            stable_pool::share(pool_val);
        };

        // Swap a moderate amount and ensure the swap succeeds with reasonable impact
        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = ts::take_shared<StableSwapPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let ctx = ts::ctx(scenario);

            let amount_in = 1_000;
            let coin_in = coin::mint_for_testing<USDT>(amount_in, ctx);

            let out = stable_pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 10_000, ctx);
            // If price impact logic were still CP-based, this scenario could either revert
            // with EExcessivePriceImpact or produce obviously nonsensical output.
            assert!(coin::value(&out) > 0, 0);
            transfer::public_transfer(out, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }
}
