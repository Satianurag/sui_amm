/// Implementation of the LPPosition NFT requirement.
/// This module manages the LPPosition struct which represents a user's liquidity position,
/// tracks fees, and stores metadata for dynamic NFT display.
module sui_amm::position {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::TxContext;
    use std::string::{Self, String};
    use sui::package::{Publisher};
    use sui::display;

    friend sui_amm::pool;
    friend sui_amm::stable_pool;
    friend sui_amm::fee_distributor;

    /// The LP Position NFT with cached values for dynamic display
    struct LPPosition has key, store {
        id: UID,
        pool_id: ID,
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        min_a: u64,
        min_b: u64,
        name: String,
        description: String,
        
        // NEW: Cached values for dynamic NFT display
        cached_value_a: u64,
        cached_value_b: u64,
        cached_fee_a: u64,
        cached_fee_b: u64,
        cached_il_bps: u64,
        pool_type: String,
        fee_tier_bps: u64,
    }

    /// View helper returned by pools for real-time position data without mutating NFTs
    struct PositionView has copy, drop {
        value_a: u64,
        value_b: u64,
        pending_fee_a: u64,
        pending_fee_b: u64,
        il_bps: u64,
    }

    public(friend) fun new(
        pool_id: ID,
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        min_a: u64,
        min_b: u64,
        name: String,
        description: String,
        ctx: &mut TxContext
    ): LPPosition {
        LPPosition {
            id: object::new(ctx),
            pool_id,
            liquidity,
            fee_debt_a,
            fee_debt_b,
            min_a,
            min_b,
            name,
            description,
            cached_value_a: min_a,
            cached_value_b: min_b,
            cached_fee_a: 0,
            cached_fee_b: 0,
            cached_il_bps: 0,
            pool_type: string::utf8(b"Regular"),
            fee_tier_bps: 30,
        }
    }

    /// Create position with metadata
    public(friend) fun new_with_metadata(
        pool_id: ID,
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        min_a: u64,
        min_b: u64,
        name: String,
        description: String,
        pool_type: String,
        fee_tier_bps: u64,
        ctx: &mut TxContext
    ): LPPosition {
        let position = LPPosition {
            id: object::new(ctx),
            pool_id,
            liquidity,
            fee_debt_a,
            fee_debt_b,
            min_a,
            min_b,
            name,
            description,
            cached_value_a: min_a,
            cached_value_b: min_b,
            cached_fee_a: 0,
            cached_fee_b: 0,
            cached_il_bps: 0,
            pool_type,
            fee_tier_bps,
        };
        position
    }

    public(friend) fun destroy(position: LPPosition) {
        let LPPosition {
            id,
            pool_id: _,
            liquidity: _,
            fee_debt_a: _,
            fee_debt_b: _,
            min_a: _,
            min_b: _,
            name: _,
            description: _,
            cached_value_a: _,
            cached_value_b: _,
            cached_fee_a: _,
            cached_fee_b: _,
            cached_il_bps: _,
            pool_type: _,
            fee_tier_bps: _,
        } = position;
        object::delete(id);
    }

    public fun pool_id(pos: &LPPosition): ID { pos.pool_id }
    public fun liquidity(pos: &LPPosition): u64 { pos.liquidity }
    public fun fee_debt_a(pos: &LPPosition): u128 { pos.fee_debt_a }
    public fun fee_debt_b(pos: &LPPosition): u128 { pos.fee_debt_b }
    public fun min_a(pos: &LPPosition): u64 { pos.min_a }
    public fun min_b(pos: &LPPosition): u64 { pos.min_b }
    public fun name(pos: &LPPosition): String { pos.name }
    public fun description(pos: &LPPosition): String { pos.description }
    public fun cached_value_a(pos: &LPPosition): u64 { pos.cached_value_a }
    public fun cached_value_b(pos: &LPPosition): u64 { pos.cached_value_b }
    public fun cached_fee_a(pos: &LPPosition): u64 { pos.cached_fee_a }
    public fun cached_fee_b(pos: &LPPosition): u64 { pos.cached_fee_b }
    public fun cached_il_bps(pos: &LPPosition): u64 { pos.cached_il_bps }

    /// Build a live view with current values (restricted to friend modules)
    public(friend) fun make_position_view(
        value_a: u64,
        value_b: u64,
        pending_fee_a: u64,
        pending_fee_b: u64,
        il_bps: u64,
    ): PositionView {
        PositionView {
            value_a,
            value_b,
            pending_fee_a,
            pending_fee_b,
            il_bps,
        }
    }

    /// Convenience getter that exposes the last cached view for legacy UIs
    public fun get_cached_view(position: &LPPosition): PositionView {
        make_position_view(
            position.cached_value_a,
            position.cached_value_b,
            position.cached_fee_a,
            position.cached_fee_b,
            position.cached_il_bps,
        )
    }

    public fun view_value(view: &PositionView): (u64, u64) {
        (view.value_a, view.value_b)
    }

    public fun view_fees(view: &PositionView): (u64, u64) {
        (view.pending_fee_a, view.pending_fee_b)
    }

    public(friend) fun increase_liquidity(pos: &mut LPPosition, amount: u64, amount_a: u64, amount_b: u64) {
        pos.liquidity = pos.liquidity + amount;
        pos.min_a = pos.min_a + amount_a;
        pos.min_b = pos.min_b + amount_b;
    }

    /// Decrease liquidity (for partial removal)
    /// CRITICAL FIX: Use proper proportional scaling to prevent precision loss
    public(friend) fun decrease_liquidity(
        pos: &mut LPPosition,
        liquidity_amount: u64
    ) {
        assert!(liquidity_amount <= pos.liquidity, 0); // Basic validation
        
        let original_liquidity = pos.liquidity;
        pos.liquidity = pos.liquidity - liquidity_amount;
        
        // Proportionally decrease min amounts using u128 to prevent precision loss
        if (pos.liquidity == 0) {
            // Complete removal - zero everything
            pos.min_a = 0;
            pos.min_b = 0;
        } else {
            // Partial removal - reduce min_a and min_b proportionally
            // Formula: new_min = old_min * remaining_liquidity / original_liquidity
            // Using u128 to prevent any precision loss
            let new_min_a = ((pos.min_a as u128) * (pos.liquidity as u128) / (original_liquidity as u128) as u64);
            let new_min_b = ((pos.min_b as u128) * (pos.liquidity as u128) / (original_liquidity as u128) as u64);
            
            pos.min_a = new_min_a;
            pos.min_b = new_min_b;
        };
    }

    public(friend) fun update_fee_debt(pos: &mut LPPosition, debt_a: u128, debt_b: u128) {
        pos.fee_debt_a = debt_a;
        pos.fee_debt_b = debt_b;
    }

    public(friend) fun update_cached_values(
        pos: &mut LPPosition,
        value_a: u64,
        value_b: u64,
        fee_a: u64,
        fee_b: u64,
        il_bps: u64,
    ) {
        pos.cached_value_a = value_a;
        pos.cached_value_b = value_b;
        pos.cached_fee_a = fee_a;
        pos.cached_fee_b = fee_b;
        pos.cached_il_bps = il_bps;
        // No on-chain SVG regeneration; cached values are used only for Display.
        // NOTE: These values are static snapshots. Users must call `refresh_position_metadata`
        // on the pool to update them before viewing if they want real-time data.
    }

    public(friend) fun set_pool_metadata(
        pos: &mut LPPosition,
        pool_type: String,
        fee_tier_bps: u64,
    ) {
        pos.pool_type = pool_type;
        pos.fee_tier_bps = fee_tier_bps;
    }

    public fun setup_display(publisher: &Publisher, ctx: &mut TxContext): display::Display<LPPosition> {
        let keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
            string::utf8(b"image_url"),
            string::utf8(b"project_url"),
            string::utf8(b"liquidity"),
            string::utf8(b"current_value"),
            string::utf8(b"fees_earned"),
            string::utf8(b"impermanent_loss"),
            string::utf8(b"pool_type"),
        ];

        let values = vector[
            string::utf8(b"{name}"),
            string::utf8(b"{description}"),
            // Off-chain renderer: construct image URL by position id with cache busting
            string::utf8(b"https://sui-amm.com/positions/{id}/image?v={cached_value_a}_{cached_value_b}"),
            string::utf8(b"https://sui-amm.com"),
            string::utf8(b"{liquidity} shares"),
            string::utf8(b"{cached_value_a} / {cached_value_b}"),
            string::utf8(b"{cached_fee_a} / {cached_fee_b}"),
            string::utf8(b"{cached_il_bps} bps"),
            string::utf8(b"{pool_type}"),
        ];

        let display = display::new_with_fields<LPPosition>(
            publisher, keys, values, ctx
        );

        display::update_version(&mut display);
        display
    }

    #[test_only]
    public fun destroy_for_testing(position: LPPosition) {
        destroy(position);
    }
}
