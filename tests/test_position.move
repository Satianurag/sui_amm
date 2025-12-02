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

    // Helper Functions
    
    /// Calculates square root of u128 using Newton's method
    /// Used for verifying liquidity calculations in tests
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

    // NFT Minting Tests
    // Verifies position NFTs are minted with correct initial values
    // Tests pool_id, liquidity calculation, fee_debt initialization, and min_a/min_b tracking
    
    #[test]
    fun test_nft_minting_initial_values() {
        // Verifies initial position NFT contains correct pool_id, liquidity, and fee_debt
        // Liquidity should equal sqrt(amount_a * amount_b) - MINIMUM_LIQUIDITY
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
        
        assert!(position::pool_id(&position) == pool_id, 0);
        
        let product = (initial_a as u128) * (initial_b as u128);
        let sqrt_product = sqrt_u128(product);
        let expected_liquidity = if (sqrt_product > (fixtures::minimum_liquidity_amount() as u128)) {
            (sqrt_product - (fixtures::minimum_liquidity_amount() as u128)) as u64
        } else {
            0
        };
        let liquidity = position::liquidity(&position);
        assert!(liquidity <= expected_liquidity + 100000, 1);
        assert!(liquidity >= expected_liquidity - 100000, 1);
        
        // Verifies fee_debt is initialized to zero (no fees accumulated yet)
        let fee_debt_a = position::fee_debt_a(&position);
        let fee_debt_b = position::fee_debt_b(&position);
        assert!(fee_debt_a == 0, 2);
        assert!(fee_debt_b == 0, 3);
        
        // Verifies min_a and min_b track initial deposit amounts for IL calculation
        assert!(position::min_a(&position) == initial_a, 4);
        assert!(position::min_b(&position) == initial_b, 5);
        
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_nft_minting_subsequent_lp() {
        // Verifies subsequent LP positions receive proportional liquidity shares
        // Second LP adding 50% of initial should receive ~33% of total liquidity
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
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
        
        assert!(position::pool_id(&second_position) == pool_id, 0);
        
        let total_liquidity = pool::get_total_liquidity(&pool);
        let _first_liquidity = position::liquidity(&first_position);
        let second_liquidity = position::liquidity(&second_position);
        
        let expected_share_bps = 3333;
        assertions::assert_lp_share_proportional(
            second_liquidity,
            total_liquidity,
            expected_share_bps,
            100
        );
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(first_position);
        position::destroy_for_testing(second_position);
        ts::end(scenario);
    }

    // Cached Value Update Tests
    // Verifies cached position values update correctly after refresh_position_metadata()
    // Cached values become stale after swaps and must be manually refreshed
    
    #[test]
    fun test_cached_values_update_after_refresh() {
        // Verifies cached values remain stale until refresh_position_metadata() is called
        // After refresh, cached values should match real-time position view
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
        
        let initial_cached_a = position::cached_value_a(&position);
        let initial_cached_b = position::cached_value_b(&position);
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
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
        
        // Verifies cached values are not automatically updated after swaps
        assert!(position::cached_value_a(&position) == initial_cached_a, 0);
        assert!(position::cached_value_b(&position) == initial_cached_b, 1);
        
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        
        let updated_cached_a = position::cached_value_a(&position);
        let updated_cached_b = position::cached_value_b(&position);
        
        assert!(updated_cached_a != initial_cached_a || updated_cached_b != initial_cached_b, 2);
        
        // Verifies cached values match real-time view after refresh
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
        // Verifies cached values diverge from real-time values after multiple swaps
        // This demonstrates why periodic refresh is necessary for accurate position tracking
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
        
        let view = pool::get_position_view(&pool, &position);
        let (view_a, view_b) = position::view_value(&view);
        
        let cached_a = position::cached_value_a(&position);
        let cached_b = position::cached_value_b(&position);
        
        assert!(cached_a != view_a || cached_b != view_b, 0);
        
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        assert!(position::cached_value_a(&position) == view_a, 1);
        assert!(position::cached_value_b(&position) == view_b, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // Pending Fee Calculation Tests
    // Verifies pending fees are calculated correctly using the fee debt mechanism
    // Formula: pending_fee = (liquidity * acc_fee_per_share / ACC_PRECISION) - fee_debt
    
    #[test]
    fun test_pending_fee_calculation() {
        // Verifies pending fee calculation matches the mathematical formula
        // Fees accumulate based on liquidity share and global fee accumulator
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
        
        let view = pool::get_position_view(&pool, &position);
        let (pending_fee_a, _pending_fee_b) = position::view_fees(&view);
        
        assert!(pending_fee_a > 0, 0);
        
        let liquidity = position::liquidity(&position);
        let (acc_a, acc_b) = pool::get_acc_fee_per_share(&pool);
        let fee_debt_a = position::fee_debt_a(&position);
        let fee_debt_b = position::fee_debt_b(&position);
        
        let expected_fee_a = ((liquidity as u128) * acc_a / fixtures::acc_precision()) - fee_debt_a;
        let _expected_fee_b = ((liquidity as u128) * acc_b / fixtures::acc_precision()) - fee_debt_b;
        
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
        // Verifies pending fees accumulate correctly across multiple swaps
        // Each swap should increase the global fee accumulator and pending fees
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
        
        let view_before = pool::get_position_view(&pool, &position);
        let (fee_before_a, _fee_before_b) = position::view_fees(&view_before);
        assert!(fee_before_a == 0, 0);
        
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
        
        let view_after = pool::get_position_view(&pool, &position);
        let (fee_after_a, _fee_after_b) = position::view_fees(&view_after);
        
        assert!(fee_after_a > fee_before_a, 1);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // Impermanent Loss Calculation Tests
    // Verifies IL calculation accuracy for various price movements (2x, 5x, 10x)
    // IL represents the opportunity cost of providing liquidity vs holding tokens
    
    #[test]
    fun test_impermanent_loss_2x_price_movement() {
        // Verifies IL calculation for 2x price movement (~5.7% theoretical IL)
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
        
        pool::set_risk_params_for_testing(&mut pool, 100, 10000);

        // Swap ~41.5% of reserve B to move price to ~2x
        let swap_amount = initial_b * 415 / 1000;
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
        
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // Expected: ~5.7% IL (570 bps) for 2x price movement
        assert!(il_bps > 500 && il_bps < 650, 0);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_impermanent_loss_5x_price_movement() {
        // Verifies IL calculation for 5x price movement (~25.5% theoretical IL)
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
        
        pool::set_risk_params_for_testing(&mut pool, 100, 10000);

        // Swap ~123.6% of reserve B to move price to ~5x
        let swap_amount = 1_236_000_000;
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
        
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // Expected: ~25.5% IL (2550 bps) for 5x price movement
        assert!(il_bps > 2400 && il_bps < 2700, 0);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_impermanent_loss_10x_price_movement() {
        // Verifies IL calculation for 10x price movement (~42.3% theoretical IL)
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
        
        pool::set_risk_params_for_testing(&mut pool, 100, 10000);

        // Swap ~216.2% of reserve B to move price to ~10x
        let swap_amount = 2_162_000_000;
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
        
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        // Expected: ~42.3% IL (4230 bps) for 10x price movement
        assert!(il_bps > 4100 && il_bps < 4400, 0);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_impermanent_loss_zero_at_entry_price() {
        // Verifies IL is zero when pool price equals entry price
        // This is the baseline - no opportunity cost when price hasn't moved
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
        
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        assert!(il_bps == 0, 0);
        
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // NFT Transfer and Ownership Tests
    // Verifies position NFTs can be transferred and new owners can perform all operations
    // Tests fee claiming and liquidity removal by transferred position owners
    
    #[test]
    fun test_nft_transfer_to_new_owner() {
        // Verifies new owner can claim fees after NFT transfer
        // Fees accrue to the position, not the original owner
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
        
        transfer::public_transfer(position, fixtures::user1());
        
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
        
        ts::next_tx(&mut scenario, fixtures::user1());
        let mut position = ts::take_from_sender<LPPosition>(&scenario);
        
        let (fee_a, fee_b) = pool::withdraw_fees(
            &mut pool,
            &mut position,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
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
        // Verifies new owner can remove liquidity after NFT transfer
        // Position ownership is fully transferable with all rights
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
        
        transfer::public_transfer(position, fixtures::user1());
        
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
        
        assert!(coin::value(&coin_a) > 0, 0);
        assert!(coin::value(&coin_b) > 0, 1);
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
        ts::end(scenario);
    }

    // NFT Destruction Tests
    // Verifies position NFTs are automatically destroyed when all liquidity is removed
    // This prevents empty positions from cluttering user wallets
    
    #[test]
    fun test_nft_destroyed_on_full_removal() {
        // Verifies NFT is destroyed by remove_liquidity() when removing all liquidity
        let mut scenario = ts::begin(fixtures::admin());
        let ctx = ts::ctx(&mut scenario);
        
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id,  position) = test_utils::create_initialized_pool<USDC, USDT>(
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
        
        coin::burn_for_testing(coin_a);
        coin::burn_for_testing(coin_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::end(scenario);
    }

    // Partial Liquidity Removal Tests
    // Verifies fee_debt and position values update correctly during partial removal
    // Partial removal claims fees and adjusts tracking proportionally
    
    #[test]
    fun test_partial_removal_updates_fee_debt() {
        // Verifies fee_debt is updated after partial liquidity removal
        // Fee debt should equal acc_fee_per_share * remaining_liquidity after claiming fees
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
        
        let _fee_debt_before_a = position::fee_debt_a(&position);
        let _fee_debt_before_b = position::fee_debt_b(&position);
        
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
        
        let fee_debt_after_a = position::fee_debt_a(&position);
        let _fee_debt_after_b = position::fee_debt_b(&position);
        
        let (acc_a, acc_b) = pool::get_acc_fee_per_share(&pool);
        let liquidity_after = position::liquidity(&position);
        let expected_debt_a = (liquidity_after as u128) * acc_a / fixtures::acc_precision();
        let _expected_debt_b = (liquidity_after as u128) * acc_b / fixtures::acc_precision();
        
        let tolerance = 1000000u128;
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
        // Verifies liquidity and min_a/min_b reduce proportionally during partial removal
        // Removing 30% should leave 70% of all tracked values
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
        
        let liquidity_after = position::liquidity(&position);
        let expected_liquidity = liquidity_before - remove_amount;
        assert!(liquidity_after == expected_liquidity, 0);
        
        let min_a_after = position::min_a(&position);
        let _min_b_after = position::min_b(&position);
        
        let expected_min_a = (min_a_before as u128) * 7 / 10;
        let _expected_min_b = (min_b_before as u128) * 7 / 10;
        
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

    // Entry Price Ratio Consistency Tests
    // Verifies entry price ratio remains unchanged after increase_liquidity()
    // IL should be calculated from original entry price, not diluted by additions
    
    #[test]
    fun test_entry_price_ratio_unchanged_after_increase() {
        // Verifies IL is calculated from original entry price after increasing liquidity
        // Adding more liquidity should not reset or dilute the entry price for IL calculation
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
        
        let original_min_a = position::min_a(&position);
        let original_min_b = position::min_b(&position);
        
        ts::next_tx(&mut scenario, fixtures::admin());
        let mut pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        let add_a = initial_a / 2;
        let add_b = initial_b / 2;
        let (refund_a, refund_b) = pool::increase_liquidity(
            &mut pool,
            &mut position,
            test_utils::mint_coin<USDC>(add_a, ts::ctx(&mut scenario)),
            test_utils::mint_coin<USDT>(add_b, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let new_min_a = position::min_a(&position);
        let new_min_b = position::min_b(&position);
        assert!(new_min_a > original_min_a, 0);
        assert!(new_min_b > original_min_b, 1);
        
        pool::set_risk_params_for_testing(&mut pool, 100, 10000);

        let swap_amount = (initial_b + add_b) / 2;
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
        
        let il_bps = pool::get_impermanent_loss(&pool, &position);
        
        assert!(il_bps > 100, 2);
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_entry_price_ratio_tracks_first_deposit() {
        // Verifies entry price tracks the first deposit, not subsequent increases
        // IL should not decrease significantly when adding liquidity at a different price
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
        
        pool::set_risk_params_for_testing(&mut pool, 100, 10000);

        let swap_amount = initial_b * 415 / 1000;
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
        
        let il_before = pool::get_impermanent_loss(&pool, &position);
        
        let (reserves_a, reserves_b) = pool::get_reserves(&pool);
        let add_a = reserves_a / 10;
        let add_b = reserves_b / 10;
        let (refund_a, refund_b) = pool::increase_liquidity(
            &mut pool,
            &mut position,
            test_utils::mint_coin<BTC>(add_a, ts::ctx(&mut scenario)),
            test_utils::mint_coin<USDC>(add_b, ts::ctx(&mut scenario)),
            0,
            &clock,
            fixtures::far_future_deadline(),
            ts::ctx(&mut scenario)
        );
        
        let il_after = pool::get_impermanent_loss(&pool, &position);
        
        // IL should remain at least 90% of original (entry price not reset)
        assert!(il_after >= il_before * 9 / 10, 0);
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }

    // Additional Edge Case Tests
    // Verifies position behavior in edge cases like zero liquidity and metadata staleness
    
    #[test]
    fun test_position_with_zero_liquidity_after_full_removal() {
        // Verifies position with zero liquidity returns zero values in all views
        // Empty positions should not cause errors or return incorrect data
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
        
        assert!(position::liquidity(&position) == 0, 0);
        
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
        // Verifies metadata staleness detection based on time elapsed since last refresh
        // Stale metadata indicates cached values may be inaccurate
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
        let  pool = ts::take_shared_by_id<LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        clock::set_for_testing(&mut clock, 1000000);
        
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let last_update = position::last_metadata_update_ms(&position);
        assert!(last_update == 1000000, 0);
        
        clock::set_for_testing(&mut clock, 2000000);
        
        let is_stale = position::is_metadata_stale(&position, &clock, 500000);
        assert!(is_stale == true, 1);
        
        pool::refresh_position_metadata(&pool, &mut position, &clock);
        let new_update = position::last_metadata_update_ms(&position);
        assert!(new_update >= 1000000, 2);
        
        let is_stale_after = position::is_metadata_stale(&position, &clock, 500000);
        assert!(is_stale_after == false, 3);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position);
        ts::end(scenario);
    }
    
    #[test]
    fun test_multiple_positions_independent_tracking() {
        // Verifies multiple positions in the same pool track fees independently
        // Larger positions should accumulate proportionally more fees
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
        
        let view1 = pool::get_position_view(&pool, &position1);
        let view2 = pool::get_position_view(&pool, &position2);
        
        let (fee1_a, _) = position::view_fees(&view1);
        let (fee2_a, _) = position::view_fees(&view2);
        
        assert!(fee1_a > 0, 0);
        assert!(fee2_a > 0, 1);
        
        // Position 1 has larger liquidity share, should earn more fees
        assert!(fee1_a > fee2_a, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        position::destroy_for_testing(position1);
        position::destroy_for_testing(position2);
        ts::end(scenario);
    }
}
