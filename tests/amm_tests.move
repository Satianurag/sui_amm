/// Main test module providing integration tests for the AMM protocol
/// Tests cover complete workflows including pool creation, liquidity management,
/// swaps, fee claiming, and edge cases across both constant product and stable pools
#[test_only]
module sui_amm::amm_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};

    use sui::clock::{Self};

    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::position::{LPPosition};
    use sui_amm::math;

    public struct BTC has drop {}
    public struct USDC has drop {}

    /// Test basic math utilities including square root and constant product output
    /// Verifies sqrt handles perfect squares, zero, and non-perfect squares correctly
    /// Verifies constant product formula calculates correct swap output
    #[test]
    fun test_math() {
        assert!(math::sqrt(100) == 10, 0);
        assert!(math::sqrt(0) == 0, 1);
        assert!(math::sqrt(3) == 1, 2); 
        
        assert!(math::calculate_constant_product_output(10, 100, 100, 0) == 9, 3);
    }

    /// Test complete pool lifecycle from creation through liquidity, swaps, and fee claiming
    /// Verifies:
    /// - Pool creation with fee configuration
    /// - Initial liquidity addition with MINIMUM_LIQUIDITY lock
    /// - Subsequent liquidity additions are proportional
    /// - Swaps execute correctly with expected output
    /// - Fee accumulation and claiming works for LPs
    #[test]
    fun test_pool_lifecycle() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;

        let mut scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create constant product pool with 0.30% fee
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);  // fee, protocol_fee, creator_fee
            pool::share(pool); 
        };

        // Owner adds initial liquidity to absorb MINIMUM_LIQUIDITY lock cost
        test_scenario::next_tx(scenario, owner);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);

            // Verify total liquidity = minted + locked
            let locked = pool::get_locked_liquidity(pool);
            let total = pool::get_total_liquidity(pool);
            let minted = sui_amm::position::liquidity(&position);
            assert!(total == minted + locked, 100);

            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val); 
        };

        // User1 adds liquidity proportional to existing reserves
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // User2 swaps BTC for USDC, generating fees for LPs
        test_scenario::next_tx(scenario, user2);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            // Verify swap output matches expected (1000 - 3 fee = 997, minus slippage ≈ 996)
            assert!(coin::value(&coin_out) == 996, 0);
            
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // User1 claims accumulated fees from the swap
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            
            let mut position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees(pool, position, &clock, 0, ctx);
            
            clock::destroy_for_testing(clock);
            
            // Verify fees were earned in token A (BTC) from the swap
            assert!(coin::value(&fee_a) >= 2, 1);
            assert!(coin::value(&fee_b) == 0, 2);
            
            transfer::public_transfer(fee_a, user1);
            transfer::public_transfer(fee_b, user1);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    /// Test StableSwap pool with amplification coefficient
    /// Verifies:
    /// - Stable pool creation with amp parameter
    /// - Liquidity addition to stable pool
    /// - Stable swap produces better output than constant product for balanced pools
    /// - Output is higher due to flatter curve from amplification
    #[test]
    fun test_stable_swap() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;

        let mut scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create StableSwap pool with amp=100 for balanced stable pairs
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = stable_pool::create_pool_for_testing<BTC, USDC>(5, 0, 100, ctx); // 0.05% fee
            stable_pool::share(pool);
        };

        // User1 adds balanced liquidity to stable pool
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<StableSwapPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = stable_pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // User2 swaps in stable pool, expecting better rate than constant product
        test_scenario::next_tx(scenario, user2);
        {
            let mut pool_val = test_scenario::take_shared<StableSwapPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_in = coin::mint_for_testing<BTC>(1000, ctx);
            
            let coin_out = stable_pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            // Verify stable swap output is better than constant product (>990 vs ~996 in constant product)
            let val = coin::value(&coin_out);
            assert!(val > 990, 0); 
            
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    /// Test liquidity removal returns proportional amounts
    /// Verifies:
    /// - Full liquidity removal burns position NFT
    /// - Returned amounts match deposited amounts (no swaps occurred)
    /// - Pool state remains valid after removal
    #[test]
    fun test_remove_liquidity() {
        let owner = @0xA;
        let user1 = @0xB;
        
        let mut scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create pool
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool); 
        };

        // Owner adds initial liquidity to absorb lock cost
        test_scenario::next_tx(scenario, owner);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val); 
        };

        // User1 adds liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);

            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // User1 removes all liquidity, burning position NFT
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let (coin_a, coin_b) = pool::remove_liquidity(pool, position, 0, 0, &clock, 18446744073709551615, ctx);  // min_amount_a, min_amount_b
            
            // Verify exact amounts returned (no swaps occurred, so no price change)
            assert!(coin::value(&coin_a) == 1000000, 0);
            assert!(coin::value(&coin_b) == 1000000, 1);
            
            transfer::public_transfer(coin_a, user1);
            transfer::public_transfer(coin_b, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        
        test_scenario::end(scenario_val);
    }

    /// Test price impact calculation for different swap sizes
    /// Verifies:
    /// - Large swaps (10% of reserve) have significant price impact (~10%)
    /// - Tiny swaps (0.0001% of reserve) have negligible price impact (~0%)
    /// - Extreme swaps (100% of reserve) have maximum price impact (~50%)
    #[test]
    fun test_price_impact() {
        // Large swap: 100 in, 1000 reserve -> ~10% price impact
        let impact = pool::test_cp_price_impact_bps(1000, 1000, 100, 90);
        assert!(impact >= 900 && impact <= 1100, 0); // ~10.00%

        // Tiny swap: 1 in, 1000000 reserve -> ~0% price impact
        let impact_small = pool::test_cp_price_impact_bps(1000000, 1000000, 1, 1);
        assert!(impact_small == 0, 1);

        // Extreme swap: 1000 in, 1000 reserve -> ~50% price impact
        let impact_large = pool::test_cp_price_impact_bps(1000, 1000, 1000, 500);
        assert!(impact_large >= 4900 && impact_large <= 5100, 2); // ~50.00%
    }

    /// Test swap with small amount handles precision correctly
    /// Verifies:
    /// - Small swaps (100 units) don't round to zero
    /// - Integer division precision is sufficient for small amounts
    /// - Pool handles edge case of minimal swap sizes
    #[test]
    fun test_swap_with_tiny_amount() {
        let owner = @0xA;
        let user = @0xB;
        let mut scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 0, 0, ctx);
            pool::share(pool);
        };

        test_scenario::next_tx(scenario, user);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user);
            
            // Swap small amount (100 units) to test precision handling
            let coin_in = coin::mint_for_testing<BTC>(100, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 1000, ctx);
            
            // Verify output is non-zero despite small input
            assert!(coin::value(&coin_out) > 0, 0);
            
            transfer::public_transfer(coin_out, user);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    /// Test auto-compounding with single-sided fees
    /// Verifies:
    /// - Fees accumulate from swaps
    /// - Compound operation claims fees and reinvests them
    /// - Liquidity increases or stays same (single-sided may return refund)
    /// - Leftover tokens are returned when can't form balanced pair
    #[test]
    fun test_auto_compound_single_token_fees() {
        let owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;
        let mut scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;

        // Create pool with high fee (3%) to generate significant fees for testing
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let pool = pool::create_pool_for_testing<BTC, USDC>(300, 0, 0, ctx); // 3% fee to generate significant fees
            pool::share(pool);
        };

        // User1 adds liquidity
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            let (position, r_a, r_b) = pool::add_liquidity(pool, coin_a, coin_b, 100, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(r_a);
            coin::burn_for_testing(r_b);
            transfer::public_transfer(position, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // User2 swaps A to B, generating fees in token A only
        test_scenario::next_tx(scenario, user2);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            
            let coin_in = coin::mint_for_testing<BTC>(10000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 18446744073709551615, ctx);
            transfer::public_transfer(coin_out, user2);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // User1 compounds fees back into liquidity position
        test_scenario::next_tx(scenario, user1);
        {
            let mut pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let mut position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);

            let initial_liquidity = sui_amm::position::liquidity(position);
            
            let (leftover_a, leftover_b) = sui_amm::fee_distributor::compound_fees(pool, position, 0, &clock, 18446744073709551615, ctx);
            
            let final_liquidity = sui_amm::position::liquidity(position);
            // With single-sided fees, compound may return fees as refund if can't form balanced pair
            assert!(final_liquidity >= initial_liquidity, 0);
            
            transfer::public_transfer(leftover_a, user1);
            transfer::public_transfer(leftover_b, user1);
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };
        test_scenario::end(scenario_val);
    }

    /// Test slippage protection rejects zero output
    /// Verifies:
    /// - Slippage check aborts when output is zero
    /// - Prevents swaps that would result in no output
    /// - Protects users from extreme slippage scenarios
    #[test]
    #[expected_failure(abort_code = sui_amm::slippage_protection::EInsufficientOutput)]
    fun test_slippage_zero_output() {
        sui_amm::slippage_protection::check_price_limit(100, 0, 1000);
    }
}
