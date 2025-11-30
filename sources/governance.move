module sui_amm::governance {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    
    friend sui_amm::admin;

    // Error codes
    const EProposalNotReady: u64 = 0;
    const EProposalExpired: u64 = 1;
    const EInvalidFee: u64 = 2;
    const EUnauthorized: u64 = 3;
    const EProposalNotFound: u64 = 4;

    // Constants
    const TIMELOCK_DURATION_MS: u64 = 604_800_000; // 7 days
    const PROPOSAL_EXPIRY_MS: u64 = 1_209_600_000; // 14 days
    const MAX_PROTOCOL_FEE_BPS: u64 = 1000; // 10% hard cap

    struct FeeChangeProposal has store, copy, drop {
        pool_id: ID,
        pool_type: u8, // 0 = regular, 1 = stable
        new_fee_bps: u64,
        proposed_at: u64,
        execution_time: u64,
        expiry_time: u64,
        executed: bool,
    }

    struct GovernanceRegistry has key {
        id: UID,
        proposals: Table<ID, FeeChangeProposal>,
        admin: address,
        next_proposal_id: u64,
    }

    struct ProposalCreated has copy, drop {
        proposal_id: ID,
        pool_id: ID,
        new_fee_bps: u64,
        execution_time: u64,
    }

    struct ProposalExecuted has copy, drop {
        proposal_id: ID,
        pool_id: ID,
        new_fee_bps: u64,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(GovernanceRegistry {
            id: object::new(ctx),
            proposals: table::new(ctx),
            admin: tx_context::sender(ctx),
            next_proposal_id: 0,
        });
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Propose protocol fee change (admin only)
    public(friend) fun propose_fee_change(
        registry: &mut GovernanceRegistry,
        pool_id: ID,
        pool_type: u8,
        new_fee_bps: u64,
        clock: &Clock,
        _ctx: &mut TxContext
    ): ID {
        assert!(tx_context::sender(_ctx) == registry.admin, EUnauthorized);
        assert!(new_fee_bps <= MAX_PROTOCOL_FEE_BPS, EInvalidFee);

        let current_time = clock::timestamp_ms(clock);
        let execution_time = current_time + TIMELOCK_DURATION_MS;
        let expiry_time = execution_time + PROPOSAL_EXPIRY_MS;

        let proposal = FeeChangeProposal {
            pool_id,
            pool_type,
            new_fee_bps,
            proposed_at: current_time,
            execution_time,
            expiry_time,
            executed: false,
        };

        // Create unique proposal ID
        let proposal_id = object::id_from_address(
            @0x0 // This will be replaced with proper ID generation
        );
        table::add(&mut registry.proposals, proposal_id, proposal);
        registry.next_proposal_id = registry.next_proposal_id + 1;

        event::emit(ProposalCreated {
            proposal_id,
            pool_id,
            new_fee_bps,
            execution_time,
        });

        proposal_id
    }

    /// Execute fee change proposal (anyone can call after timelock)
    public fun execute_fee_change_regular<CoinA, CoinB>(
        registry: &mut GovernanceRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        proposal_id: ID,
        clock: &Clock,
        _ctx: &TxContext
    ) {
        assert!(table::contains(&registry.proposals, proposal_id), EProposalNotFound);
        
        let proposal = table::borrow_mut(&mut registry.proposals, proposal_id);
        assert!(!proposal.executed, EProposalNotReady);
        assert!(proposal.pool_type == 0, EInvalidFee);
        assert!(proposal.pool_id == object::id(pool), EInvalidFee);

        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= proposal.execution_time, EProposalNotReady);
        assert!(current_time <= proposal.expiry_time, EProposalExpired);

        // Execute the change
        pool::set_protocol_fee_percent(pool, proposal.new_fee_bps);
        proposal.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            pool_id: proposal.pool_id,
            new_fee_bps: proposal.new_fee_bps,
        });
    }

    /// Execute fee change for stable pool
    public fun execute_fee_change_stable<CoinA, CoinB>(
        registry: &mut GovernanceRegistry,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        proposal_id: ID,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        assert!(table::contains(&registry.proposals, proposal_id), EProposalNotFound);
        
        let proposal = table::borrow_mut(&mut registry.proposals, proposal_id);
        assert!(!proposal.executed, EProposalNotReady);
        assert!(proposal.pool_type == 1, EInvalidFee);
        assert!(proposal.pool_id == object::id(pool), EInvalidFee);

        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= proposal.execution_time, EProposalNotReady);
        assert!(current_time <= proposal.expiry_time, EProposalExpired);

        stable_pool::set_protocol_fee_percent(pool, proposal.new_fee_bps);
        proposal.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            pool_id: proposal.pool_id,
            new_fee_bps: proposal.new_fee_bps,
        });
    }

    /// FIX [M2]: Governance for risk parameters (ratio tolerance, max price impact)
    /// Admin can update risk parameters immediately (no timelock for safety)
    public(friend) fun update_risk_params<CoinA, CoinB>(
        registry: &GovernanceRegistry,
        pool: &mut LiquidityPool<CoinA, CoinB>,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.admin, EUnauthorized);
        pool::set_risk_params(pool, ratio_tolerance_bps, max_price_impact_bps);
    }

    /// FIX [M2]: Governance for stable pool risk parameters
    public(friend) fun update_stable_risk_params<CoinA, CoinB>(
        registry: &GovernanceRegistry,
        pool: &mut StableSwapPool<CoinA, CoinB>,
        max_price_impact_bps: u64,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.admin, EUnauthorized);
        stable_pool::set_max_price_impact_bps(pool, max_price_impact_bps);
    }

    // View functions
    public fun get_proposal(registry: &GovernanceRegistry, proposal_id: ID): FeeChangeProposal {
        assert!(table::contains(&registry.proposals, proposal_id), EProposalNotFound);
        *table::borrow(&registry.proposals, proposal_id)
    }

    public fun timelock_duration(): u64 { TIMELOCK_DURATION_MS }
    public fun max_protocol_fee(): u64 { MAX_PROTOCOL_FEE_BPS }
    public fun admin(registry: &GovernanceRegistry): address { registry.admin }
}
