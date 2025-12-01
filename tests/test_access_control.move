#[test_only]
module sui_amm::test_access_control {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{LPPosition};
    use sui_amm::admin::{Self, AdminCap};
    use sui_amm::governance::{Self, GovernanceConfig};
    use sui_amm::factory::{Self, PoolRegistry};
    use sui_amm::test_utils::{Self, USDC, BTC};
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN CAP REQUIREMENT TESTS - Requirement 8.6
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_admin_can_withdraw_protocol_fees() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
        };
        
        // Create pool and generate fees
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Generate fees
            let coin_in = test_utils::mint_coin<USDC>(10_000_000, ctx);
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(coin_out);
            
            transfer::public_transfer(position, admin);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Admin withdraws protocol fees (should succeed)
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            
            let (fee_a, fee_b) = admin::withdraw_protocol_fees_from_pool(
                &admin_cap,
                pool,
                ctx
            );
            
            // Verify fees were withdrawn
            assert!(coin::value(&fee_a) > 0, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_admin_can_pause_pool() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
        };
        
        // Create pool
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            transfer::public_transfer(position, admin);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Admin pauses pool (should succeed)
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            admin::pause_pool(&admin_cap, pool, &clock);
            
            // Pool is now paused - we can't directly verify but the function succeeded
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE ACCESS CONTROL TESTS - Requirement 8.6
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_admin_can_create_governance_proposal() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap and GovernanceConfig
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
        };
        
        // Create pool
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            let pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            pool::share(pool);
        };
        
        // Admin creates proposal (should succeed)
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut gov_config_val = ts::take_shared<GovernanceConfig>(&scenario);
            let gov_config = &mut gov_config_val;
            let pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &pool_val;
            let pool_id = object::id(pool);
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let proposal_id = governance::propose_fee_change(
                &admin_cap,
                gov_config,
                pool_id,
                20, // new_protocol_fee_bps
                &clock,
                ctx
            );
            
            // Verify proposal was created
            assert!(object::id_to_address(&proposal_id) != @0x0, 0);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(gov_config_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_admin_can_cancel_proposal() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap and GovernanceConfig
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
        };
        
        // Create pool
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            let pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            pool::share(pool);
        };
        
        // Admin creates proposal
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut gov_config_val = ts::take_shared<GovernanceConfig>(&scenario);
            let gov_config = &mut gov_config_val;
            let pool_val = ts::take_from_sender<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &pool_val;
            let pool_id = object::id(pool);
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let proposal_id = governance::propose_fee_change(
                &admin_cap,
                gov_config,
                pool_id,
                20,
                &clock,
                ctx
            );
            
            // Admin cancels proposal (should succeed)
            governance::cancel_proposal(&admin_cap, gov_config, proposal_id, ctx);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(gov_config_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POSITION OWNERSHIP VERIFICATION TESTS - Requirement 8.6
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_position_owner_can_remove_liquidity() {
        let owner = @0xA;
        let mut scenario = ts::begin(owner);
        
        // Owner creates pool and adds liquidity
        ts::next_tx(&mut scenario, owner);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            transfer::public_transfer(position, owner);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Owner removes liquidity (should succeed)
        ts::next_tx(&mut scenario, owner);
        {
            let position = ts::take_from_sender<LPPosition>(&scenario);
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (coin_a, coin_b) = pool::remove_liquidity(
                pool,
                position,
                1,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            
            // Verify liquidity was removed
            assert!(coin::value(&coin_a) > 0, 0);
            assert!(coin::value(&coin_b) > 0, 1);
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_position_owner_can_claim_fees() {
        let owner = @0xA;
        let mut scenario = ts::begin(owner);
        
        // Owner creates pool and adds liquidity
        ts::next_tx(&mut scenario, owner);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Generate fees
            let coin_in = test_utils::mint_coin<USDC>(10_000_000, ctx);
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(coin_out);
            
            transfer::public_transfer(position, owner);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Owner claims fees (should succeed)
        ts::next_tx(&mut scenario, owner);
        {
            let mut position_val = ts::take_from_sender<LPPosition>(&scenario);
            let position = &mut position_val;
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = pool::withdraw_fees(pool, position, &clock, fixtures::far_future_deadline(), ctx);
            
            // Verify fees were claimed
            assert!(coin::value(&fee_a) > 0, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, position_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_transferred_position_new_owner_can_operate() {
        let original_owner = @0xA;
        let new_owner = @0xB;
        let mut scenario = ts::begin(original_owner);
        
        // Original owner creates pool and adds liquidity
        ts::next_tx(&mut scenario, original_owner);
        {
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let mut pool = pool::create_pool<USDC, BTC>(30, 100, 0, ctx);
            let coin_a = test_utils::mint_coin<USDC>(1_000_000_000, ctx);
            let coin_b = test_utils::mint_coin<BTC>(1_000_000_000, ctx);
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Generate fees
            let coin_in = test_utils::mint_coin<USDC>(10_000_000, ctx);
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                ctx
            );
            coin::burn_for_testing(coin_out);
            
            // Transfer position to new owner
            transfer::public_transfer(position, new_owner);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // Pool is already shared, no need to transfer
        
        // New owner claims fees (should succeed)
        ts::next_tx(&mut scenario, new_owner);
        {
            let mut position_val = ts::take_from_sender<LPPosition>(&scenario);
            let position = &mut position_val;
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = pool::withdraw_fees(pool, position, &clock, fixtures::far_future_deadline(), ctx);
            
            // Verify new owner can claim fees
            assert!(coin::value(&fee_a) > 0, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, position_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY ACCESS CONTROL TESTS - Requirement 8.6
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_admin_can_add_fee_tier() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap and PoolRegistry
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
            factory::test_init(ctx);
        };
        
        // Admin adds fee tier (should succeed)
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut registry_val = ts::take_shared<PoolRegistry>(&scenario);
            let registry = &mut registry_val;
            
            factory::add_fee_tier(&admin_cap, registry, 50); // Add 0.5% fee tier
            
            // Verify fee tier was added
            assert!(factory::is_valid_fee_tier(registry, 50), 0);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry_val);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_admin_can_set_pool_creation_fee() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        // Create AdminCap and PoolRegistry
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
            factory::test_init(ctx);
        };
        
        // Admin sets pool creation fee (should succeed)
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut registry_val = ts::take_shared<PoolRegistry>(&scenario);
            let registry = &mut registry_val;
            
            factory::set_pool_creation_fee(&admin_cap, registry, 2_000_000_000); // 2 SUI
            
            // Verify fee was set
            assert!(factory::get_pool_creation_fee(registry) == 2_000_000_000, 0);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry_val);
        };
        
        ts::end(scenario);
    }
}
