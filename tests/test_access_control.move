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

    /// Tests that verify admin capability (AdminCap) is required for privileged
    /// operations, ensuring only authorized administrators can perform sensitive actions.

    /// Verifies that an admin with AdminCap can successfully withdraw accumulated
    /// protocol fees from a pool. This ensures the fee collection mechanism works
    /// correctly for authorized administrators.
    #[test]
    fun test_admin_can_withdraw_protocol_fees() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
        };
        
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
        
        // Admin exercises their privilege to withdraw accumulated protocol fees
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            
            let (fee_a, fee_b) = admin::withdraw_protocol_fees_from_pool(
                &admin_cap,
                pool,
                ctx
            );
            
            // Verify that protocol fees were successfully withdrawn
            assert!(coin::value(&fee_a) > 0, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Verifies that an admin with AdminCap can pause a pool, activating the
    /// emergency stop mechanism. This is critical for responding to security
    /// incidents or critical bugs.
    #[test]
    fun test_admin_can_pause_pool() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
        };
        
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
        
        // Admin activates the emergency pause mechanism
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            admin::pause_pool(&admin_cap, pool, &clock);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Tests that verify governance operations require AdminCap, ensuring only
    /// authorized administrators can create and manage governance proposals.

    /// Verifies that an admin with AdminCap can create governance proposals.
    /// This ensures the governance system is properly gated and only authorized
    /// parties can initiate protocol changes.
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
        
        // Admin creates a governance proposal to change protocol fees
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
                20,
                &clock,
                ctx
            );
            
            // Verify the proposal was successfully created
            assert!(object::id_to_address(&proposal_id) != @0x0, 0);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(gov_config_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Verifies that an admin with AdminCap can cancel governance proposals.
    /// This provides a safety mechanism to halt proposals that may be harmful
    /// or were created in error.
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
        
        // Admin creates a proposal, then immediately cancels it
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
                20,
                &clock,
                ctx
            );
            
            // Admin exercises their authority to cancel the proposal
            governance::cancel_proposal(&admin_cap, gov_config, proposal_id, ctx);
            
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(gov_config_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Tests that verify position ownership is properly enforced, ensuring only
    /// the owner of an LP position can perform operations on it.

    /// Verifies that the owner of an LP position can remove liquidity from it.
    /// Position ownership is enforced through Sui's object ownership model,
    /// ensuring only the holder can perform operations.
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
        
        // Owner exercises their right to remove liquidity from their position
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
            
            // Verify tokens were successfully returned to the owner
            assert!(coin::value(&coin_a) > 0, 0);
            assert!(coin::value(&coin_b) > 0, 1);
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Verifies that the owner of an LP position can claim accumulated trading fees.
    /// Fee claims are proportional to the position's share of the pool and are
    /// tracked through the fee debt mechanism.
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
        
        // Owner claims their accumulated trading fees
        ts::next_tx(&mut scenario, owner);
        {
            let mut position_val = ts::take_from_sender<LPPosition>(&scenario);
            let position = &mut position_val;
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = pool::withdraw_fees(pool, position, &clock, fixtures::far_future_deadline(), ctx);
            
            // Verify fees were successfully claimed
            assert!(coin::value(&fee_a) > 0, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, position_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Verifies that when a position is transferred to a new owner, the new owner
    /// gains full control and can perform all position operations. This tests that
    /// ownership transfer works correctly in Sui's object model.
    #[test]
    fun test_transferred_position_new_owner_can_operate() {
        let original_owner = @0xA;
        let new_owner = @0xB;
        let mut scenario = ts::begin(original_owner);
        
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
            
            // Transfer ownership of the position to the new owner
            transfer::public_transfer(position, new_owner);
            pool::share(pool);
            clock::destroy_for_testing(clock);
        };
        
        // New owner can now operate on the transferred position
        ts::next_tx(&mut scenario, new_owner);
        {
            let mut position_val = ts::take_from_sender<LPPosition>(&scenario);
            let position = &mut position_val;
            let mut pool_val = ts::take_shared<LiquidityPool<USDC, BTC>>(&scenario);
            let pool = &mut pool_val;
            let ctx = ts::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            
            let (fee_a, fee_b) = pool::withdraw_fees(pool, position, &clock, fixtures::far_future_deadline(), ctx);
            
            // Verify the new owner successfully claimed the fees
            assert!(coin::value(&fee_a) > 0, 0);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            clock::destroy_for_testing(clock);
            ts::return_to_sender(&scenario, position_val);
            ts::return_shared(pool_val);
        };
        
        ts::end(scenario);
    }

    /// Tests that verify factory operations require AdminCap, ensuring only
    /// authorized administrators can modify factory configuration.

    /// Verifies that an admin with AdminCap can add new fee tiers to the factory.
    /// Fee tiers determine the trading fee percentage for pools and must be
    /// managed by authorized administrators.
    #[test]
    fun test_admin_can_add_fee_tier() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
            factory::test_init(ctx);
        };
        
        // Admin adds a new fee tier to the registry
        ts::next_tx(&mut scenario, admin);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            let mut registry_val = ts::take_shared<PoolRegistry>(&scenario);
            let registry = &mut registry_val;
            
            factory::add_fee_tier(&admin_cap, registry, 50);
            
            // Verify the new fee tier is now valid
            assert!(factory::is_valid_fee_tier(registry, 50), 0);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry_val);
        };
        
        ts::end(scenario);
    }

    /// Verifies that an admin with AdminCap can set the pool creation fee.
    /// This fee acts as a spam prevention mechanism and must be managed by
    /// authorized administrators to balance accessibility and security.
    #[test]
    fun test_admin_can_set_pool_creation_fee() {
        let admin = @0xA;
        let mut scenario = ts::begin(admin);
        
        ts::next_tx(&mut scenario, admin);
        {
            let ctx = ts::ctx(&mut scenario);
            admin::test_init(ctx);
            factory::test_init(ctx);
        };
        
        // Admin updates the pool creation fee
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
