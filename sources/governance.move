module sui_amm::governance {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::admin::{AdminCap};
    
    // Error codes
    const EProposalNotReady: u64 = 0;
    const EProposalExpired: u64 = 1;
    const EInvalidFee: u64 = 2;
    #[allow(unused_const)]
    const EUnauthorized: u64 = 3; // Reserved for future use
    const EProposalNotFound: u64 = 4;
    const EProposalAlreadyExecuted: u64 = 5;
    const EInvalidProposalType: u64 = 6;

    // Constants
    const TIMELOCK_DURATION_MS: u64 = 172_800_000; // 48 hours (as per audit fix)
    const PROPOSAL_EXPIRY_MS: u64 = 604_800_000; // 7 days
    const MAX_PROTOCOL_FEE_BPS: u64 = 1000; // 10% hard cap

    // Proposal Types
    const TYPE_FEE_CHANGE: u8 = 1;
    const TYPE_PARAMETER_CHANGE: u8 = 2;

    struct Proposal has store, drop {
        id: ID,
        proposal_type: u8, 
        target_pool: ID,
        // For Fee Change: new_fee_bps
        // For Param Change: max_price_impact_bps (we use u64 for generic value)
        new_value: u64, 
        // Additional value for param change (ratio_tolerance)
        aux_value: u64,
        proposer: address,
        created_at: u64,
        executable_at: u64,
        executed: bool,
        cancelled: bool,
    }

    struct GovernanceConfig has key {
        id: UID,
        timelock_duration_ms: u64,
        proposals: Table<ID, Proposal>,
        proposal_count: u64,
    }

    struct ProposalCreated has copy, drop {
        proposal_id: ID,
        proposal_type: u8,
        target_pool: ID,
        new_value: u64,
        executable_at: u64,
    }

    struct ProposalExecuted has copy, drop {
        proposal_id: ID,
        executed_at: u64,
    }

    struct ProposalCancelled has copy, drop {
        proposal_id: ID,
        cancelled_by: address,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(GovernanceConfig {
            id: object::new(ctx),
            timelock_duration_ms: TIMELOCK_DURATION_MS,
            proposals: table::new(ctx),
            proposal_count: 0,
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    // --- Propose Functions ---

    /// Propose a fee change. Requires AdminCap.
    public fun propose_fee_change(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        pool_id: ID,
        new_fee_percent: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): ID {
        assert!(new_fee_percent <= MAX_PROTOCOL_FEE_BPS, EInvalidFee);
        
        create_proposal(
            config,
            TYPE_FEE_CHANGE,
            pool_id,
            new_fee_percent,
            0,
            clock,
            ctx
        )
    }

    /// Propose parameter change (risk params). Requires AdminCap.
    public fun propose_parameter_change(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        pool_id: ID,
        ratio_tolerance_bps: u64, // 0 for stable pools
        max_price_impact_bps: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): ID {
        create_proposal(
            config,
            TYPE_PARAMETER_CHANGE,
            pool_id,
            max_price_impact_bps, // Primary value
            ratio_tolerance_bps,  // Aux value
            clock,
            ctx
        )
    }

    fun create_proposal(
        config: &mut GovernanceConfig,
        proposal_type: u8,
        target_pool: ID,
        new_value: u64,
        aux_value: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): ID {
        let now = clock::timestamp_ms(clock);
        let proposal_id = object::new(ctx);
        let id = object::uid_to_inner(&proposal_id);
        object::delete(proposal_id); // We just need the ID

        let proposal = Proposal {
            id,
            proposal_type,
            target_pool,
            new_value,
            aux_value,
            proposer: tx_context::sender(ctx),
            created_at: now,
            executable_at: now + config.timelock_duration_ms,
            executed: false,
            cancelled: false,
        };

        table::add(&mut config.proposals, id, proposal);
        config.proposal_count = config.proposal_count + 1;

        event::emit(ProposalCreated {
            proposal_id: id,
            proposal_type,
            target_pool,
            new_value,
            executable_at: now + config.timelock_duration_ms,
        });

        id
    }

    // --- Execute Functions ---

    /// Execute fee change for regular pool
    public fun execute_fee_change_regular<CoinA, CoinB>(
        config: &mut GovernanceConfig,
        proposal_id: ID,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        let proposal = validate_proposal_execution(config, proposal_id, TYPE_FEE_CHANGE, object::id(pool), clock);
        
        pool::set_protocol_fee_percent(pool, proposal.new_value);
        
        // Mark executed
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Execute fee change for stable pool
    public fun execute_fee_change_stable<CoinA, CoinB>(
        config: &mut GovernanceConfig,
        proposal_id: ID,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        let proposal = validate_proposal_execution(config, proposal_id, TYPE_FEE_CHANGE, object::id(pool), clock);
        
        stable_pool::set_protocol_fee_percent(pool, proposal.new_value);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Execute parameter change for regular pool
    public fun execute_parameter_change_regular<CoinA, CoinB>(
        config: &mut GovernanceConfig,
        proposal_id: ID,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        let proposal = validate_proposal_execution(config, proposal_id, TYPE_PARAMETER_CHANGE, object::id(pool), clock);
        
        // new_value = max_price_impact, aux_value = ratio_tolerance
        pool::set_risk_params(pool, proposal.aux_value, proposal.new_value);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Execute parameter change for stable pool
    public fun execute_parameter_change_stable<CoinA, CoinB>(
        config: &mut GovernanceConfig,
        proposal_id: ID,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        let proposal = validate_proposal_execution(config, proposal_id, TYPE_PARAMETER_CHANGE, object::id(pool), clock);
        
        // Stable pool only has max_price_impact
        stable_pool::set_max_price_impact_bps(pool, proposal.new_value);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    // Helper to validate execution conditions
    fun validate_proposal_execution(
        config: &GovernanceConfig, 
        proposal_id: ID, 
        expected_type: u8,
        target_pool: ID,
        clock: &Clock
    ): &Proposal {
        assert!(table::contains(&config.proposals, proposal_id), EProposalNotFound);
        let proposal = table::borrow(&config.proposals, proposal_id);
        
        assert!(proposal.proposal_type == expected_type, EInvalidProposalType);
        assert!(proposal.target_pool == target_pool, EInvalidProposalType);
        assert!(!proposal.executed, EProposalAlreadyExecuted);
        assert!(!proposal.cancelled, EProposalAlreadyExecuted);
        
        let now = clock::timestamp_ms(clock);
        assert!(now >= proposal.executable_at, EProposalNotReady);
        assert!(now < proposal.executable_at + PROPOSAL_EXPIRY_MS, EProposalExpired);
        
        proposal
    }

    /// Cancel a proposal (Admin only)
    public fun cancel_proposal(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: ID,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&config.proposals, proposal_id), EProposalNotFound);
        let proposal = table::borrow_mut(&mut config.proposals, proposal_id);
        assert!(!proposal.executed, EProposalAlreadyExecuted);
        
        proposal.cancelled = true;
        
        event::emit(ProposalCancelled {
            proposal_id,
            cancelled_by: tx_context::sender(ctx),
        });
    }
}
