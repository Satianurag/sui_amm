/// Governance module for time-locked protocol parameter changes
///
/// This module implements a timelock-based governance system that prevents unilateral
/// changes to critical protocol parameters. All parameter modifications must go through
/// a proposal process with a mandatory delay, providing transparency and allowing the
/// community to respond to potentially harmful changes.
///
/// # Governance Model
/// - Proposals require AdminCap to create (can be held by multi-sig or DAO)
/// - All proposals have a 48-hour timelock before execution
/// - Proposals expire after 7 days if not executed
/// - Proposals can be cancelled by admin before execution
///
/// # Supported Proposal Types
/// 1. Fee Changes: Modify protocol fee percentages (capped at 10%)
/// 2. Parameter Changes: Adjust risk parameters like price impact limits
/// 3. Pause Operations: Emergency pause of pool operations with timelock
///
/// # Security Considerations
/// The timelock mechanism prevents:
/// - Front-running governance decisions
/// - Instant parameter changes that could harm liquidity providers
/// - Malicious pause operations to manipulate prices
/// - Execution of stale proposals through expiry mechanism
module sui_amm::governance {
    use sui::table;
    use sui::clock;
    use sui::event;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui_amm::admin::AdminCap;
    
    /// Proposal cannot be executed yet (timelock not expired)
    const EProposalNotReady: u64 = 0;
    /// Proposal has expired and can no longer be executed
    const EProposalExpired: u64 = 1;
    /// Proposed fee exceeds maximum allowed protocol fee
    const EInvalidFee: u64 = 2;
    /// Reserved for future authorization checks
    #[allow(unused_const)]
    const EUnauthorized: u64 = 3;
    /// Proposal ID does not exist in governance system
    const EProposalNotFound: u64 = 4;
    /// Proposal has already been executed or cancelled
    const EProposalAlreadyExecuted: u64 = 5;
    /// Proposal type does not match expected type for execution
    const EInvalidProposalType: u64 = 6;

    /// Timelock duration: 48 hours
    ///
    /// This delay provides sufficient time for the community to review and respond to
    /// governance proposals. It prevents instant parameter changes that could be used
    /// to front-run large trades or manipulate pool behavior.
    const TIMELOCK_DURATION_MS: u64 = 172_800_000;
    
    /// Proposal expiry window: 7 days after timelock expiration
    ///
    /// Proposals must be executed within 7 days of becoming executable. This prevents
    /// stale proposals from being executed long after they were created, when market
    /// conditions or protocol state may have changed significantly. The reduced window
    /// (from 30 days) improves governance security by ensuring timely execution or
    /// explicit cancellation of proposals.
    const PROPOSAL_EXPIRY_MS: u64 = 604_800_000;
    
    /// Maximum protocol fee: 10% (1000 basis points)
    ///
    /// This hard cap prevents excessive fee extraction that could make the protocol
    /// uncompetitive or harm liquidity providers. Even with governance approval,
    /// fees cannot exceed this limit.
    const MAX_PROTOCOL_FEE_BPS: u64 = 1000;

    /// Proposal type: Fee change
    const TYPE_FEE_CHANGE: u8 = 1;
    /// Proposal type: Risk parameter change
    const TYPE_PARAMETER_CHANGE: u8 = 2;
    /// Proposal type: Emergency pause operation
    ///
    /// Pause proposals require timelock to prevent instant pause abuse where an
    /// administrator could pause a pool to manipulate prices or front-run trades.
    /// For true emergencies, a separate multi-sig emergency mechanism can bypass
    /// the timelock with higher authorization requirements.
    const TYPE_PAUSE: u8 = 3;

    /// Governance proposal for protocol parameter changes
    ///
    /// Each proposal represents a pending change to protocol parameters that must
    /// wait for the timelock period before execution. Proposals are stored in the
    /// GovernanceConfig and can be queried, executed, or cancelled.
    ///
    /// # Field Semantics
    /// - `new_value`: Primary parameter value (fee_bps for fee changes, max_price_impact_bps for param changes)
    /// - `aux_value`: Secondary parameter value (ratio_tolerance for regular pool param changes, unused for others)
    ///
    /// # Lifecycle
    /// 1. Created: Proposal is submitted with timelock delay
    /// 2. Pending: Waiting for timelock to expire
    /// 3. Executable: Timelock expired, can be executed within expiry window
    /// 4. Executed/Cancelled: Final state, proposal cannot be modified
    public struct Proposal has store, drop {
        id: object::ID,
        proposal_type: u8, 
        target_pool: object::ID,
        new_value: u64,
        aux_value: u64,
        proposer: address,
        created_at: u64,
        executable_at: u64,
        executed: bool,
        cancelled: bool,
    }

    /// Shared governance configuration and proposal storage
    ///
    /// This shared object stores all governance proposals and configuration parameters.
    /// It is created during module initialization and persists for the lifetime of the
    /// protocol. All governance operations interact with this object.
    ///
    /// # Shared Object Design
    /// Using a shared object allows multiple transactions to interact with governance
    /// concurrently while maintaining consistency through Sui's consensus mechanism.
    public struct GovernanceConfig has key {
        id: object::UID,
        timelock_duration_ms: u64,
        proposals: table::Table<ID, Proposal>,
        proposal_count: u64,
    }

    /// Event emitted when a new governance proposal is created
    ///
    /// This event allows off-chain systems to track pending proposals and notify
    /// stakeholders about upcoming parameter changes. The executable_at timestamp
    /// indicates when the proposal can be executed.
    public struct ProposalCreated has copy, drop {
        proposal_id: object::ID,
        proposal_type: u8,
        target_pool: object::ID,
        new_value: u64,
        executable_at: u64,
    }

    /// Event emitted when a governance proposal is successfully executed
    ///
    /// This event confirms that a parameter change has been applied to the protocol.
    /// Off-chain systems can use this to update their state and notify users of the
    /// completed change.
    public struct ProposalExecuted has copy, drop {
        proposal_id: object::ID,
        executed_at: u64,
    }

    /// Event emitted when a governance proposal is cancelled
    ///
    /// Proposals can be cancelled by the admin before execution if they are no longer
    /// needed or if conditions have changed. This event records who cancelled the
    /// proposal for transparency.
    public struct ProposalCancelled has copy, drop {
        proposal_id: object::ID,
        cancelled_by: address,
    }

    /// Initialize the governance module and create shared configuration
    ///
    /// This function is called automatically when the module is published. It creates
    /// a shared GovernanceConfig object that will store all proposals and governance
    /// parameters for the lifetime of the protocol.
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

    /// Propose a protocol fee change for a pool
    ///
    /// Creates a governance proposal to modify the protocol fee percentage. The fee
    /// determines what portion of swap fees goes to the protocol treasury versus
    /// liquidity providers. The proposal must wait for the timelock period before
    /// it can be executed.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization to create proposals
    /// - `config`: Shared governance configuration
    /// - `pool_id`: The pool to modify
    /// - `new_fee_percent`: New protocol fee in basis points (max 1000 = 10%)
    /// - `clock`: Clock for timestamp validation
    /// - `ctx`: Transaction context
    ///
    /// # Returns
    /// The proposal ID that can be used to query status and execute the proposal
    ///
    /// # Aborts
    /// - `EInvalidFee`: If new_fee_percent exceeds MAX_PROTOCOL_FEE_BPS (10%)
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized proposal creation
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

    /// Propose a risk parameter change for a pool
    ///
    /// Creates a governance proposal to modify risk parameters that protect liquidity
    /// providers from excessive price impact and ratio imbalances. These parameters
    /// help prevent sandwich attacks and ensure fair pricing.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Shared governance configuration
    /// - `pool_id`: The pool to modify
    /// - `ratio_tolerance_bps`: Maximum allowed reserve ratio deviation (0 for stable pools)
    /// - `max_price_impact_bps`: Maximum allowed price impact per swap
    /// - `clock`: Clock for timestamp validation
    /// - `ctx`: Transaction context
    ///
    /// # Returns
    /// The proposal ID for tracking and execution
    ///
    /// # Parameter Semantics
    /// - Regular pools use both ratio_tolerance and max_price_impact
    /// - Stable pools only use max_price_impact (ratio_tolerance should be 0)
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized proposal creation
    public fun propose_parameter_change(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        pool_id: object::ID,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
        clock: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ): ID {
        create_proposal(
            config,
            TYPE_PARAMETER_CHANGE,
            pool_id,
            max_price_impact_bps,
            ratio_tolerance_bps,
            clock,
            ctx
        )
    }

    /// Propose an emergency pause of pool operations
    ///
    /// Creates a governance proposal to pause a pool, disabling all swaps and liquidity
    /// operations. The timelock delay prevents instant pause abuse where an administrator
    /// could pause a pool to manipulate prices or front-run large trades.
    ///
    /// For true emergencies requiring immediate response, a separate multi-sig emergency
    /// mechanism can bypass the timelock with higher authorization requirements.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Shared governance configuration
    /// - `pool_id`: The pool to pause
    /// - `clock`: Clock for timestamp validation
    /// - `ctx`: Transaction context
    ///
    /// # Returns
    /// The proposal ID for tracking and execution
    ///
    /// # Security Rationale
    /// The timelock on pause operations provides transparency and prevents malicious
    /// pausing. However, it means genuine emergencies require either:
    /// 1. Waiting 48 hours for the pause to take effect
    /// 2. Using a separate emergency pause mechanism with multi-sig requirements
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized pause proposals
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
            0,
            0,
            clock,
            ctx
        )
    }

    /// Internal helper to create a new governance proposal
    ///
    /// This function handles the common logic for creating proposals of any type.
    /// It generates a unique proposal ID, calculates the executable timestamp based
    /// on the timelock duration, stores the proposal, and emits an event.
    ///
    /// # Parameters
    /// - `config`: Governance configuration to store the proposal
    /// - `proposal_type`: Type of proposal (fee change, parameter change, pause)
    /// - `target_pool`: Pool that will be affected by the proposal
    /// - `new_value`: Primary parameter value
    /// - `aux_value`: Secondary parameter value (if needed)
    /// - `clock`: Clock for timestamp calculation
    /// - `ctx`: Transaction context for ID generation and sender address
    ///
    /// # Returns
    /// The unique proposal ID that can be used to query and execute the proposal
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
        object::delete(proposal_id);

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

    /// Execute a fee change proposal for a regular liquidity pool
    ///
    /// Applies the proposed protocol fee change to the specified pool after validating
    /// that the timelock has expired and the proposal is still valid. The proposal is
    /// marked as executed to prevent double execution.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization to execute proposals
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the proposal to execute
    /// - `pool`: The pool to modify (must match proposal's target_pool)
    /// - `clock`: Clock for timestamp validation
    /// - `_ctx`: Transaction context
    ///
    /// # Aborts
    /// - `EProposalNotFound`: Proposal ID doesn't exist
    /// - `EInvalidProposalType`: Proposal type or target pool doesn't match
    /// - `EProposalAlreadyExecuted`: Proposal was already executed or cancelled
    /// - `EProposalNotReady`: Timelock hasn't expired yet
    /// - `EProposalExpired`: Proposal expired (more than 7 days after becoming executable)
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized execution. This ensures that even though
    /// proposals are public and time-locked, only authorized addresses can execute them.
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
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Execute a fee change proposal for a stable swap pool
    ///
    /// Similar to regular pool fee changes, but applies to stable swap pools which
    /// use a different pricing curve optimized for pegged assets.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the proposal to execute
    /// - `pool`: The stable swap pool to modify
    /// - `clock`: Clock for timestamp validation
    /// - `_ctx`: Transaction context
    ///
    /// # Aborts
    /// Same abort conditions as execute_fee_change_regular
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized execution
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

    /// Execute a risk parameter change proposal for a regular liquidity pool
    ///
    /// Applies the proposed risk parameter changes to protect liquidity providers from
    /// excessive price impact and reserve ratio imbalances. These parameters help prevent
    /// sandwich attacks and ensure fair pricing.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the proposal to execute
    /// - `pool`: The pool to modify
    /// - `clock`: Clock for timestamp validation
    /// - `_ctx`: Transaction context
    ///
    /// # Parameter Application
    /// - `new_value`: Applied as max_price_impact_bps
    /// - `aux_value`: Applied as ratio_tolerance_bps
    ///
    /// # Aborts
    /// Same abort conditions as execute_fee_change_regular
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized execution
    public fun execute_parameter_change_regular<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
    ) {
        let proposal = validate_proposal_execution(config, proposal_id, TYPE_PARAMETER_CHANGE, object::id(pool), clock);
        
        pool::set_risk_params(pool, proposal.aux_value, proposal.new_value);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Execute a risk parameter change proposal for a stable swap pool
    ///
    /// Applies risk parameter changes to stable swap pools. Unlike regular pools,
    /// stable pools only use max_price_impact and don't have ratio_tolerance since
    /// they're designed for pegged assets with minimal price deviation.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the proposal to execute
    /// - `pool`: The stable swap pool to modify
    /// - `clock`: Clock for timestamp validation
    /// - `_ctx`: Transaction context
    ///
    /// # Parameter Application
    /// Only `new_value` is used as max_price_impact_bps (aux_value is ignored)
    ///
    /// # Aborts
    /// Same abort conditions as execute_fee_change_regular
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized execution
    public fun execute_parameter_change_stable<CoinA, CoinB>(
        _admin: &AdminCap,
        config: &mut GovernanceConfig,
        proposal_id: object::ID,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock,
        _ctx: &mut tx_context::TxContext
    ) {
        let proposal = validate_proposal_execution(config, proposal_id, TYPE_PARAMETER_CHANGE, object::id(pool), clock);
        
        stable_pool::set_max_price_impact_bps(pool, proposal.new_value);
        
        let proposal_mut = table::borrow_mut(&mut config.proposals, proposal_id);
        proposal_mut.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_at: clock::timestamp_ms(clock),
        });
    }

    /// Internal helper to validate proposal execution conditions
    ///
    /// Performs comprehensive validation before allowing proposal execution:
    /// - Proposal exists and matches expected type
    /// - Proposal targets the correct pool
    /// - Proposal hasn't been executed or cancelled
    /// - Timelock has expired
    /// - Proposal hasn't expired (within 7-day execution window)
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    /// - `proposal_id`: ID of proposal to validate
    /// - `expected_type`: Expected proposal type (must match)
    /// - `target_pool`: Expected target pool (must match)
    /// - `clock`: Clock for timestamp validation
    ///
    /// # Returns
    /// Reference to the validated proposal
    ///
    /// # Aborts
    /// - `EProposalNotFound`: Proposal doesn't exist
    /// - `EInvalidProposalType`: Type or target mismatch
    /// - `EProposalAlreadyExecuted`: Already executed or cancelled
    /// - `EProposalNotReady`: Timelock not expired
    /// - `EProposalExpired`: Past execution window
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

    /// Execute a pause proposal for a regular liquidity pool
    ///
    /// Pauses all pool operations (swaps, add/remove liquidity) after the timelock
    /// delay has expired. The timelock prevents instant pause abuse while maintaining
    /// emergency response capability through the governance process.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the pause proposal to execute
    /// - `pool`: The pool to pause
    /// - `clock`: Clock for timestamp validation
    /// - `_ctx`: Transaction context
    ///
    /// # Security Model
    /// The timelock on pause operations prevents malicious pausing to manipulate prices
    /// or front-run trades. For genuine emergencies, a separate multi-sig emergency
    /// mechanism can provide immediate pause capability with higher authorization thresholds.
    ///
    /// # Aborts
    /// Same abort conditions as execute_fee_change_regular
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized execution
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

    /// Execute a pause proposal for a stable swap pool
    ///
    /// Similar to regular pool pausing, but applies to stable swap pools. Stable pools
    /// may require pausing due to de-pegging events, amplification coefficient issues,
    /// or oracle failures for pegged assets.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the pause proposal to execute
    /// - `pool`: The stable swap pool to pause
    /// - `clock`: Clock for timestamp validation
    /// - `_ctx`: Transaction context
    ///
    /// # Stable Pool Considerations
    /// Stable pools may need pausing when:
    /// - Pegged assets de-peg significantly
    /// - Oracle feeds fail or provide stale data
    /// - Amplification coefficient causes unexpected behavior
    ///
    /// # Aborts
    /// Same abort conditions as execute_fee_change_regular
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized execution
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

    /// Cancel a pending governance proposal
    ///
    /// Allows the admin to cancel a proposal before it is executed. This is useful when:
    /// - Conditions have changed making the proposal unnecessary
    /// - An error was made in the proposal parameters
    /// - The community has raised concerns about the proposal
    ///
    /// Cancelled proposals cannot be executed and remain in the cancelled state permanently.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `config`: Governance configuration containing the proposal
    /// - `proposal_id`: ID of the proposal to cancel
    /// - `ctx`: Transaction context for recording who cancelled
    ///
    /// # Aborts
    /// - `EProposalNotFound`: Proposal doesn't exist
    /// - `EProposalAlreadyExecuted`: Proposal was already executed (cannot cancel)
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized cancellation
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

    /// Query the status of a governance proposal
    ///
    /// Returns key status information about a proposal including its type, execution
    /// state, and timing information. This allows off-chain systems and users to track
    /// proposal progress.
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    /// - `proposal_id`: ID of the proposal to query
    ///
    /// # Returns
    /// Tuple of (proposal_type, executed, cancelled, executable_at, created_at)
    ///
    /// # Aborts
    /// - `EProposalNotFound`: Proposal ID doesn't exist
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

    /// Query detailed information about a governance proposal
    ///
    /// Returns comprehensive details about a proposal including the target pool,
    /// proposed parameter values, and who created the proposal. This is useful for
    /// displaying proposal information in user interfaces.
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    /// - `proposal_id`: ID of the proposal to query
    ///
    /// # Returns
    /// Tuple of (proposal_type, target_pool, new_value, aux_value, proposer, executed, cancelled)
    ///
    /// # Aborts
    /// - `EProposalNotFound`: Proposal ID doesn't exist
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

    /// Check if a proposal is ready for execution
    ///
    /// Determines whether a proposal can currently be executed by checking:
    /// - Proposal exists
    /// - Not already executed or cancelled
    /// - Timelock has expired
    /// - Still within execution window (not expired)
    ///
    /// This is useful for off-chain systems to determine when to submit execution
    /// transactions.
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    /// - `proposal_id`: ID of the proposal to check
    /// - `clock`: Clock for current timestamp
    ///
    /// # Returns
    /// True if the proposal can be executed now, false otherwise
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
        
        now >= proposal.executable_at && now < proposal.executable_at + PROPOSAL_EXPIRY_MS
    }

    /// Get the total number of proposals created
    ///
    /// Returns the cumulative count of all proposals ever created in the governance
    /// system. This includes executed, cancelled, and pending proposals.
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    ///
    /// # Returns
    /// Total number of proposals created
    public fun get_proposal_count(config: &GovernanceConfig): u64 {
        config.proposal_count
    }

    /// Get the configured timelock duration
    ///
    /// Returns the delay period (in milliseconds) that must pass between proposal
    /// creation and execution. Currently set to 48 hours.
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    ///
    /// # Returns
    /// Timelock duration in milliseconds
    public fun get_timelock_duration(config: &GovernanceConfig): u64 {
        config.timelock_duration_ms
    }

    /// Check if a proposal exists in the governance system
    ///
    /// Simple existence check for a proposal ID. Returns true if the proposal was
    /// created, regardless of its current state (pending, executed, or cancelled).
    ///
    /// # Parameters
    /// - `config`: Governance configuration to query
    /// - `proposal_id`: ID to check
    ///
    /// # Returns
    /// True if the proposal exists, false otherwise
    public fun proposal_exists(config: &GovernanceConfig, proposal_id: ID): bool {
        table::contains(&config.proposals, proposal_id)
    }
}
