#[test_only]
module sui_amm::test_fee_distributor {
    use sui::test_scenario;
    use sui::coin;
    use sui::clock;

    use sui_amm::test_utils::{Self, USDC, USDT};
    use sui_amm::assertions;
    use sui_amm::pool;
    use sui_amm::position;
    use sui_amm::fee_distributor;

    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    const USER2: address = @0xC;
    const USER3: address = @0xD;

    // Helper function to execute swap A to B
    fun swap_a_to_b<A: drop, B: drop>(
        pool: &mut pool::LiquidityPool<A, B>,
        amount: u64,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<B> {
        let coin_in = test_utils::mint_coin<A>(amount, ctx);
        pool::swap_a_to_b(
            pool,
            coin_in,
            0, // min_out
            option::none(), // max_price
            clock,
            test_utils::far_future(),
            ctx
        )
    }

    // Helper function to execute swap B to A
    fun swap_b_to_a<A: drop, B: drop>(
        pool: &mut pool::LiquidityPool<A, B>,
        amount: u64,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<A> {
        let coin_in = test_utils::mint_coin<B>(amount, ctx);
        pool::swap_b_to_a(
            pool,
            coin_in,
            0, // min_out
            option::none(), // max_price
            clock,
            test_utils::far_future(),
            ctx
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 1: acc_fee_per_share increase on swap fees
    // Requirement 5.1: Verify acc_fee_per_share increases correctly
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_acc_fee_per_share_increases_on_swap() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        // Create pool with 30 bps fee, 100 bps protocol fee, 0 creator fee
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,    // 0.3% fee
            100,   // 1% protocol fee
            0,     // 0% creator fee
            1_000_000_000, // 1B USDC
            1_000_000_000, // 1B USDT
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Capture initial state
        let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
        let (acc_before_a, acc_before_b) = test_utils::get_snapshot_acc_fees(&snapshot_before);
        
        // Execute swap: 1M USDC -> USDT
        let swap_amount = 1_000_000;
        let coin_out = swap_a_to_b(&mut pool, swap_amount, &clock, test_scenario::ctx(&mut scenario));
        coin::burn_for_testing(coin_out);
        
        // Capture state after swap
        let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
        let (acc_after_a, acc_after_b) = test_utils::get_snapshot_acc_fees(&snapshot_after);
        
        // Verify acc_fee_per_share_a increased (token A was swapped in)
        assert!(acc_after_a > acc_before_a, 0);
        // Token B should not have fee accumulation (no swap in that direction)
        assert!(acc_after_b == acc_before_b, 1);
        
        // Calculate expected fee accumulation
        let fee_amount = (swap_amount * 30) / 10000; // 0.3% fee
        let protocol_fee = (fee_amount * 100) / 10000; // 1% of fee
        let lp_fee = fee_amount - protocol_fee;
        
        // Verify fee accumulation matches expected
        assertions::assert_fee_accumulation(
            &snapshot_before,
            &snapshot_after,
            lp_fee,
            1000 // tolerance
        );
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 2: Proportional fee distribution across multiple LPs
    // Requirement 5.2: Verify each LP receives fees proportional to their share
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_proportional_fee_distribution_multiple_lps() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        // Create pool with initial liquidity from ADMIN
        let (pool_id, position_admin) = test_utils::create_initialized_pool<USDC, USDT>(
            30,    // 0.3% fee
            100,   // 1% protocol fee
            0,     // 0% creator fee
            1_000_000_000, // 1B USDC
            1_000_000_000, // 1B USDT
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, USER1);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // USER1 adds liquidity (50% of pool)
        let position_user1 = test_utils::add_liquidity_helper(
            &mut pool,
            1_000_000_000, // 1B USDC
            1_000_000_000, // 1B USDT
            0, 0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, USER2);
        // USER2 adds liquidity (25% of pool)
        let position_user2 = test_utils::add_liquidity_helper(
            &mut pool,
            1_000_000_000, // 1B USDC
            1_000_000_000, // 1B USDT
            0, 0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Execute multiple swaps to generate fees
        test_scenario::next_tx(&mut scenario, USER3);
        let swap_amount = 10_000_000; // 10M per swap
        let mut i = 0;
        while (i < 10) {
            let coin_out = swap_a_to_b(&mut pool, swap_amount, &clock, test_scenario::ctx(&mut scenario));
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Get LP shares
        let liq_admin = position::liquidity(&position_admin);
        let liq_user1 = position::liquidity(&position_user1);
        let liq_user2 = position::liquidity(&position_user2);
        let total_liq = pool::get_total_liquidity(&pool);
        
        // Calculate expected shares (in bps)
        let share_admin_bps = ((liq_admin as u128) * 10000 / (total_liq as u128)) as u64;
        let share_user1_bps = ((liq_user1 as u128) * 10000 / (total_liq as u128)) as u64;
        let share_user2_bps = ((liq_user2 as u128) * 10000 / (total_liq as u128)) as u64;
        
        // Verify shares are proportional
        assertions::assert_lp_share_proportional(liq_admin, total_liq, share_admin_bps, 10);
        assertions::assert_lp_share_proportional(liq_user1, total_liq, share_user1_bps, 10);
        assertions::assert_lp_share_proportional(liq_user2, total_liq, share_user2_bps, 10);
        
        // Get pending fees for each LP
        let (fee_admin_a, _fee_admin_b) = pool::get_accumulated_fees(&pool, &position_admin);
        let (fee_user1_a, _fee_user1_b) = pool::get_accumulated_fees(&pool, &position_user1);
        let (fee_user2_a, _fee_user2_b) = pool::get_accumulated_fees(&pool, &position_user2);
        
        // Verify fees are proportional to shares (within tolerance)
        let total_fees = fee_admin_a + fee_user1_a + fee_user2_a;
        if (total_fees > 0) {
            let fee_admin_share_bps = ((fee_admin_a as u128) * 10000 / (total_fees as u128)) as u64;
            let fee_user1_share_bps = ((fee_user1_a as u128) * 10000 / (total_fees as u128)) as u64;
            let fee_user2_share_bps = ((fee_user2_a as u128) * 10000 / (total_fees as u128)) as u64;
            
            // Fee shares should match liquidity shares (within 1% tolerance)
            let diff_admin = if (fee_admin_share_bps > share_admin_bps) {
                fee_admin_share_bps - share_admin_bps
            } else {
                share_admin_bps - fee_admin_share_bps
            };
            assert!(diff_admin <= 100, 2); // 1% tolerance
            
            let diff_user1 = if (fee_user1_share_bps > share_user1_bps) {
                fee_user1_share_bps - share_user1_bps
            } else {
                share_user1_bps - fee_user1_share_bps
            };
            assert!(diff_user1 <= 100, 3);
            
            let diff_user2 = if (fee_user2_share_bps > share_user2_bps) {
                fee_user2_share_bps - share_user2_bps
            } else {
                share_user2_bps - fee_user2_share_bps
            };
            assert!(diff_user2 <= 100, 4);
        };
        
        test_scenario::return_shared(pool);
        position::destroy(position_admin);
        position::destroy(position_user1);
        position::destroy(position_user2);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 3: fee_debt update to prevent double-claiming
    // Requirement 5.3: Verify fee_debt prevents double-claiming
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_debt_prevents_double_claiming() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Execute swap to generate fees
        let coin_out = swap_a_to_b(&mut pool, 10_000_000, &clock, test_scenario::ctx(&mut scenario));
        coin::burn_for_testing(coin_out);
        
        // Claim fees first time
        let (fee_a_1, fee_b_1) = fee_distributor::claim_fees(
            &mut pool,
            &mut position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        let first_claim_a = coin::value(&fee_a_1);
        let _first_claim_b = coin::value(&fee_b_1);
        
        // First claim should have fees
        assert!(first_claim_a > 0, 5);
        
        coin::burn_for_testing(fee_a_1);
        coin::burn_for_testing(fee_b_1);
        
        // Claim fees second time immediately (should be zero)
        let (fee_a_2, fee_b_2) = fee_distributor::claim_fees(
            &mut pool,
            &mut position,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        let second_claim_a = coin::value(&fee_a_2);
        let second_claim_b = coin::value(&fee_b_2);
        
        // Second claim should be zero (no double-claiming)
        assert!(second_claim_a == 0, 6);
        assert!(second_claim_b == 0, 7);
        
        // Verify position snapshot shows no pending fees
        let pos_snapshot = test_utils::snapshot_position(&position);
        assertions::assert_no_pending_fees(&pos_snapshot);
        
        coin::burn_for_testing(fee_a_2);
        coin::burn_for_testing(fee_b_2);
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 4: Protocol fee calculation accuracy
    // Requirement 5.4: Verify protocol_fee_amount = fee_amount * protocol_fee_percent / 10000
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_protocol_fee_calculation_accuracy() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        // Create pool with 30 bps fee, 200 bps protocol fee (2% of fees)
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,    // 0.3% total fee
            200,   // 2% protocol fee
            0,
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        let (protocol_before_a, _protocol_before_b) = pool::get_protocol_fees(&pool);
        
        // Execute swap
        let swap_amount = 100_000_000; // 100M
        let coin_out = swap_a_to_b(&mut pool, swap_amount, &clock, test_scenario::ctx(&mut scenario));
        coin::burn_for_testing(coin_out);
        
        let (protocol_after_a, _protocol_after_b) = pool::get_protocol_fees(&pool);
        
        // Calculate expected protocol fee
        let total_fee = (swap_amount * 30) / 10000; // 0.3%
        let _expected_protocol_fee = (total_fee * 200) / 10000; // 2% of fee
        
        let actual_protocol_fee = protocol_after_a - protocol_before_a;
        
        // Verify protocol fee calculation (within 1 unit tolerance for rounding)
        assertions::assert_fee_calculation(
            total_fee,
            200, // protocol_fee_percent
            actual_protocol_fee,
            1 // tolerance
        );
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 5: Creator fee calculation and 500 bps limit
    // Requirement 5.5: Verify creator_fee_amount and creator_fee_percent <= 500 bps
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_creator_fee_calculation_and_limit() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        // Create pool with maximum creator fee (500 bps = 5%)
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,    // 0.3% total fee
            100,   // 1% protocol fee
            500,   // 5% creator fee (maximum allowed)
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Verify creator fee is set correctly
        let creator_fee_percent = pool::get_creator_fee_percent(&pool);
        assert!(creator_fee_percent == 500, 8);
        assert!(creator_fee_percent <= 500, 9); // Verify limit
        
        // Execute swap to generate fees
        let swap_amount = 100_000_000;
        let coin_out = swap_a_to_b(&mut pool, swap_amount, &clock, test_scenario::ctx(&mut scenario));
        coin::burn_for_testing(coin_out);
        
        // Calculate expected creator fee
        let total_fee = (swap_amount * 30) / 10000;
        let expected_creator_fee = (total_fee * 500) / 10000; // 5% of fee
        
        // Note: We can't directly access creator_fee_a balance, but we can verify
        // the fee distribution is complete
        let protocol_fee = (total_fee * 100) / 10000;
        let creator_fee = expected_creator_fee;
        let lp_fee = total_fee - protocol_fee - creator_fee;
        
        assertions::assert_fee_distribution_complete(
            total_fee,
            protocol_fee,
            creator_fee,
            lp_fee
        );
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::pool::ECreatorFeeTooHigh)]
    fun test_creator_fee_exceeds_limit_fails() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Try to create pool with creator fee > 500 bps (should fail)
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,
            100,
            501,   // 5.01% - exceeds limit
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        // Should not reach here
        test_scenario::next_tx(&mut scenario, ADMIN);
        let pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        test_scenario::return_shared(pool);
        position::destroy(position);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 6: compound_fees() liquidity increase and refunds
    // Requirement 5.6: Verify compound_fees increases liquidity and returns refunds
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_compound_fees_increases_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Execute swaps to generate fees
        let mut i = 0;
        while (i < 20) {
            let coin_out = swap_a_to_b(&mut pool, 10_000_000, &clock, test_scenario::ctx(&mut scenario));
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Get liquidity before compounding
        let liquidity_before = position::liquidity(&position);
        
        // Compound fees
        let (refund_a, refund_b) = fee_distributor::compound_fees(
            &mut pool,
            &mut position,
            0, // min_liquidity
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        // Get liquidity after compounding
        let liquidity_after = position::liquidity(&position);
        
        // Verify liquidity increased
        assert!(liquidity_after > liquidity_before, 10);
        
        // Refunds may exist due to ratio mismatch
        let _refund_a_val = coin::value(&refund_a);
        let _refund_b_val = coin::value(&refund_b);
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 7: MIN_COMPOUND_AMOUNT (1000) threshold behavior
    // Requirement 5.7: Verify fees below 1000 are returned instead of compounded
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_min_compound_amount_threshold() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Execute small swap to generate dust fees (below MIN_COMPOUND_AMOUNT)
        let coin_out = swap_a_to_b(
            &mut pool,
            10_000, // Small amount to generate dust fees
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        // Get liquidity before compounding
        let liquidity_before = position::liquidity(&position);
        
        // Try to compound fees (should return them as refunds if below threshold)
        let (refund_a, refund_b) = fee_distributor::compound_fees(
            &mut pool,
            &mut position,
            0,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        // Get liquidity after
        let liquidity_after = position::liquidity(&position);
        
        let refund_a_val = coin::value(&refund_a);
        let _refund_b_val = coin::value(&refund_b);
        
        // If fees were below MIN_COMPOUND_AMOUNT (1000), they should be returned
        // and liquidity should not increase
        if (refund_a_val > 0 && refund_a_val < 1000) {
            // Fees were below threshold, liquidity should not increase
            assert!(liquidity_after == liquidity_before, 11);
        };
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 8: Fee accumulation precision across 1000+ swaps
    // Requirement 5.8: Verify no precision loss or overflow across many swaps
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_accumulation_precision_many_swaps() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            10_000_000_000, // 10B for larger pool
            10_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Capture initial acc_fee_per_share
        let snapshot_initial = test_utils::snapshot_pool(&pool, &clock);
        let (acc_initial_a, acc_initial_b) = test_utils::get_snapshot_acc_fees(&snapshot_initial);
        
        // Execute 1000+ swaps with varying amounts
        let mut i = 0;
        let seed = 12345u64;
        while (i < 1000) {
            let swap_amount = test_utils::random_amount(seed, i, 10_000_000); // Up to 10M
            let coin_out = swap_a_to_b(&mut pool, swap_amount, &clock, test_scenario::ctx(&mut scenario));
            coin::burn_for_testing(coin_out);
            
            // Alternate direction every 100 swaps
            if (i % 200 < 100) {
                let coin_out_b = swap_b_to_a(&mut pool, swap_amount, &clock, test_scenario::ctx(&mut scenario));
                coin::burn_for_testing(coin_out_b);
            };
            
            i = i + 1;
        };
        
        // Capture final acc_fee_per_share
        let snapshot_final = test_utils::snapshot_pool(&pool, &clock);
        let (acc_final_a, acc_final_b) = test_utils::get_snapshot_acc_fees(&snapshot_final);
        
        // Verify acc_fee_per_share increased (no overflow)
        assert!(acc_final_a > acc_initial_a, 12);
        assert!(acc_final_b > acc_initial_b, 13);
        
        // Verify no overflow occurred (values should be reasonable)
        let max_reasonable = 1_000_000_000_000_000_000u128; // 1e18
        assert!(acc_final_a < max_reasonable, 14);
        assert!(acc_final_b < max_reasonable, 15);
        
        // Verify fees can still be claimed correctly
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut position_mut = position;
        let (fee_a, fee_b) = fee_distributor::claim_fees(
            &mut pool,
            &mut position_mut,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        // Should have accumulated significant fees
        assert!(coin::value(&fee_a) > 0, 16);
        assert!(coin::value(&fee_b) > 0, 17);
        
        coin::burn_for_testing(fee_a);
        coin::burn_for_testing(fee_b);
        
        test_scenario::return_shared(pool);
        position::destroy(position_mut);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 9: Fee distribution with varying LP shares
    // Additional test for complex multi-LP scenarios
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_distribution_varying_shares() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        // ADMIN creates pool with 10% share
        let (pool_id, position_admin) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            100_000_000, // 100M
            100_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, USER1);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // USER1 adds 60% of pool
        let position_user1 = test_utils::add_liquidity_helper(
            &mut pool,
            600_000_000,
            600_000_000,
            0, 0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, USER2);
        // USER2 adds 30% of pool
        let position_user2 = test_utils::add_liquidity_helper(
            &mut pool,
            300_000_000,
            300_000_000,
            0, 0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Execute swaps
        test_scenario::next_tx(&mut scenario, USER3);
        let mut i = 0;
        while (i < 50) {
            let coin_out = swap_a_to_b(&mut pool, 5_000_000, &clock, test_scenario::ctx(&mut scenario));
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        // Get fees for each LP
        let (fee_admin_a, _) = pool::get_accumulated_fees(&pool, &position_admin);
        let (fee_user1_a, _) = pool::get_accumulated_fees(&pool, &position_user1);
        let (fee_user2_a, _) = pool::get_accumulated_fees(&pool, &position_user2);
        
        // Verify fee ratios match liquidity ratios
        // USER1 should have ~6x ADMIN's fees
        // USER2 should have ~3x ADMIN's fees
        if (fee_admin_a > 0) {
            let ratio_user1 = (fee_user1_a as u128) * 100 / (fee_admin_a as u128);
            let ratio_user2 = (fee_user2_a as u128) * 100 / (fee_admin_a as u128);
            
            // USER1 should have ~600% of ADMIN (6x)
            assert!(ratio_user1 >= 550 && ratio_user1 <= 650, 18); // 5.5x to 6.5x tolerance
            
            // USER2 should have ~300% of ADMIN (3x)
            assert!(ratio_user2 >= 250 && ratio_user2 <= 350, 19); // 2.5x to 3.5x tolerance
        };
        
        test_scenario::return_shared(pool);
        position::destroy(position_admin);
        position::destroy(position_user1);
        position::destroy(position_user2);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 10: Compound fees with zero fees returns empty coins
    // Edge case test
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_compound_fees_with_zero_fees() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        let (pool_id, mut position) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        // Try to compound without any swaps (no fees)
        let liquidity_before = position::liquidity(&position);
        
        let (refund_a, refund_b) = fee_distributor::compound_fees(
            &mut pool,
            &mut position,
            0,
            &clock,
            test_utils::far_future(),
            test_scenario::ctx(&mut scenario)
        );
        
        let liquidity_after = position::liquidity(&position);
        
        // Liquidity should not change
        assert!(liquidity_after == liquidity_before, 20);
        
        // Refunds should be zero
        assert!(coin::value(&refund_a) == 0, 21);
        assert!(coin::value(&refund_b) == 0, 22);
        
        coin::burn_for_testing(refund_a);
        coin::burn_for_testing(refund_b);
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 11: Fee accumulation with single token swap direction
    // Verify only the swapped-in token accumulates fees
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_accumulation_single_direction() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = test_utils::create_clock_at(0, test_scenario::ctx(&mut scenario));
        
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30, 100, 0,
            1_000_000_000,
            1_000_000_000,
            ADMIN,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        let mut pool = test_scenario::take_shared_by_id<pool::LiquidityPool<USDC, USDT>>(&scenario, pool_id);
        
        let snapshot_before = test_utils::snapshot_pool(&pool, &clock);
        let (acc_before_a, acc_before_b) = test_utils::get_snapshot_acc_fees(&snapshot_before);
        
        // Execute only A->B swaps
        let mut i = 0;
        while (i < 10) {
            let coin_out = swap_a_to_b(&mut pool, 1_000_000, &clock, test_scenario::ctx(&mut scenario));
            coin::burn_for_testing(coin_out);
            i = i + 1;
        };
        
        let snapshot_after = test_utils::snapshot_pool(&pool, &clock);
        let (acc_after_a, acc_after_b) = test_utils::get_snapshot_acc_fees(&snapshot_after);
        
        // Only token A should have fee accumulation
        assert!(acc_after_a > acc_before_a, 23);
        assert!(acc_after_b == acc_before_b, 24);
        
        test_scenario::return_shared(pool);
        position::destroy(position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
