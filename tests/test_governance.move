#[test_only]
module sui_amm::test_governance {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    
    use sui_amm::governance::{Self, GovernanceConfig};
    use sui_amm::admin::{Self, AdminCap};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::position::{LPPosition};
    use sui_amm::test_utils::{Self, USDC, USDT};
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Proposal Creation with Correct Executable Timestamp
    // Requirement 7.1: executable_at = created_at + timelock_duration_ms (48 hours)
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_proposal_creation_timestamp() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create clock at specific time
        let start_time = 1_000_000_000u64;
        let clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create a dummy pool ID for the proposal
        let pool_id = object::id_from_address(@0x1234);
        
        // Create fee change proposal
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            200, // new_fee_percent
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Get proposal status
        let (_, _, _, executable_at, created_at) = governance::get_proposal_status(&config, proposal_id);
        
        // Verify timestamps
        assert!(created_at == start_time, 0);
        
        // Timelock duration is 48 hours = 172,800,000 ms
        let expected_executable_at = start_time + 172_800_000;
        assert!(executable_at == expected_executable_at, 1);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Proposal Execution Abort Before Timelock
    // Requirement 7.2: EProposalNotReady when executed before timelock expires
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = governance::EProposalNotReady)]
    fun test_execution_before_timelock() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create pool
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,  // fee_bps
            100, // protocol_fee_bps
            0,   // creator_fee_bps
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<LiquidityPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create proposal
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            200,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Try to execute immediately (before timelock)
        test_utils::advance_clock(&mut clock, 1_000_000); // Advance only 1000 seconds (not 48 hours)
        
        governance::execute_fee_change_regular<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Proposal Execution Abort After Expiry
    // Requirement 7.3: EProposalExpired when executed after 7 days
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = governance::EProposalExpired)]
    fun test_execution_after_expiry() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create pool
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,
            100,
            0,
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<LiquidityPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create proposal
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            200,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Advance past timelock (48 hours) + expiry (7 days)
        let timelock = 172_800_000u64; // 48 hours
        let expiry = 604_800_000u64;   // 7 days
        test_utils::advance_clock(&mut clock, timelock + expiry + 1000);
        
        // Try to execute after expiry
        governance::execute_fee_change_regular<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Fee Change Proposal Execution
    // Requirement 7.4: Fee change proposal executes correctly
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_change_execution() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create pool
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,
            100, // Initial protocol fee
            0,
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<LiquidityPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create fee change proposal
        let new_protocol_fee = 200u64;
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            new_protocol_fee,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Advance past timelock (48 hours)
        test_utils::advance_clock(&mut clock, 172_800_000);
        
        // Execute proposal
        governance::execute_fee_change_regular<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify fee was changed
        let current_protocol_fee = pool::get_protocol_fee_percent(&pool);
        assert!(current_protocol_fee == new_protocol_fee, 0);
        
        // Verify proposal is marked as executed
        let (_, executed, _, _, _) = governance::get_proposal_status(&config, proposal_id);
        assert!(executed, 1);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Parameter Change Proposal Execution
    // Requirement 7.5: Parameter change proposal executes correctly
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_parameter_change_execution() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create pool
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,
            100,
            0,
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<LiquidityPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create parameter change proposal
        let new_ratio_tolerance = 500u64;
        let new_max_price_impact = 2000u64;
        let proposal_id = governance::propose_parameter_change(
            &admin_cap,
            &mut config,
            pool_id,
            new_ratio_tolerance,
            new_max_price_impact,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Advance past timelock
        test_utils::advance_clock(&mut clock, 172_800_000);
        
        // Execute proposal
        governance::execute_parameter_change_regular<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify parameters were changed
        let (ratio_tolerance, max_price_impact) = pool::get_risk_params(&pool);
        assert!(ratio_tolerance == new_ratio_tolerance, 0);
        assert!(max_price_impact == new_max_price_impact, 1);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Pause Proposal Execution and Operation Blocking
    // Requirement 7.6: Pause proposal executes and blocks operations
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_pause_execution() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create pool
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,
            100,
            0,
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<LiquidityPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Verify pool is not paused initially
        assert!(!pool::is_paused(&pool), 0);
        
        // Create pause proposal
        let proposal_id = governance::propose_pause(
            &admin_cap,
            &mut config,
            pool_id,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Advance past timelock
        test_utils::advance_clock(&mut clock, 172_800_000);
        
        // Execute pause proposal
        governance::execute_pause_regular<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify pool is now paused
        assert!(pool::is_paused(&pool), 1);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Proposal Cancellation
    // Requirement 7.7: Cancelled proposals cannot be executed
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = governance::EProposalAlreadyExecuted)]
    fun test_proposal_cancellation() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create pool
        let (pool_id, position) = test_utils::create_initialized_pool<USDC, USDT>(
            30,
            100,
            0,
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<LiquidityPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create proposal
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            200,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Cancel proposal
        governance::cancel_proposal(
            &admin_cap,
            &mut config,
            proposal_id,
            ts::ctx(&mut scenario)
        );
        
        // Verify proposal is cancelled
        let (_, _, cancelled, _, _) = governance::get_proposal_status(&config, proposal_id);
        assert!(cancelled, 0);
        
        // Advance past timelock
        test_utils::advance_clock(&mut clock, 172_800_000);
        
        // Try to execute cancelled proposal (should fail)
        governance::execute_fee_change_regular<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Should not reach here
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: AdminCap Requirement for Governance Functions
    // Requirement 7.8: All governance functions require AdminCap
    // Note: This is enforced at compile time by the type system, but we test
    // that proposals can only be created/executed with AdminCap
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_admin_cap_requirement() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        let pool_id = object::id_from_address(@0x1234);
        let clock = test_utils::create_clock_at(1_000_000_000, ts::ctx(&mut scenario));
        
        // Verify we can create proposal with AdminCap
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            200,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify proposal was created
        assert!(governance::proposal_exists(&config, proposal_id), 0);
        
        // Verify we can cancel with AdminCap
        governance::cancel_proposal(
            &admin_cap,
            &mut config,
            proposal_id,
            ts::ctx(&mut scenario)
        );
        
        // Verify proposal was cancelled
        let (_, _, cancelled, _, _) = governance::get_proposal_status(&config, proposal_id);
        assert!(cancelled, 1);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Stable Pool Fee Change
    // Additional test for stable pool governance
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_stable_pool_fee_change() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create stable pool
        let (pool_id, position) = test_utils::create_initialized_stable_pool<USDC, USDT>(
            200, // amp
            5,   // fee_bps
            100, // protocol_fee_bps
            0,   // creator_fee_bps
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<StableSwapPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create fee change proposal
        let new_protocol_fee = 150u64;
        let proposal_id = governance::propose_fee_change(
            &admin_cap,
            &mut config,
            pool_id,
            new_protocol_fee,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Advance past timelock
        test_utils::advance_clock(&mut clock, 172_800_000);
        
        // Execute proposal
        governance::execute_fee_change_stable<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify fee was changed
        let current_protocol_fee = stable_pool::get_protocol_fee_percent(&pool);
        assert!(current_protocol_fee == new_protocol_fee, 0);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Stable Pool Parameter Change
    // Additional test for stable pool governance
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_stable_pool_parameter_change() {
        let admin = fixtures::admin();
        let mut scenario = ts::begin(admin);
        
        governance::test_init(ts::ctx(&mut scenario));
        admin::test_init(ts::ctx(&mut scenario));
        
        ts::next_tx(&mut scenario, admin);
        
        let mut config = ts::take_shared<GovernanceConfig>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        
        // Create stable pool
        let (pool_id, position) = test_utils::create_initialized_stable_pool<USDC, USDT>(
            100, // amp
            5,   // fee_bps
            100, // protocol_fee_bps
            0,   // creator_fee_bps
            1_000_000_000,
            1_000_000_000,
            admin,
            ts::ctx(&mut scenario)
        );
        
        transfer::public_transfer<LPPosition>(position, admin);
        
        ts::next_tx(&mut scenario, admin);
        
        let mut pool = ts::take_shared<StableSwapPool<USDC, USDT>>(&scenario);
        
        let start_time = 1_000_000_000u64;
        let mut clock = test_utils::create_clock_at(start_time, ts::ctx(&mut scenario));
        
        // Create parameter change proposal (stable pools only have max_price_impact)
        let new_max_price_impact = 1500u64;
        let proposal_id = governance::propose_parameter_change(
            &admin_cap,
            &mut config,
            pool_id,
            0, // ratio_tolerance not used for stable pools
            new_max_price_impact,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Advance past timelock
        test_utils::advance_clock(&mut clock, 172_800_000);
        
        // Execute proposal
        governance::execute_parameter_change_stable<USDC, USDT>(
            &admin_cap,
            &mut config,
            proposal_id,
            &mut pool,
            &clock,
            ts::ctx(&mut scenario)
        );
        
        // Verify parameter was changed
        let current_max_price_impact = stable_pool::get_max_price_impact_bps(&pool);
        assert!(current_max_price_impact == new_max_price_impact, 0);
        
        // Clean up
        ts::return_to_sender(&scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::return_shared(pool);
        ts::return_shared(config);
        ts::end(scenario);
    }
}
