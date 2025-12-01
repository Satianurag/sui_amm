/// Tests for governance module
#[test_only]
module sui_amm::governance_tests {
    use sui::test_scenario::{Self};
    use sui::clock::{Self};
    use sui::object;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::governance::{Self, GovernanceConfig};
    use sui_amm::admin::{Self, AdminCap};

    struct BTC has drop {}
    public struct USDC has drop {}

    #[test]
    fun test_propose_fee_change() {
        let admin_addr = @0xA;
        let scenario_val = test_scenario::begin(admin_addr);
        let scenario = &mut scenario_val;
        
        // Initialize
        test_scenario::next_tx(scenario, admin_addr);
        {
            let ctx = test_scenario::ctx(scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        // Create proposal
        test_scenario::next_tx(scenario, admin_addr);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let config_val = test_scenario::take_shared<GovernanceConfig>(scenario);
            let config = &mut config_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            
            // Propose fee change to 200 bps (2%)
            let proposal_id = governance::propose_fee_change(
                &admin_cap,
                config,
                pool_id,
                200,
                &clock,
                ctx
            );

            // Proposal should exist but not be executable yet
            // (timelock is 48 hours)
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(config_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = governance::EProposalNotReady)]
    fun test_execute_before_timelock() {
        let admin_addr = @0xA;
        let scenario_val = test_scenario::begin(admin_addr);
        let scenario = &mut scenario_val;
        
        // Initialize
        test_scenario::next_tx(scenario, admin_addr);
        {
            let ctx = test_scenario::ctx(scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        // Create and try to execute immediately
        test_scenario::next_tx(scenario, admin_addr);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let config_val = test_scenario::take_shared<GovernanceConfig>(scenario);
            let config = &mut config_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            
            let proposal_id = governance::propose_fee_change(
                &admin_cap,
                config,
                pool_id,
                200,
                &clock,
                ctx
            );

            // Try to execute immediately - should fail (timelock not passed)
            governance::execute_fee_change_regular(
                config,
                proposal_id,
                pool,
                &clock,
                ctx
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(config_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_execute_after_timelock() {
        let admin_addr = @0xA;
        let scenario_val = test_scenario::begin(admin_addr);
        let scenario = &mut scenario_val;
        
        // Initialize
        test_scenario::next_tx(scenario, admin_addr);
        {
            let ctx = test_scenario::ctx(scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        // Create proposal
        let proposal_id;
        test_scenario::next_tx(scenario, admin_addr);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let config_val = test_scenario::take_shared<GovernanceConfig>(scenario);
            let config = &mut config_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            
            proposal_id = governance::propose_fee_change(
                &admin_cap,
                config,
                pool_id,
                200,
                &clock,
                ctx
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(config_val);
        };

        // Execute after timelock (48 hours = 172_800_000 ms)
        test_scenario::next_tx(scenario, admin_addr);
        {
            let config_val = test_scenario::take_shared<GovernanceConfig>(scenario);
            let config = &mut config_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            // Advance clock past timelock
            clock::set_for_testing(&mut clock, 172_800_001);

            governance::execute_fee_change_regular(
                config,
                proposal_id,
                pool,
                &clock,
                ctx
            );

            // Verify fee was changed
            let new_fee = pool::get_protocol_fee_percent(pool);
            assert!(new_fee == 200, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(config_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_cancel_proposal() {
        let admin_addr = @0xA;
        let scenario_val = test_scenario::begin(admin_addr);
        let scenario = &mut scenario_val;
        
        // Initialize
        test_scenario::next_tx(scenario, admin_addr);
        {
            let ctx = test_scenario::ctx(scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        // Create and cancel proposal
        test_scenario::next_tx(scenario, admin_addr);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let config_val = test_scenario::take_shared<GovernanceConfig>(scenario);
            let config = &mut config_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            
            let proposal_id = governance::propose_fee_change(
                &admin_cap,
                config,
                pool_id,
                200,
                &clock,
                ctx
            );

            // Cancel the proposal
            governance::cancel_proposal(
                &admin_cap,
                config,
                proposal_id,
                ctx
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(config_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = governance::EInvalidFee)]
    fun test_propose_invalid_fee() {
        let admin_addr = @0xA;
        let scenario_val = test_scenario::begin(admin_addr);
        let scenario = &mut scenario_val;
        
        // Initialize
        test_scenario::next_tx(scenario, admin_addr);
        {
            let ctx = test_scenario::ctx(scenario);
            admin::test_init(ctx);
            governance::test_init(ctx);
            let pool = pool::create_pool_for_testing<BTC, USDC>(30, 100, 0, ctx);
            pool::share(pool);
        };

        // Try to propose fee > 10% (1000 bps)
        test_scenario::next_tx(scenario, admin_addr);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let config_val = test_scenario::take_shared<GovernanceConfig>(scenario);
            let config = &mut config_val;
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let pool_id = object::id(pool);
            
            // 1500 bps = 15% - should fail
            let _proposal_id = governance::propose_fee_change(
                &admin_cap,
                config,
                pool_id,
                1500,
                &clock,
                ctx
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(pool_val);
            test_scenario::return_shared(config_val);
        };

        test_scenario::end(scenario_val);
    }
}
