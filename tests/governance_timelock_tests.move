#[test_only]
module sui_amm::governance_timelock_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::object::{Self};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::admin::{Self, AdminCap};
    use sui_amm::governance::{Self, GovernanceConfig};

    struct USDT has drop {}
    struct USDC has drop {}

    const ADMIN: address = @0x1;
    #[allow(unused_const)]
    const ALICE: address = @0x2; // Reserved for future tests

    #[test]
    #[expected_failure(abort_code = sui_amm::governance::EProposalNotReady)]
    fun test_proposal_cannot_execute_before_timelock() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 10, 5, ts::ctx(scenario));
            pool::share(pool);
            admin::test_init(ts::ctx(scenario));
            governance::test_init(ts::ctx(scenario));
        };

        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let cap = ts::take_from_sender<AdminCap>(scenario);
            let config = ts::take_shared<GovernanceConfig>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let proposal_id = governance::propose_fee_change(
                &cap,
                &mut config,
                object::id(pool),
                200,
                &clock,
                ts::ctx(scenario)
            );
            
            // Advance clock only 1 hour (timelock is 48h)
            clock::increment_for_testing(&mut clock, 3_600_000);
            
            // Should fail
            governance::execute_fee_change_regular(
                &mut config,
                proposal_id,
                pool,
                &clock,
                ts::ctx(scenario)
            );
            
            clock::destroy_for_testing(clock);
            ts::return_shared(config);
            ts::return_to_sender(scenario, cap);
            ts::return_shared(pool_val);
        };
        ts::end(scenario_val);
    }

    #[test]
    fun test_proposal_executes_after_timelock() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 10, 5, ts::ctx(scenario));
            pool::share(pool);
            admin::test_init(ts::ctx(scenario));
            governance::test_init(ts::ctx(scenario));
        };

        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let cap = ts::take_from_sender<AdminCap>(scenario);
            let config = ts::take_shared<GovernanceConfig>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let proposal_id = governance::propose_fee_change(
                &cap,
                &mut config,
                object::id(pool),
                200,
                &clock,
                ts::ctx(scenario)
            );
            
            // Advance clock 48h + 1ms
            clock::increment_for_testing(&mut clock, 172_800_001);
            
            governance::execute_fee_change_regular(
                &mut config,
                proposal_id,
                pool,
                &clock,
                ts::ctx(scenario)
            );
            
            assert!(pool::get_protocol_fee_percent(pool) == 200, 0);
            
            clock::destroy_for_testing(clock);
            ts::return_shared(config);
            ts::return_to_sender(scenario, cap);
            ts::return_shared(pool_val);
        };
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::governance::EProposalExpired)]
    fun test_proposal_expires_after_7_days() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 10, 5, ts::ctx(scenario));
            pool::share(pool);
            admin::test_init(ts::ctx(scenario));
            governance::test_init(ts::ctx(scenario));
        };

        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let cap = ts::take_from_sender<AdminCap>(scenario);
            let config = ts::take_shared<GovernanceConfig>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let proposal_id = governance::propose_fee_change(
                &cap,
                &mut config,
                object::id(pool),
                200,
                &clock,
                ts::ctx(scenario)
            );
            
            // Advance clock 7 days + 48h + 1ms (expired)
            // Expiry is execution_time + 7 days
            // execution_time is now + 48h
            // So expiry is now + 48h + 7 days
            // Let's advance by 48h + 7 days + 1ms
            clock::increment_for_testing(&mut clock, 172_800_000 + 604_800_000 + 1);
            
            governance::execute_fee_change_regular(
                &mut config,
                proposal_id,
                pool,
                &clock,
                ts::ctx(scenario)
            );
            
            clock::destroy_for_testing(clock);
            ts::return_shared(config);
            ts::return_to_sender(scenario, cap);
            ts::return_shared(pool_val);
        };
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::governance::EProposalAlreadyExecuted)]
    fun test_cancelled_proposal_cannot_execute() {
        let scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        ts::next_tx(scenario, ADMIN);
        {
            let pool = pool::create_pool_for_testing<USDT, USDC>(30, 10, 5, ts::ctx(scenario));
            pool::share(pool);
            admin::test_init(ts::ctx(scenario));
            governance::test_init(ts::ctx(scenario));
        };

        ts::next_tx(scenario, ADMIN);
        {
            let pool_val = ts::take_shared<LiquidityPool<USDT, USDC>>(scenario);
            let pool = &mut pool_val;
            let cap = ts::take_from_sender<AdminCap>(scenario);
            let config = ts::take_shared<GovernanceConfig>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            
            let proposal_id = governance::propose_fee_change(
                &cap,
                &mut config,
                object::id(pool),
                200,
                &clock,
                ts::ctx(scenario)
            );
            
            // Cancel proposal
            governance::cancel_proposal(&cap, &mut config, proposal_id, ts::ctx(scenario));
            
            // Advance clock past timelock
            clock::increment_for_testing(&mut clock, 172_800_001);
            
            // Should fail
            governance::execute_fee_change_regular(
                &mut config,
                proposal_id,
                pool,
                &clock,
                ts::ctx(scenario)
            );
            
            clock::destroy_for_testing(clock);
            ts::return_shared(config);
            ts::return_to_sender(scenario, cap);
            ts::return_shared(pool_val);
        };
        ts::end(scenario_val);
    }
}
