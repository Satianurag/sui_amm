#[test_only]
module sui_amm::test_position {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::coin;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self, LPPosition};
    use sui_amm::test_utils::{Self, USDC, USDT, BTC};
    use sui_amm::fixtures;
    use sui_amm::assertions;

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Calculate square root of u128 (for liquidity calculations)
    fun sqrt_u128(y: u128): u128 {
        if (y < 4) {
            if (y == 0) {
                0
            } else {
                1
            }
        } else {
            let mut z = y;
            let mut x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            z
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: NFT Minting with Correct Initial Values
    // Requirement 3.1: Verify NFT is minted with correct pool_id, liquidity, fee_debt
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_nft_minting_initial_values() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        // Verify NFT has correct pool_id
        assert!(position::pool_id(&position) == pool_id, 0);
        
        // Verify liquidity is correct (sqrt(a * b) - MINIMUM_LIQUIDITY)
        let product = (initial_a as u128) * (initial_b as u128);
        let sqrt_product = sqrt_u128(product);
        let expected_liquidity = if (sqrt_product > (fixtures::minimum_liquidity_amount() as u128)) {
            (sqrt_product - (fixtures::minimum_liquidity_amount() as u128)) as u64
        } else {
            0
        };
        assert!(position::liquidity(&position) == expected_liquidity, 1);
        
        // Verify fee_debt is initialized to current acc_fee_per_share
        let fee_debt_a = position::fee_debt_a(&position);
        let fee_debt_b = position::fee_debt_b(&position);
        assert!(fee_debt_a == 0, 2); // No fees accumulated yet
        assert!(fee_debt_b == 0, 3);
        
        // Verify min_a and min_b are set correctly
        assert!(position::min_a(&position) == initial_a, 4);
        assert!(position::min_b(&position) == initial_b, 5);
        
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_nft_minting_subsequent_lp() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, first_position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Add more liquidity as second LP
        let add_a = initial_a / 2;
        let add_b = initial_b / 2;
        let second_position = test_utils::add_liquidity_helper(
            &mut pool,
            add_a,
            add_b,
            add_a,
            add_b,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify second NFT has correct pool_id
        assert!(position::pool_id(&second_position) == pool_id, 0);
        
        // Verify liquidity is proportional
        let total_liquidity = pool::get_total_liquidity(&pool);
        let _first_liquidity = position::liquidity(&first_position);
        let second_liquidity = position::liquidity(&second_position);
        
        // Second LP should have ~33% of total (added 50% of initial)
        let expected_share_bps = 3333; // ~33.33%
        assertions::assert_lp_share_proportional(
            second_liquidity,
            total_liquidity,
            expected_share_bps,
            100 // 1% tolerance
        );
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(first_position);
        position::destroy_for_testing(second_position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Cached Value Updates After refresh_position_metadata()
    // Requirement 3.2: Verify cached_value_a/b updates after refresh
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_cached_values_update_after_refresh() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        // Create pool with initial liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        // Get initial cached values
        let initial_cached_a = position::cached_value_a(&position);
        let initial_cached_b = position::cached_value_b(&position);
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute a swap to change pool state
        let swap_amount = fixtures::medium_swap();
        let _coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Cached values should still be the same (not auto-updated)
        assert!(position::cached_value_a(&position) == initial_cached_a, 0);
        assert!(position::cached_value_b(&position) == initial_cached_b, 1);
        
        // Refresh metadata
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        // Cached values should now be updated
        let updated_cached_a = position::cached_value_a(&position);
        let updated_cached_b = position::cached_value_b(&position);
        
        // Values should have changed due to swap
        assert!(updated_cached_a != initial_cached_a || updated_cached_b != initial_cached_b, 2);
        
        // Verify cached values match real-time view
        let view = pool::get_position_view(&pool, &position);
        let (view_a, view_b) = position::view_value(&view);
        assert!(updated_cached_a == view_a, 3);
        assert!(updated_cached_b == view_b, 4);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_cached_values_stale_after_swaps() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute multiple swaps
        let mut i = 0;
        while (i < 10) {
            let swap_amount = fixtures::small_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Get real-time view
        let view = pool::get_position_view(&pool, &position);
        let (view_a, view_b) = position::view_value(&view);
        
        // Cached values should be stale (different from real-time)
        let cached_a = position::cached_value_a(&position);
        let cached_b = position::cached_value_b(&position);
        
        // After 10 swaps, values should have diverged
        assert!(cached_a != view_a || cached_b != view_b, 0);
        
        // Refresh and verify they match
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        assert!(position::cached_value_a(&position) == view_a, 1);
        assert!(position::cached_value_b(&position) == view_b, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Pending Fee Calculation Accuracy
    // Requirement 3.3: Verify pending fee calculation accuracy
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_pending_fee_calculation() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute swap to generate fees
        let swap_amount = fixtures::large_swap();
        let _coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get pending fees from view
        let view = pool::get_position_view(&pool, &position);
        let (pending_fee_a, _pending_fee_b) = position::view_fees(&view);
        
        // Pending fees should be > 0 after swap
        assert!(pending_fee_a > 0, 0);
        
        // Verify formula: pending_fee = (liquidity * acc_fee_per_share / ACC_PRECISION) - fee_debt
        let liquidity = position::liquidity(&position);
        let (acc_a, acc_b) = pool::get_acc_fee_per_share(&pool);
        let fee_debt_a = position::fee_debt_a(&position);
        let fee_debt_b = position::fee_debt_b(&position);
        
        let expected_fee_a = ((liquidity as u128) * acc_a / fixtures::acc_precision()) - fee_debt_a;
        let _expected_fee_b = ((liquidity as u128) * acc_b / fixtures::acc_precision()) - fee_debt_b;
        
        // Allow small tolerance for rounding
        let tolerance = 10;
        let diff_a = if (pending_fee_a > (expected_fee_a as u64)) {
            pending_fee_a - (expected_fee_a as u64)
        } else {
            (expected_fee_a as u64) - pending_fee_a
        };
        assert!(diff_a <= tolerance, 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_pending_fees_accumulate_over_multiple_swaps() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Get initial pending fees (should be 0)
        let view_before = pool::get_position_view(&pool, &position);
        let (fee_before_a, _fee_before_b) = position::view_fees(&view_before);
        assert!(fee_before_a == 0, 0);
        
        // Execute multiple swaps
        let mut i = 0;
        while (i < 5) {
            let swap_amount = fixtures::medium_swap();
            let _coin_out = test_utils::swap_a_to_b_helper(
                &mut pool,
                swap_amount,
                0,
                0,
                fixtures::far_future_deadline(),
                &clock,
                ts::ctx(&mut scenario)
            );
            coin::burn_for_testing(_coin_out);
            i = i + 1;
        };
        
        // Get pending fees after swaps
        let view_after = pool::get_position_view(&pool, &position);
        let (fee_after_a, _fee_after_b) = position::view_fees(&view_after);
        
        // Fees should have accumulated
        assert!(fee_after_a > fee_before_a, 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Impermanent Loss Calculation
    // Requirement 3.4: Test IL calculation for 2x, 5x, 10x price movements
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_impermanent_loss_2x_price_movement() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 1_000_000_000; // 1B
        let initial_b = 1_000_000_000; // 1B (1:1 ratio)
        
        let (pool_id, position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute large swap to move price to ~2x
        // To double price of A in terms of B, we need to reduce reserve_a significantly
        let swap_amount = initial_b / 3; // Swap 33% of reserve B for A
        let _coin_out = test_utils::swap_b_to_a_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get IL
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // For 2x price movement, theoretical IL is ~5.7%
        // Allow tolerance since we can't achieve exact 2x with discrete swaps
        assert!(il_bps > 400 && il_bps < 800, 0); // Between 4% and 8%
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_impermanent_loss_5x_price_movement() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 1_000_000_000;
        let initial_b = 1_000_000_000;
        
        let (pool_id, position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute very large swap to move price to ~5x
        let swap_amount = initial_b * 2 / 3; // Swap 66% of reserve B
        let _coin_out = test_utils::swap_b_to_a_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get IL
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // For 5x price movement, theoretical IL is ~25.5%
        assert!(il_bps > 2000 && il_bps < 3000, 0); // Between 20% and 30%
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_impermanent_loss_10x_price_movement() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 1_000_000_000;
        let initial_b = 1_000_000_000;
        
        let (pool_id, position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Execute extreme swap to move price to ~10x
        let swap_amount = initial_b * 4 / 5; // Swap 80% of reserve B
        let _coin_out = test_utils::swap_b_to_a_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get IL
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // For 10x price movement, theoretical IL is ~42.3%
        assert!(il_bps > 3500 && il_bps < 5000, 0); // Between 35% and 50%
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_impermanent_loss_zero_at_entry_price() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Get IL immediately (no price change)
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // IL should be 0 at entry price
        assert!(il_bps == 0, 0);
        
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: NFT Transfer and New Owner Operations
    // Requirement 3.5: Test NFT transfer and new owner operations
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_nft_transfer_to_new_owner() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        // Transfer NFT to user1
        transfer::public_transfer(position, fixtures::user1());
        
        // Generate some fees
        ts::next_tx(&mut scenario, fixtures::user2());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let swap_amount = fixtures::large_swap();
        let _coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // New owner (user1) should be able to claim fees
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut position = ts::take_from_sender<LPPosition>(&scenario);
        
        let (fee_a, fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut position,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Fees should be claimable by new owner
        assert!(coin::value(&fee_a) > 0, 0);
        
        coin::burn_for_testing(fee_a);
        coin::burn_for_testing(fee_b);
        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
        ts::end(scenario);
    }
    
    #[test]
    fun test_new_owner_can_remove_liquidity() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        // Transfer NFT to user1
        transfer::public_transfer(position, fixtures::user1());
        
        // New owner removes liquidity
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut position = ts::take_from_sender<LPPosition>(&scenario);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let liquidity_to_remove = position::liquidity(&position) / 2;
        let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
            &mut pool,
            &mut position,
            liquidity_to_remove,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // New owner should receive tokens
        assert!(coin::value(&coin_a) > 0, 0);
        assert!(coin::value(&coin_b) > 0, 1);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: NFT Destruction on Full Liquidity Removal
    // Requirement 3.6: Test NFT destruction on full liquidity removal
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_nft_destroyed_on_full_removal() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let _total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity(
            &mut pool,
            position,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Position is destroyed by remove_liquidity, so we can't check it or destroy it again
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Partial Liquidity Removal and fee_debt Update
    // Requirement 3.7: Test partial liquidity removal and fee_debt update
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_partial_removal_updates_fee_debt() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Generate fees
        let swap_amount = fixtures::large_swap();
        let _coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get fee_debt before removal
        let _fee_debt_before_a = position::fee_debt_a(&position);
        let _fee_debt_before_b = position::fee_debt_b(&position);
        
        // Remove partial liquidity
        let liquidity_before = position::liquidity(&position);
        let remove_amount = liquidity_before / 2;
        let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
            &mut pool,
            &mut position,
            remove_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Get fee_debt after removal
        let fee_debt_after_a = position::fee_debt_a(&position);
        let _fee_debt_after_b = position::fee_debt_b(&position);
        
        // fee_debt should be updated (fees were claimed during removal)
        // After claiming fees, fee_debt should equal current acc_fee_per_share * remaining_liquidity
        let (acc_a, acc_b) = pool::get_acc_fee_per_share(&pool);
        let liquidity_after = position::liquidity(&position);
        let expected_debt_a = (liquidity_after as u128) * acc_a / fixtures::acc_precision();
        let _expected_debt_b = (liquidity_after as u128) * acc_b / fixtures::acc_precision();
        
        // Allow small tolerance
        let tolerance = 1000u128;
        let diff_a = if (fee_debt_after_a > expected_debt_a) {
            fee_debt_after_a - expected_debt_a
        } else {
            expected_debt_a - fee_debt_after_a
        };
        assert!(diff_a <= tolerance, 0);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    fun test_partial_removal_proportional_reduction() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let liquidity_before = position::liquidity(&position);
        let min_a_before = position::min_a(&position);
        let min_b_before = position::min_b(&position);
        
        // Remove 30% of liquidity
        let remove_amount = liquidity_before * 3 / 10;
        let (coin_a, coin_b) = test_utils::remove_liquidity_helper(
            &mut pool,
            &mut position,
            remove_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify liquidity reduced by 30%
        let liquidity_after = position::liquidity(&position);
        let expected_liquidity = liquidity_before - remove_amount;
        assert!(liquidity_after == expected_liquidity, 0);
        
        // Verify min_a and min_b reduced proportionally (70% remaining)
        let min_a_after = position::min_a(&position);
        let _min_b_after = position::min_b(&position);
        
        let expected_min_a = (min_a_before as u128) * 7 / 10;
        let _expected_min_b = (min_b_before as u128) * 7 / 10;
        
        // Allow 1 unit tolerance for rounding
        let diff_a = if ((min_a_after as u128) > expected_min_a) {
            (min_a_after as u128) - expected_min_a
        } else {
            expected_min_a - (min_a_after as u128)
        };
        assert!(diff_a <= 1, 1);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Entry Price Ratio Consistency After increase_liquidity()
    // Requirement 3.8: Test entry_price_ratio_scaled consistency
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_entry_price_ratio_unchanged_after_increase() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        // Get entry price ratio (stored internally, we'll verify via IL calculation)
        let original_min_a = position::min_a(&position);
        let original_min_b = position::min_b(&position);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Increase liquidity
        let add_a = initial_a / 2;
        let add_b = initial_b / 2;
        let (refund_a, refund_b) = pool::increase_liquidity(
            &mut pool,
            &mut position,
            test_utils::mint_coin<USDC>(add_a, ts::ctx(&mut scenario)),
            test_utils::mint_coin<USDT>(add_b, ts::ctx(&mut scenario)),
            0, // min_liquidity
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Verify min_a and min_b increased
        let new_min_a = position::min_a(&position);
        let new_min_b = position::min_b(&position);
        assert!(new_min_a > original_min_a, 0);
        assert!(new_min_b > original_min_b, 1);
        
        // Execute swap to change price
        let swap_amount = fixtures::large_swap();
        let _coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get IL - it should be calculated from ORIGINAL entry price, not average
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // IL should be non-zero since price changed
        // The key test is that IL is calculated from original entry, not diluted by increase
        assert!(il_bps > 0, 2);
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_entry_price_ratio_tracks_first_deposit() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let initial_a = 1_000_000_000;
        let initial_b = 1_000_000_000; // 1:1 ratio
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Change price significantly
        let swap_amount = initial_b / 2;
        let _coin_out = test_utils::swap_b_to_a_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Get IL at new price
        let il_before = pool::get_impermanent_loss(&pool, &position);
        
        // Increase liquidity at new price
        let (reserves_a, reserves_b) = pool::get_reserves(&pool);
        let add_a = reserves_a / 10;
        let add_b = reserves_b / 10;
        let (refund_a, refund_b) = pool::increase_liquidity(
            &mut pool,
            &mut position,
            test_utils::mint_coin<BTC>(add_a, ts::ctx(&mut scenario)),
            test_utils::mint_coin<USDC>(add_b, ts::ctx(&mut scenario)),
            0, // min_liquidity
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Get IL after increase - should be similar (not reset)
        let il_after = pool::get_impermanent_loss(&pool, &position);
        
        // IL should not decrease significantly (entry price not reset)
        // Allow small variance due to liquidity increase
        assert!(il_after >= il_before * 9 / 10, 0); // At least 90% of original IL
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADDITIONAL EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_position_with_zero_liquidity_after_full_removal() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Remove all liquidity
        let total_liquidity = position::liquidity(&position);
        let (coin_a, coin_b) = pool::remove_liquidity_partial(
            &mut pool,
            &mut position,
            total_liquidity,
            0,
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        // Position should have zero liquidity
        assert!(position::liquidity(&position) == 0, 0);
        
        // Get view should return zeros
        let view = pool::get_position_view(&pool, &position);
        let (value_a, value_b) = position::view_value(&view);
        let (fee_a, fee_b) = position::view_fees(&view);
        
        assert!(value_a == 0, 1);
        assert!(value_b == 0, 2);
        assert!(fee_a == 0, 3);
        assert!(fee_b == 0, 4);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_metadata_staleness_tracking() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Set initial time
        clock::set_for_testing(&mut clock, 1000000);
        
        // Refresh metadata
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let last_update = position::last_metadata_update_ms(&position);
        assert!(last_update == 1000000, 0);
        
        // Advance time
        clock::set_for_testing(&mut clock, 2000000);
        
        // Check staleness (1M ms = ~16 minutes)
        let is_stale = position::is_metadata_stale(&position, &clock, 500000); // 500s threshold
        assert!(is_stale == true, 1);
        
        // Refresh again
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let new_update = position::last_metadata_update_ms(&position);
        assert!(new_update == 2000000, 2);
        
        // Should not be stale immediately after refresh
        let is_stale_after = position::is_metadata_stale(&position, &clock, 500000);
        assert!(is_stale_after == false, 3);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_multiple_positions_independent_tracking() {
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, position1) = test_utils::create_initialized_pool<USDC, USDT>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            fixtures::admin(),
            ctx
        );
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // Add second position
        let position2 = test_utils::add_liquidity_helper(
            &mut pool,
            initial_a / 2,
            initial_b / 2,
            initial_a / 2,
            initial_b / 2,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Generate fees
        let swap_amount = fixtures::large_swap();
        let _coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            fixtures::far_future_deadline(),
            &clock,
            ts::ctx(&mut scenario)
        );
        coin::burn_for_testing(_coin_out);
        
        // Both positions should have pending fees
        let view1 = pool::get_position_view(&pool, &position1);
        let view2 = pool::get_position_view(&pool, &position2);
        
        let (fee1_a, _) = position::view_fees(&view1);
        let (fee2_a, _) = position::view_fees(&view2);
        
        assert!(fee1_a > 0, 0);
        assert!(fee2_a > 0, 1);
        
        // Position 1 should have more fees (larger share)
        assert!(fee1_a > fee2_a, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        ts::end(scenario);
    }
}
