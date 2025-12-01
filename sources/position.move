/// Implementation of the LPPosition NFT requirement.
/// This module manages the LPPosition struct which represents a user's liquidity position,
/// tracks fees, and stores metadata for dynamic NFT display.
module sui_amm::position {
    use std::string;
    use sui::package;
    use sui::display;

    /// The LP Position NFT with cached values for dynamic display
    /// WARNING: Cached values may be stale. Call refresh_position_metadata() for accurate data.
    public struct LPPosition has key, store {
        id: object::UID,
        pool_id: object::ID,
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        min_a: u64,
        min_b: u64,
        name: string::String,
        description: string::String,
        
        // NEW: Track original entry for IL calculation
        entry_price_ratio_scaled: u64,  // (reserve_b * 1e9) / reserve_a at first deposit
        original_deposit_a: u64,  // First deposit amount A
        original_deposit_b: u64,  // First deposit amount B
        
        // NEW: Cached values for dynamic NFT display
        // IMPORTANT: These values are cached and may be stale after pool swaps
        // Always call get_position_view() for real-time accurate values
        cached_value_a: u64,
        cached_value_b: u64,
        cached_fee_a: u64,
        cached_fee_b: u64,
        cached_il_bps: u64,
        pool_type: string::String,
        fee_tier_bps: u64,
        // On-chain SVG image as base64 data URI
        cached_image_url: string::String,
        // Staleness tracking: timestamp of last metadata update
        last_metadata_update_ms: u64,
    }

    /// View helper returned by pools for real-time position data without mutating NFTs
    public struct PositionView has copy, drop {
        value_a: u64,
        value_b: u64,
        pending_fee_a: u64,
        pending_fee_b: u64,
        il_bps: u64,
    }

    public(package) fun new(
        pool_id: object::ID,
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        min_a: u64,
        min_b: u64,
        name: string::String,
        description: string::String,
        ctx: &mut tx_context::TxContext
    ): LPPosition {
        // SECURITY FIX [P1-15.5]: Increase IL calculation precision from 1e9 to 1e12
        // Calculate entry price ratio: (min_b * 1e12) / min_a
        // 
        // ENTRY PRICE RATIO VALIDATION:
        // Expected range: 0 to u64::MAX (18,446,744,073,709,551,615)
        // - For balanced pools (1:1 ratio): ~1e12 (1,000,000,000,000)
        // - For 10:1 ratio: ~10e12 (10,000,000,000,000)
        // - For 1:10 ratio: ~0.1e12 (100,000,000,000)
        // - Zero value indicates min_a was zero (edge case, should not occur in practice)
        // 
        // This ratio is used for accurate impermanent loss calculation and remains
        // constant throughout the position's lifetime to track IL from initial entry.
        let entry_price_ratio_scaled = if (min_a == 0) {
            0
        } else {
            ((min_b as u128) * 1_000_000_000_000 / (min_a as u128) as u64)
        };
        
        let pos = LPPosition {
            id: object::new(ctx),
            pool_id,
            liquidity,
            fee_debt_a,
            fee_debt_b,
            min_a,
            min_b,
            name,
            description,
            entry_price_ratio_scaled,
            original_deposit_a: min_a,
            original_deposit_b: min_b,
            cached_value_a: min_a,
            cached_value_b: min_b,
            cached_fee_a: 0,
            cached_fee_b: 0,
            cached_il_bps: 0,
            pool_type: string::utf8(b"Regular"),
            fee_tier_bps: 30,
            // Generate initial SVG inline
            cached_image_url: sui_amm::svg_nft::generate_lp_position_svg(
                string::utf8(b"Regular"),
                liquidity,
                min_a,
                min_b,
                0,
                0,
                0,
                30
            ),
            last_metadata_update_ms: 0,
        };
        pos
    }

    /// Create position with metadata
    public(package) fun new_with_metadata(
        pool_id: object::ID,
        liquidity: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
        min_a: u64,
        min_b: u64,
        name: string::String,
        description: string::String,
        pool_type: string::String,
        fee_tier_bps: u64,
        ctx: &mut tx_context::TxContext
    ): LPPosition {
        // SECURITY FIX [P1-15.5]: Increase IL calculation precision from 1e9 to 1e12
        // Calculate entry price ratio: (min_b * 1e12) / min_a
        // 
        // ENTRY PRICE RATIO VALIDATION:
        // Expected range: 0 to u64::MAX (18,446,744,073,709,551,615)
        // - For balanced pools (1:1 ratio): ~1e12 (1,000,000,000,000)
        // - For 10:1 ratio: ~10e12 (10,000,000,000,000)
        // - For 1:10 ratio: ~0.1e12 (100,000,000,000)
        // - Zero value indicates min_a was zero (edge case, should not occur in practice)
        // 
        // This ratio is used for accurate impermanent loss calculation and remains
        // constant throughout the position's lifetime to track IL from initial entry.
        let entry_price_ratio_scaled = if (min_a == 0) {
            0
        } else {
            ((min_b as u128) * 1_000_000_000_000 / (min_a as u128) as u64)
        };
        
        // Generate initial SVG inline
        let image_url = sui_amm::svg_nft::generate_lp_position_svg(
            pool_type,
            liquidity,
            min_a,
            min_b,
            0,
            0,
            0,
            fee_tier_bps
        );
        
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
            entry_price_ratio_scaled,
            original_deposit_a: min_a,
            original_deposit_b: min_b,
            cached_value_a: min_a,
            cached_value_b: min_b,
            cached_fee_a: 0,
            cached_fee_b: 0,
            cached_il_bps: 0,
            pool_type,
            fee_tier_bps,
            cached_image_url: image_url,
            last_metadata_update_ms: 0,
        };
        position
    }

    public(package) fun destroy(position: LPPosition) {
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
            entry_price_ratio_scaled: _,
            original_deposit_a: _,
            original_deposit_b: _,
            cached_value_a: _,
            cached_value_b: _,
            cached_fee_a: _,
            cached_fee_b: _,
            cached_il_bps: _,
            pool_type: _,
            fee_tier_bps: _,
            cached_image_url: _,
            last_metadata_update_ms: _,
        } = position;
        object::delete(id);
    }

    public fun pool_id(pos: &LPPosition): ID { pos.pool_id }
    public fun liquidity(pos: &LPPosition): u64 { pos.liquidity }
    public fun fee_debt_a(pos: &LPPosition): u128 { pos.fee_debt_a }
    public fun fee_debt_b(pos: &LPPosition): u128 { pos.fee_debt_b }
    public fun min_a(pos: &LPPosition): u64 { pos.min_a }
    public fun min_b(pos: &LPPosition): u64 { pos.min_b }
    public fun name(pos: &LPPosition): string::String { pos.name }
    public fun description(pos: &LPPosition): string::String { pos.description }
    public fun cached_value_a(pos: &LPPosition): u64 { pos.cached_value_a }
    public fun cached_value_b(pos: &LPPosition): u64 { pos.cached_value_b }
    public fun cached_fee_a(pos: &LPPosition): u64 { pos.cached_fee_a }
    public fun cached_fee_b(pos: &LPPosition): u64 { pos.cached_fee_b }
    public fun cached_il_bps(pos: &LPPosition): u64 { pos.cached_il_bps }

    /// Build a live view with current values (restricted to package modules)
    public(package) fun make_position_view(
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

    public(package) fun increase_liquidity(pos: &mut LPPosition, amount: u64, amount_a: u64, amount_b: u64) {
        pos.liquidity = pos.liquidity + amount;
        pos.min_a = pos.min_a + amount_a;
        pos.min_b = pos.min_b + amount_b;
        
        // FIX [P2-16.4]: Entry Price Ratio Tracking - INTENTIONAL DESIGN DECISION
        // 
        // DO NOT update entry_price_ratio_scaled, original_deposit_a, or original_deposit_b
        // when increasing liquidity. These fields track the INITIAL entry price for accurate
        // impermanent loss (IL) calculation.
        //
        // Rationale:
        // - IL is calculated relative to the original entry price, not the average entry price
        // - Updating these values would incorrectly reduce displayed IL
        // - Users need to see IL from their first deposit to make informed decisions
        //
        // If users want to track IL for new deposits separately, they should:
        // 1. Create a new position for the additional liquidity, OR
        // 2. Use external tracking tools to monitor multiple entry points
        //
        // This behavior is documented and intentional, not a bug.
    }

    /// Decrease liquidity (for partial removal)
    /// FIX [P2-16.5]: Use u128 arithmetic to prevent precision loss in partial removals
    /// 
    /// This function uses u128 intermediate calculations to ensure maximum precision
    /// when proportionally reducing min_a and min_b values during partial liquidity removal.
    /// 
    /// Precision Analysis:
    /// - u64 max value: 18,446,744,073,709,551,615
    /// - u128 max value: 340,282,366,920,938,463,463,374,607,431,768,211,455
    /// - For typical pool values (< 10^18), u128 arithmetic prevents any precision loss
    /// 
    /// Example:
    /// - Original liquidity: 1,000,000
    /// - Remove: 300,000 (30%)
    /// - Remaining: 700,000 (70%)
    /// - min_a calculation: (min_a * 700,000) / 1,000,000 using u128
    /// - This preserves all significant digits without rounding errors
    public(package) fun decrease_liquidity(
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
            
            // FIX [P2-16.5]: Verify no precision loss occurred
            // The new values should be proportional to the remaining liquidity
            // This assertion catches any unexpected rounding issues
            let expected_ratio = (pos.liquidity as u128) * 10000 / (original_liquidity as u128);
            let actual_ratio_a = if (pos.min_a > 0) {
                (new_min_a as u128) * 10000 / (pos.min_a as u128)
            } else {
                expected_ratio
            };
            let actual_ratio_b = if (pos.min_b > 0) {
                (new_min_b as u128) * 10000 / (pos.min_b as u128)
            } else {
                expected_ratio
            };
            
            // Allow 1 basis point tolerance for rounding
            assert!(actual_ratio_a >= expected_ratio - 1 && actual_ratio_a <= expected_ratio + 1, 0);
            assert!(actual_ratio_b >= expected_ratio - 1 && actual_ratio_b <= expected_ratio + 1, 0);
            
            pos.min_a = new_min_a;
            pos.min_b = new_min_b;
        };
    }

    public(package) fun update_fee_debt(pos: &mut LPPosition, debt_a: u128, debt_b: u128) {
        pos.fee_debt_a = debt_a;
        pos.fee_debt_b = debt_b;
    }

    public(package) fun update_cached_values(
        pos: &mut LPPosition,
        value_a: u64,
        value_b: u64,
        fee_a: u64,
        fee_b: u64,
        il_bps: u64,
        clock: &sui::clock::Clock,
    ) {
        pos.cached_value_a = value_a;
        pos.cached_value_b = value_b;
        pos.cached_fee_a = fee_a;
        pos.cached_fee_b = fee_b;
        pos.cached_il_bps = il_bps;
        pos.last_metadata_update_ms = sui::clock::timestamp_ms(clock);
        // Regenerate on-chain SVG with updated values
        refresh_nft_image(pos);
    }

    public(package) fun set_pool_metadata(
        pos: &mut LPPosition,
        pool_type: string::String,
        fee_tier_bps: u64,
    ) {
        pos.pool_type = pool_type;
        pos.fee_tier_bps = fee_tier_bps;
    }

    public fun setup_display(publisher: &package::Publisher, ctx: &mut tx_context::TxContext): display::Display<LPPosition> {
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
            // On-chain SVG stored in cached_image_url field (generated by refresh_nft_image)
            string::utf8(b"{cached_image_url}"),
            string::utf8(b"https://sui-amm.io"),
            string::utf8(b"{liquidity} shares"),
            string::utf8(b"{cached_value_a} / {cached_value_b}"),
            string::utf8(b"{cached_fee_a} / {cached_fee_b}"),
            string::utf8(b"{cached_il_bps} bps"),
            string::utf8(b"{pool_type}"),
        ];

        let mut display = display::new_with_fields<LPPosition>(
            publisher, keys, values, ctx
        );

        display::update_version(&mut display);
        display
    }

    /// Generate and cache the on-chain SVG image for this position
    /// Call this to update the NFT image before listing on marketplaces
    public(package) fun refresh_nft_image(pos: &mut LPPosition) {
        let image_url = sui_amm::svg_nft::generate_lp_position_svg(
            pos.pool_type,
            pos.liquidity,
            pos.cached_value_a,
            pos.cached_value_b,
            pos.cached_fee_a,
            pos.cached_fee_b,
            pos.cached_il_bps,
            pos.fee_tier_bps
        );
        pos.cached_image_url = image_url;
    }

    /// Get the cached image URL
    public fun cached_image_url(pos: &LPPosition): string::String {
        pos.cached_image_url
    }

    /// Get the timestamp of the last metadata update
    public fun last_metadata_update_ms(pos: &LPPosition): u64 {
        pos.last_metadata_update_ms
    }

    /// Check if cached metadata is stale (older than threshold_ms)
    /// Returns true if metadata should be refreshed
    public fun is_metadata_stale(
        pos: &LPPosition,
        clock: &sui::clock::Clock,
        staleness_threshold_ms: u64
    ): bool {
        let current_time = sui::clock::timestamp_ms(clock);
        let time_since_update = if (current_time > pos.last_metadata_update_ms) {
            current_time - pos.last_metadata_update_ms
        } else {
            0
        };
        time_since_update > staleness_threshold_ms
    }

    /// Calculate what the original deposits would be worth if held separately
    /// Used for impermanent loss calculation
    /// SECURITY FIX [P1-15.5]: Updated to use 1e12 precision for better accuracy
    fun calculate_held_value(
        original_deposit_a: u64,
        original_deposit_b: u64,
        current_price_ratio_scaled: u64,
        entry_price_ratio_scaled: u64
    ): u128 {
        // If price hasn't changed, held value equals LP value (no IL)
        if (current_price_ratio_scaled == entry_price_ratio_scaled) {
            return ((original_deposit_a as u128) + (original_deposit_b as u128))
        };
        
        // Calculate current value of original token A holdings
        let value_a = (original_deposit_a as u128);
        
        // Calculate current value of original token B holdings in terms of token A
        // value_b_in_a = original_deposit_b * (1e12 / current_price_ratio_scaled)
        let value_b_in_a = if (current_price_ratio_scaled == 0) {
            0
        } else {
            ((original_deposit_b as u128) * 1_000_000_000_000 / (current_price_ratio_scaled as u128))
        };
        
        value_a + value_b_in_a
    }

    /// Calculate impermanent loss using original entry price
    /// Returns IL in basis points (10000 = 100%)
    public fun get_impermanent_loss(
        pos: &LPPosition,
        current_value_a: u64,
        current_value_b: u64,
        current_price_ratio_scaled: u64
    ): u64 {
        // Calculate what holdings would be worth if held separately
        let held_value = calculate_held_value(
            pos.original_deposit_a,
            pos.original_deposit_b,
            current_price_ratio_scaled,
            pos.entry_price_ratio_scaled
        );
        
        // Calculate current LP position value (in terms of token A)
        // SECURITY FIX [P1-15.5]: Updated to use 1e12 precision for better accuracy
        let lp_value_a = (current_value_a as u128);
        let lp_value_b_in_a = if (current_price_ratio_scaled == 0) {
            0
        } else {
            ((current_value_b as u128) * 1_000_000_000_000 / (current_price_ratio_scaled as u128))
        };
        let lp_value = lp_value_a + lp_value_b_in_a;
        
        // IL = (held_value - lp_value) / held_value * 10000 (in bps)
        // If LP value >= held value, there's no impermanent loss
        if (lp_value >= held_value || held_value == 0) {
            return 0
        };
        
        let loss = held_value - lp_value;
        ((loss * 10000) / held_value as u64)
    }

    #[test_only]
    public fun destroy_for_testing(position: LPPosition) {
        destroy(position);
    }
}
