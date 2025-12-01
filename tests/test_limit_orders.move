#[test_only]
module sui_amm::test_limit_orders {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self};
    use sui_amm::limit_orders::{Self, OrderRegistry, LimitOrder};
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Limit Order Execution When Target Price Met
    // Requirements: 9.4 - Test limit order execution when target_price is met
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_limit_order_execution_price_met() {
        let admin = fixtures::admin();
        let trader = fixtures::user1();
        let executor = fixtures::user2();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize limit order registry
        limit_orders::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Create pool with balanced liquidity
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::balanced_large_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, trader);
        
        // Get pool and registry
        let pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        
        // Get current price (reserve_a / reserve_b)
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128)) as u64;
        
        // Create limit order with target price slightly above current (favorable for trader)
        let order_amount = 10_000_000u64;
        let target_price = current_price + (current_price / 10); // 10% above current
        let min_amount_out = 9_000_000u64;
        let expiry = clock::timestamp_ms(&clock) + fixtures::hour();
        
        let coin_in = test_utils::mint_coin<BTC>(order_amount, test_scenario::ctx(&mut scenario));
        
        let order_id = limit_orders::create_limit_order<BTC, USDC>(
            &mut registry,
            pool_id,
            true, // is_a_to_b
            coin_in,
            target_price,
            min_amount_out,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        // Return pool for now
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        
        // Execute some swaps to move price in favorable direction for the order
        test_scenario::next_tx(&mut scenario, admin);
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        // Swap B to A to decrease reserve_a/reserve_b ratio (make A cheaper)
        let swap_amount = 5_000_000_000u64; // Large swap to move price
        let coin_out = test_utils::swap_b_to_a_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        test_scenario::return_shared(pool);
        
        // Now executor tries to execute the order
        test_scenario::next_tx(&mut scenario, executor);
        
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        let order = test_scenario::take_shared_by_id<LimitOrder<BTC, USDC>>(&scenario, order_id);
        
        // Verify price is now favorable
        let (new_reserve_a, new_reserve_b) = pool::get_reserves(&pool);
        let new_price = ((new_reserve_a as u128) * 1_000_000_000 / (new_reserve_b as u128)) as u64;
        assert!(new_price <= target_price, 0);
        
        // Execute the order
        limit_orders::execute_limit_order_a_to_b<BTC, USDC>(
            &mut registry,
            &mut pool,
            order,
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify order was executed (trader should receive coins)
        test_scenario::next_tx(&mut scenario, trader);
        
        // Check that trader received output coins
        // In real scenario, coins would be in trader's account
        // For this test, we verify the order was removed from registry
        let trader_orders = limit_orders::get_user_orders(&registry, trader);
        assert!(vector::length(&trader_orders) == 0, 1);
        
        // Cleanup
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        position::destroy_for_testing(admin_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Limit Order Execution B to A
    // Requirements: 9.4 - Test limit order execution for B to A swaps
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_limit_order_execution_b_to_a() {
        let admin = fixtures::admin();
        let trader = fixtures::user1();
        let executor = fixtures::user2();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize limit order registry
        limit_orders::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::balanced_large_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, trader);
        
        let pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        
        // Get current price (reserve_b / reserve_a for B to A)
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let current_price = ((reserve_b as u128) * 1_000_000_000 / (reserve_a as u128)) as u64;
        
        // Create limit order B to A
        let order_amount = 10_000_000u64;
        let target_price = current_price + (current_price / 10); // 10% above current
        let min_amount_out = 9_000_000u64;
        let expiry = clock::timestamp_ms(&clock) + fixtures::hour();
        
        let coin_in = test_utils::mint_coin<USDC>(order_amount, test_scenario::ctx(&mut scenario));
        
        let order_id = limit_orders::create_limit_order<USDC, BTC>(
            &mut registry,
            pool_id,
            false, // is_a_to_b = false (B to A)
            coin_in,
            target_price,
            min_amount_out,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        
        // Execute swap to move price
        test_scenario::next_tx(&mut scenario, admin);
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        
        // Swap A to B to decrease reserve_b/reserve_a ratio
        let swap_amount = 5_000_000_000u64;
        let coin_out = test_utils::swap_a_to_b_helper(
            &mut pool,
            swap_amount,
            0,
            0,
            test_utils::far_future(),
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        coin::burn_for_testing(coin_out);
        
        test_scenario::return_shared(pool);
        
        // Execute the order
        test_scenario::next_tx(&mut scenario, executor);
        
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        let order = test_scenario::take_shared_by_id<LimitOrder<USDC, BTC>>(&scenario, order_id);
        
        limit_orders::execute_limit_order_b_to_a<BTC, USDC>(
            &mut registry,
            &mut pool,
            order,
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify order was executed
        test_scenario::next_tx(&mut scenario, trader);
        let trader_orders = limit_orders::get_user_orders(&registry, trader);
        assert!(vector::length(&trader_orders) == 0, 0);
        
        // Cleanup
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        position::destroy_for_testing(admin_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Limit Order Cancellation and Fund Return
    // Requirements: 9.5 - Test limit order cancellation and fund return
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_limit_order_cancellation() {
        let admin = fixtures::admin();
        let trader = fixtures::user1();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize limit order registry
        limit_orders::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, trader);
        
        let pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        
        // Create limit order
        let order_amount = 10_000_000u64;
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128)) as u64;
        let target_price = current_price / 2; // Price that won't be met
        let min_amount_out = 5_000_000u64;
        let expiry = clock::timestamp_ms(&clock) + fixtures::hour();
        
        let coin_in = test_utils::mint_coin<BTC>(order_amount, test_scenario::ctx(&mut scenario));
        
        let order_id = limit_orders::create_limit_order<BTC, USDC>(
            &mut registry,
            pool_id,
            true, // is_a_to_b
            coin_in,
            target_price,
            min_amount_out,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        
        // Verify order was created
        test_scenario::next_tx(&mut scenario, trader);
        let registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        let trader_orders = limit_orders::get_user_orders(&registry, trader);
        assert!(vector::length(&trader_orders) == 1, 0);
        test_scenario::return_shared(registry);
        
        // Cancel the order
        test_scenario::next_tx(&mut scenario, trader);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        let order = test_scenario::take_shared_by_id<LimitOrder<BTC, USDC>>(&scenario, order_id);
        
        let returned_coin = limit_orders::cancel_limit_order<BTC, USDC>(
            &mut registry,
            order,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify funds were returned
        assert!(coin::value(&returned_coin) == order_amount, 1);
        coin::burn_for_testing(returned_coin);
        
        // Verify order was removed from registry
        let trader_orders = limit_orders::get_user_orders(&registry, trader);
        assert!(vector::length(&trader_orders) == 0, 2);
        
        // Cleanup
        test_scenario::return_shared(registry);
        position::destroy_for_testing(admin_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Limit Order Expiry
    // Requirements: 9.4, 9.5 - Test limit order expiry handling
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = limit_orders::EOrderExpired)]
    fun test_limit_order_expiry() {
        let admin = fixtures::admin();
        let trader = fixtures::user1();
        let executor = fixtures::user2();
        
        let mut scenario = test_scenario::begin(admin);
        let mut clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize limit order registry
        limit_orders::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, trader);
        
        let pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        
        // Create limit order with short expiry
        let order_amount = 10_000_000u64;
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128)) as u64;
        let target_price = current_price * 2; // High target price (easy to meet)
        let min_amount_out = 5_000_000u64;
        let expiry = clock::timestamp_ms(&clock) + 60000; // 1 minute
        
        let coin_in = test_utils::mint_coin<BTC>(order_amount, test_scenario::ctx(&mut scenario));
        
        let order_id = limit_orders::create_limit_order<BTC, USDC>(
            &mut registry,
            pool_id,
            true,
            coin_in,
            target_price,
            min_amount_out,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        
        // Advance time past expiry
        test_utils::advance_clock(&mut clock, 120000); // 2 minutes
        
        // Try to execute expired order (should fail)
        test_scenario::next_tx(&mut scenario, executor);
        
        let mut pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        let order = test_scenario::take_shared_by_id<LimitOrder<BTC, USDC>>(&scenario, order_id);
        
        // This should abort with EOrderExpired
        limit_orders::execute_limit_order_a_to_b<BTC, USDC>(
            &mut registry,
            &mut pool,
            order,
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        
        // Cleanup (won't reach here due to expected failure)
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        position::destroy_for_testing(admin_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Multiple Limit Orders Per User
    // Requirements: 9.4 - Test multiple limit orders management
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_multiple_limit_orders() {
        let admin = fixtures::admin();
        let trader = fixtures::user1();
        
        let mut scenario = test_scenario::begin(admin);
        let clock = test_utils::create_clock_at(1000000, test_scenario::ctx(&mut scenario));
        
        // Initialize limit order registry
        limit_orders::test_init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, admin);
        
        // Create pool
        let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
        let (initial_a, initial_b) = fixtures::retail_liquidity();
        
        let (pool_id, admin_position) = test_utils::create_initialized_pool<BTC, USDC>(
            fee_bps,
            protocol_fee_bps,
            creator_fee_bps,
            initial_a,
            initial_b,
            admin,
            test_scenario::ctx(&mut scenario)
        );
        
        test_scenario::next_tx(&mut scenario, trader);
        
        let pool = test_scenario::take_shared_by_id<LiquidityPool<BTC, USDC>>(&scenario, pool_id);
        let mut registry = test_scenario::take_shared<OrderRegistry>(&scenario);
        
        let (reserve_a, reserve_b) = pool::get_reserves(&pool);
        let current_price = ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128)) as u64;
        let expiry = clock::timestamp_ms(&clock) + fixtures::hour();
        
        // Create 3 limit orders with different target prices
        let order_amount = 5_000_000u64;
        
        let coin_in1 = test_utils::mint_coin<BTC>(order_amount, test_scenario::ctx(&mut scenario));
        let _order_id1 = limit_orders::create_limit_order<BTC, USDC>(
            &mut registry,
            pool_id,
            true,
            coin_in1,
            current_price / 2,
            2_000_000,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        let coin_in2 = test_utils::mint_coin<BTC>(order_amount, test_scenario::ctx(&mut scenario));
        let _order_id2 = limit_orders::create_limit_order<BTC, USDC>(
            &mut registry,
            pool_id,
            true,
            coin_in2,
            current_price,
            4_000_000,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        let coin_in3 = test_utils::mint_coin<BTC>(order_amount, test_scenario::ctx(&mut scenario));
        let _order_id3 = limit_orders::create_limit_order<BTC, USDC>(
            &mut registry,
            pool_id,
            true,
            coin_in3,
            current_price * 2,
            8_000_000,
            &clock,
            expiry,
            test_scenario::ctx(&mut scenario)
        );
        
        // Verify all 3 orders are registered
        let trader_orders = limit_orders::get_user_orders(&registry, trader);
        assert!(vector::length(&trader_orders) == 3, 0);
        
        // Verify pool has 3 orders
        let pool_orders = limit_orders::get_pool_orders(&registry, pool_id);
        assert!(vector::length(&pool_orders) == 3, 1);
        
        // Cleanup
        test_scenario::return_shared(pool);
        test_scenario::return_shared(registry);
        position::destroy_for_testing(admin_position);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
