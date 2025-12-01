module sui_amm::governance {
    use sui::object;
    use sui::tx_context;
    use sui::transfer;
    use sui::table;
    use sui::clock;
    use sui::event;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::admin::AdminCap;
    
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
    // SECURITY FIX [P2-18.2]: Reduced proposal expiry from 30 days to 7 days
    // This reduces the window for stale proposals to be executed, improving governance security
    const PROPOSAL_EXPIRY_MS: u64 = 604_800_000; // 7 days (reduced from 30 days)
    const MAX_PROTOCOL_FEE_BPS: u64 = 1000; // 10% hard cap

    // Proposal Types
    const TYPE_FEE_CHANGE: u8 = 1;
    const TYPE_PARAMETER_CHANGE: u8 = 2;
    const TYPE_PAUSE: u8 = 3;  // SECURITY FIX [P2-18.1]: New proposal type for pause operations

    public struct Proposal has store, drop {
        id: object::ID,
        proposal_type: u8, 
        target_pool: object::ID,
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

    public struct GovernanceConfig has key {
        id: object::UID,
        timelock_duration_ms: u64,
        proposals: table::Table<ID, Proposal>,
        proposal_count: u64,
    }

    public struct ProposalCreated has copy, drop {
        proposal_id: object::ID,
        proposal_type: u8,
        target_pool: object::ID,
        new_value: u64,
        executable_at: u64,
    }

    public struct ProposalExecuted has copy, drop {
        proposal_id: object::ID,
        executed_at: u64,
    }

    public struct ProposalCancelled has copy, drop {
        proposal_id: object::ID,
        cancelled_by: address,
    }

    fun init(ctx: &mut tx_context::TxContext) {
        transfer::share_object(GovernanceConfig {
            id: object::new(ctx),
            timelock_duration_ms: TIMELOCK_DURATION_MS,
            proposals: table::new(ctx),
            proposal_count: 0,
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }

    // --- Propose Functions ---

    /// Propose a fee change. Requires AdminCap.
    public fun propose_fee_change(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        pool_id: object::ID,
        new_fee_percent: u64,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
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
        pool_id: object::ID,
        ratio_tolerance_bps: u64, // 0 for stable pools
        max_price_impact_bps: u64,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
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

    /// SECURITY FIX [P2-18.1]: Propose pool pause with timelock
    /// Adds a delay before pause takes effect to prevent instant pause abuse
    /// while maintaining emergency response capability through governance
    public fun propose_pause(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        pool_id: object::ID,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ): ID {
        create_proposal(
            config,
            TYPE_PAUSE,
            pool_id,
            0, // No value needed for pause
            0, // No aux value needed
            clock,
            ctx
        )
    }

    fun create_proposal(
        config: &mut GovernanceConfig,
        proposal_type: u8,
        target_pool: object::ID,
        new_value: u64,
        aux_value: u64,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
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
    /// SECURITY FIX [P1-15.2]: Added AdminCap requirement for execution
    /// This prevents unauthorized execution of governance proposals
    public fun execute_fee_change_regular<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
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
    /// SECURITY FIX [P1-15.2]: Added AdminCap requirement for execution
    /// This prevents unauthorized execution of governance proposals
    public fun execute_fee_change_stable<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
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
    /// SECURITY FIX [P1-15.2]: Added AdminCap requirement for execution
    /// This prevents unauthorized execution of governance proposals
    public fun execute_parameter_change_regular<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
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
    /// SECURITY FIX [P1-15.2]: Added AdminCap requirement for execution
    /// This prevents unauthorized execution of governance proposals
    public fun execute_parameter_change_stable<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
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
        proposal_id: object::ID, 
        expected_type: u8,
        target_pool: object::ID,
        clock: &clock::Clock
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

    /// SECURITY FIX [P2-18.1]: Execute pause proposal for regular pool
    /// Pauses pool operations after timelock delay
    public fun execute_pause_regular<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
    ) {
        let _proposal = validate_proposal_execution(config, proposal_id, TYPE_PAUSE, object::id(pool), clock);
        
        pool::pause_pool(pool, clock);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// SECURITY FIX [P2-18.1]: Execute pause proposal for stable pool
    /// Pauses pool operations after timelock delay
    public fun execute_pause_stable<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
    ) {
        let _proposal = validate_proposal_execution(config, proposal_id, TYPE_PAUSE, object::id(pool), clock);
        
        stable_pool::pause_pool(pool, clock);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Cancel a proposal (Admin only)
    public fun cancel_proposal(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        ctx: &mut tx_context::TxContext
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

    // Query Functions

    /// Get proposal status
    /// Returns: (proposal_type, executed, cancelled, executable_at, created_at)
    public fun get_proposal_status(
        config: &GovernanceConfig,
        proposal_id: object::ID
    ): (u8, bool, bool, u64, u64) {
        assert!(table::contains(&config.proposals, proposal_id), EProposalNotFound);
        let proposal = table::borrow(&config.proposals, proposal_id);
        (
            proposal.proposal_type,
            proposal.executed,
            proposal.cancelled,
            proposal.executable_at,
            proposal.created_at
        )
    }

    /// Get proposal details
    /// Returns: (proposal_type, target_pool, new_value, aux_value, proposer, executed, cancelled)
    public fun get_proposal_details(
        config: &GovernanceConfig,
        proposal_id: object::ID
    ): (u8, ID, u64, u64, address, bool, bool) {
        assert!(table::contains(&config.proposals, proposal_id), EProposalNotFound);
        let proposal = table::borrow(&config.proposals, proposal_id);
        (
            proposal.proposal_type,
            proposal.target_pool,
            proposal.new_value,
            proposal.aux_value,
            proposal.proposer,
            proposal.executed,
            proposal.cancelled
        )
    }

    /// Check if proposal is ready to execute
    /// Returns true if proposal exists, is not executed/cancelled, and timelock has passed
    public fun is_proposal_ready(
        config: &GovernanceConfig,
        proposal_id: object::ID,
        clock: &clock::Clock
    ): bool {
        if (!table::contains(&config.proposals, proposal_id)) {
            return false
        };
        
        let proposal = table::borrow(&config.proposals, proposal_id);
        
        if (proposal.executed || proposal.cancelled) {
            return false
        };
        
        let now = clock::timestamp_ms(clock);
        
        // Check if timelock has passed and not expired
        now >= proposal.executable_at && now < proposal.executable_at + PROPOSAL_EXPIRY_MS
    }

    /// Get total proposal count
    public fun get_proposal_count(config: &GovernanceConfig): u64 {
        config.proposal_count
    }

    /// Get timelock duration in milliseconds
    public fun get_timelock_duration(config: &GovernanceConfig): u64 {
        config.timelock_duration_ms
    }

    /// Check if proposal exists
    public fun proposal_exists(config: &GovernanceConfig, proposal_id: ID): bool {
        table::contains(&config.proposals, proposal_id)
    }
}
