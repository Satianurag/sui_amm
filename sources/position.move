/// Implementation of the LPPosition NFT requirement.
/// 
/// This module manages the LPPosition struct which represents a user's liquidity position,
/// tracks fees, and stores metadata for dynamic NFT display.
/// 
/// # Overview
/// 
/// LP Position NFTs are dynamic NFTs that represent a user's share in a liquidity pool.
/// Unlike static NFTs, these NFTs display real-time information about the position's value,
/// accumulated fees, and impermanent loss.
/// 
/// # Key Features
/// 
/// - **Dynamic Display**: NFT metadata updates to reflect current position state
/// - **Fee Tracking**: Automatically tracks accumulated trading fees
/// - **Impermanent Loss**: Calculates IL based on entry price
/// - **On-Chain SVG**: Generates visual representation entirely on-chain
/// - **Staleness Detection**: Indicates when cached data needs refresh
/// 
/// # Usage Examples
/// 
/// ## Creating a Position
/// ```move
/// // Add liquidity to get a position NFT
/// let (position, refund_a, refund_b) = pool::add_liquidity(
///     &mut pool,
///     coin_a,
///     coin_b,
///     min_liquidity,
///     &clock,
///     deadline,
///     ctx
/// );
/// 
/// // Position is now owned by the sender
/// transfer::public_transfer(position, sender);
/// ```
/// 
/// ## Checking Position Value
/// ```move
/// // Get real-time position view
/// let view = pool::get_position_view(&pool, &position);
/// let (value_a, value_b) = position::view_value(&view);
/// let (fees_a, fees_b) = position::view_fees(&view);
/// 
/// // Or get comprehensive display data
/// let display_data = pool::get_nft_display_data(
///     &pool,
///     &position,
///     &clock,
///     3_600_000  // 1 hour staleness threshold
/// );
/// ```
/// 
/// ## Auto-Compounding Fees
/// ```move
/// // Reinvest accumulated fees back into position
/// let liquidity_increase = pool::auto_compound_fees(
///     &mut pool,
///     &mut position,
///     min_liquidity_increase,
///     &clock,
///     deadline,
///     ctx
/// );
/// 
/// // Position now has more liquidity shares
/// ```
/// 
/// ## Refreshing Metadata
/// ```move
/// // Check if metadata is stale
/// if (position::is_metadata_stale(&position, &clock, 3_600_000)) {
///     // Refresh to update cached values and SVG
///     pool::refresh_position_metadata(&pool, &mut position, &clock);
/// };
/// ```
/// 
/// ## Removing Liquidity
/// ```move
/// // Remove all liquidity
/// let (coin_a, coin_b) = pool::remove_liquidity(
///     &mut pool,
///     position,  // Position is consumed
///     min_amount_a,
///     min_amount_b,
///     &clock,
///     deadline,
///     ctx
/// );
/// 
/// // Or remove partial liquidity
/// let (coin_a, coin_b) = pool::remove_liquidity_partial(
///     &mut pool,
///     &mut position,  // Position is modified, not consumed
///     liquidity_to_remove,
///     min_amount_a,
///     min_amount_b,
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// # Metadata Staleness
/// 
/// NFT metadata (cached values) is NOT automatically updated on every swap to save gas.
/// This is an intentional design decision for gas efficiency.
/// 
/// **Metadata is automatically refreshed on:**
/// - `add_liquidity()` - Initial creation
/// - `increase_liquidity()` - Adding more liquidity
/// - `remove_liquidity_partial()` - Partial removal
/// - `withdraw_fees()` - Fee withdrawal
/// - `auto_compound_fees()` - Auto-compounding
/// 
/// **Metadata is NOT automatically refreshed on:**
/// - Pool swaps by other users
/// - Time passing
/// 
/// **For real-time data:**
/// - Use `get_position_view()` which computes values on-demand
/// - Use `get_nft_display_data()` which includes both real-time and cached values
/// 
/// **To manually refresh:**
/// - Call `refresh_position_metadata()` before listing on marketplaces
/// - Call when `is_metadata_stale()` returns true
/// 
/// # Staleness Threshold Recommendations
/// 
/// - **High-frequency trading**: 60,000 ms (1 minute)
/// - **Active monitoring**: 300,000 ms (5 minutes)
/// - **Casual viewing**: 3,600,000 ms (1 hour)
/// - **Marketplace listings**: 86,400,000 ms (24 hours) - Use MAX_STALENESS_THRESHOLD
/// 
/// # Important Notes
/// 
/// - Position NFTs are transferable and can be traded on marketplaces
/// - Cached values may be stale - always check staleness or use real-time values
/// - Impermanent loss is calculated relative to entry price
/// - Fee debt prevents double-claiming of fees
/// - SVG images are generated entirely on-chain
/// 
module sui_amm::position {
    use std::string;
    use sui::package;
    use sui::display;

    // Error codes
    const EInsufficientLiquidity: u64 = 0;
    const EPrecisionLoss: u64 = 1;

    // Constants
    /// Maximum recommended staleness threshold: 24 hours in milliseconds
    /// Used to determine when cached NFT metadata should be refreshed
    /// Positions with metadata older than this threshold should call refresh_position_metadata()
    /// This constant is provided as a reference for client applications
    #[allow(unused_const)]
    const MAX_STALENESS_THRESHOLD: u64 = 86400000; // 24 hours in ms

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

    /// Comprehensive NFT display data structure for wallet and marketplace integration
    /// 
    /// This struct provides all information needed to display an LP Position NFT in a single query.
    /// It combines real-time calculated values with cached metadata, allowing clients to choose
    /// between accuracy (real-time) and gas efficiency (cached).
    /// 
    /// # Usage Example
    /// ```move
    /// // Get display data with 1 hour staleness threshold
    /// let display_data = pool::get_nft_display_data(
    ///     &pool,
    ///     &position,
    ///     &clock,
    ///     3600000  // 1 hour in milliseconds
    /// );
    /// 
    /// // Check if metadata needs refresh
    /// if (position::display_is_stale(&display_data)) {
    ///     // Prompt user to refresh metadata
    ///     pool::refresh_position_metadata(&pool, &mut position, &clock);
    /// };
    /// 
    /// // Display current values (always accurate)
    /// let (value_a, value_b) = (
    ///     position::display_current_value_a(&display_data),
    ///     position::display_current_value_b(&display_data)
    /// );
    /// ```
    /// 
    /// # Field Categories
    /// 
    /// ## Identity Fields
    /// - `position_id`: Unique identifier of the position NFT
    /// - `pool_id`: Pool this position belongs to
    /// 
    /// ## Basic Information
    /// - `name`: Display name (e.g., "Sui AMM LP Position")
    /// - `description`: Human-readable description
    /// - `pool_type`: "Standard" or "Stable"
    /// - `fee_tier_bps`: Fee tier in basis points (e.g., 30 = 0.3%)
    /// 
    /// ## Position Size
    /// - `liquidity_shares`: Number of LP shares owned
    /// 
    /// ## Real-Time Values (Always Current)
    /// These values are calculated on-demand from the pool state:
    /// - `current_value_a`: Current token A amount in position
    /// - `current_value_b`: Current token B amount in position
    /// - `pending_fees_a`: Unclaimed fees in token A
    /// - `pending_fees_b`: Unclaimed fees in token B
    /// - `impermanent_loss_bps`: Current IL in basis points (10000 = 100%)
    /// 
    /// ## Entry Tracking
    /// Used for impermanent loss calculation:
    /// - `original_deposit_a`: Initial deposit amount in token A
    /// - `original_deposit_b`: Initial deposit amount in token B
    /// - `entry_price_ratio_scaled`: Price ratio at position creation (scaled by 1e12)
    /// 
    /// ## Cached Values (May Be Stale)
    /// These values are stored in the NFT and updated only when refresh_position_metadata() is called:
    /// - `cached_value_a`: Last cached token A amount
    /// - `cached_value_b`: Last cached token B amount
    /// - `cached_fee_a`: Last cached fees in token A
    /// - `cached_fee_b`: Last cached fees in token B
    /// - `cached_il_bps`: Last cached impermanent loss
    /// 
    /// ## Display
    /// - `image_url`: Base64-encoded SVG data URI (e.g., "data:image/svg+xml;base64,...")
    /// 
    /// ## Staleness Tracking
    /// - `is_stale`: True if cached data exceeds staleness_threshold_ms
    /// - `last_update_ms`: Timestamp of last metadata refresh (milliseconds since epoch)
    /// - `staleness_threshold_ms`: Threshold used for staleness check
    /// 
    /// # Staleness Recommendations
    /// 
    /// Recommended staleness thresholds based on use case:
    /// - **High-frequency trading**: 60,000 ms (1 minute)
    /// - **Active monitoring**: 300,000 ms (5 minutes)
    /// - **Casual viewing**: 3,600,000 ms (1 hour)
    /// - **Marketplace listings**: 86,400,000 ms (24 hours)
    /// 
    /// The constant `MAX_STALENESS_THRESHOLD` (24 hours) is provided as a reference.
    /// 
    /// Requirements: 2.1, 2.2
    public struct NFTDisplayData has copy, drop {
        // Identity
        position_id: ID,
        pool_id: ID,
        
        // Basic Info
        name: string::String,
        description: string::String,
        pool_type: string::String,
        fee_tier_bps: u64,
        
        // Position Size
        liquidity_shares: u64,
        
        // Current Values (real-time)
        current_value_a: u64,
        current_value_b: u64,
        
        // Fees (real-time)
        pending_fees_a: u64,
        pending_fees_b: u64,
        
        // Impermanent Loss (real-time)
        impermanent_loss_bps: u64,
        
        // Entry Tracking
        original_deposit_a: u64,
        original_deposit_b: u64,
        entry_price_ratio_scaled: u64,
        
        // Cached Values (may be stale)
        cached_value_a: u64,
        cached_value_b: u64,
        cached_fee_a: u64,
        cached_fee_b: u64,
        cached_il_bps: u64,
        
        // Display
        image_url: string::String,
        
        // Staleness
        is_stale: bool,
        last_update_ms: u64,
        staleness_threshold_ms: u64,
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

    public fun get_id(pos: &LPPosition): ID { object::uid_to_inner(&pos.id) }
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
        
        // FIX [IL Tracking]: Update original deposits to track total HODL value
        // We must track the total amount deposited to correctly calculate IL
        // (Held Value vs LP Value)
        pos.original_deposit_a = pos.original_deposit_a + amount_a;
        pos.original_deposit_b = pos.original_deposit_b + amount_b;
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
        assert!(liquidity_amount <= pos.liquidity, EInsufficientLiquidity);
        
        let original_liquidity = pos.liquidity;
        pos.liquidity = pos.liquidity - liquidity_amount;
        
        // Proportionally decrease min amounts using u128 to prevent precision loss
        if (pos.liquidity == 0) {
            // Complete removal - zero everything
            pos.min_a = 0;
            pos.min_b = 0;
            pos.original_deposit_a = 0;
            pos.original_deposit_b = 0;
        } else {
            // Partial removal - reduce min_a and min_b proportionally
            // Formula: new_min = old_min * remaining_liquidity / original_liquidity
            // Using u128 to prevent any precision loss
            let new_min_a = ((pos.min_a as u128) * (pos.liquidity as u128) / (original_liquidity as u128) as u64);
            let new_min_b = ((pos.min_b as u128) * (pos.liquidity as u128) / (original_liquidity as u128) as u64);
            
            // Also reduce original_deposit_a/b proportionally to maintain correct IL tracking
            let new_original_a = ((pos.original_deposit_a as u128) * (pos.liquidity as u128) / (original_liquidity as u128) as u64);
            let new_original_b = ((pos.original_deposit_b as u128) * (pos.liquidity as u128) / (original_liquidity as u128) as u64);
            
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
            assert!(actual_ratio_a >= expected_ratio - 1 && actual_ratio_a <= expected_ratio + 1, EPrecisionLoss);
            assert!(actual_ratio_b >= expected_ratio - 1 && actual_ratio_b <= expected_ratio + 1, EPrecisionLoss);
            
            pos.min_a = new_min_a;
            pos.min_b = new_min_b;
            pos.original_deposit_a = new_original_a;
            pos.original_deposit_b = new_original_b;
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

    /// Update only the timestamp without changing cached values
    /// Used by refresh_position_metadata when values haven't changed but staleness tracking needs update
    public(package) fun touch_metadata_timestamp(
        pos: &mut LPPosition,
        clock: &sui::clock::Clock,
    ) {
        pos.last_metadata_update_ms = sui::clock::timestamp_ms(clock);
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
    /// 
    /// Requirements: 2.4 - Regenerate SVG image on metadata refresh
    /// This function is called by:
    /// - update_cached_values() when cached values are updated
    /// - refresh_position_metadata() to ensure SVG is always current
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

    /// Get enhanced staleness information
    /// Returns (is_stale, age_ms) tuple
    /// 
    /// This function provides comprehensive staleness detection by:
    /// - Using is_metadata_stale() internally for consistency
    /// - Calculating the age of cached data in milliseconds
    /// - Handling edge case where last_update_ms is 0 (never updated)
    /// 
    /// When last_metadata_update_ms is 0, the position has never been updated,
    /// so we return the maximum possible age (u64::MAX) to indicate extreme staleness.
    public fun get_staleness_info(
        pos: &LPPosition,
        clock: &sui::clock::Clock,
        staleness_threshold_ms: u64
    ): (bool, u64) {
        let is_stale = is_metadata_stale(pos, clock, staleness_threshold_ms);
        
        let current_time = sui::clock::timestamp_ms(clock);
        let age_ms = if (pos.last_metadata_update_ms == 0) {
            // Never updated - return maximum age to indicate extreme staleness
            18446744073709551615 // u64::MAX
        } else if (current_time > pos.last_metadata_update_ms) {
            current_time - pos.last_metadata_update_ms
        } else {
            // Clock went backwards or same time - age is 0
            0
        };
        
        (is_stale, age_ms)
    }

    /// Calculate what the original deposits would be worth if held separately
    /// Used for impermanent loss calculation
    /// SECURITY FIX [P1-15.5]: Updated to use 1e12 precision for better accuracy
    fun calculate_held_value(
        original_deposit_a: u64,
        original_deposit_b: u64,
        current_price_ratio_scaled: u64,
        _entry_price_ratio_scaled: u64
    ): u128 {
        // FIX [IL Calculation]: Removed incorrect optimization that returned sum of raw amounts
        // We must always calculate value in terms of Token A to be correct
        
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

    /// Build NFTDisplayData from position and real-time view
    /// This is a package-level function to be called by pool module
    public(package) fun make_nft_display_data(
        position: &LPPosition,
        position_view: &PositionView,
        clock: &sui::clock::Clock,
        staleness_threshold_ms: u64,
    ): NFTDisplayData {
        let current_time = sui::clock::timestamp_ms(clock);
        let time_since_update = if (current_time > position.last_metadata_update_ms) {
            current_time - position.last_metadata_update_ms
        } else {
            0
        };
        let is_stale = time_since_update > staleness_threshold_ms;

        NFTDisplayData {
            position_id: object::uid_to_inner(&position.id),
            pool_id: position.pool_id,
            name: position.name,
            description: position.description,
            pool_type: position.pool_type,
            fee_tier_bps: position.fee_tier_bps,
            liquidity_shares: position.liquidity,
            current_value_a: position_view.value_a,
            current_value_b: position_view.value_b,
            pending_fees_a: position_view.pending_fee_a,
            pending_fees_b: position_view.pending_fee_b,
            impermanent_loss_bps: position_view.il_bps,
            original_deposit_a: position.original_deposit_a,
            original_deposit_b: position.original_deposit_b,
            entry_price_ratio_scaled: position.entry_price_ratio_scaled,
            cached_value_a: position.cached_value_a,
            cached_value_b: position.cached_value_b,
            cached_fee_a: position.cached_fee_a,
            cached_fee_b: position.cached_fee_b,
            cached_il_bps: position.cached_il_bps,
            image_url: position.cached_image_url,
            is_stale,
            last_update_ms: position.last_metadata_update_ms,
            staleness_threshold_ms,
        }
    }

    // Getter functions for NFTDisplayData
    public fun display_position_id(data: &NFTDisplayData): ID { data.position_id }
    public fun display_pool_id(data: &NFTDisplayData): ID { data.pool_id }
    public fun display_name(data: &NFTDisplayData): string::String { data.name }
    public fun display_description(data: &NFTDisplayData): string::String { data.description }
    public fun display_pool_type(data: &NFTDisplayData): string::String { data.pool_type }
    public fun display_fee_tier_bps(data: &NFTDisplayData): u64 { data.fee_tier_bps }
    public fun display_liquidity_shares(data: &NFTDisplayData): u64 { data.liquidity_shares }
    public fun display_current_value_a(data: &NFTDisplayData): u64 { data.current_value_a }
    public fun display_current_value_b(data: &NFTDisplayData): u64 { data.current_value_b }
    public fun display_pending_fees_a(data: &NFTDisplayData): u64 { data.pending_fees_a }
    public fun display_pending_fees_b(data: &NFTDisplayData): u64 { data.pending_fees_b }
    public fun display_impermanent_loss_bps(data: &NFTDisplayData): u64 { data.impermanent_loss_bps }
    public fun display_original_deposit_a(data: &NFTDisplayData): u64 { data.original_deposit_a }
    public fun display_original_deposit_b(data: &NFTDisplayData): u64 { data.original_deposit_b }
    public fun display_entry_price_ratio_scaled(data: &NFTDisplayData): u64 { data.entry_price_ratio_scaled }
    public fun display_cached_value_a(data: &NFTDisplayData): u64 { data.cached_value_a }
    public fun display_cached_value_b(data: &NFTDisplayData): u64 { data.cached_value_b }
    public fun display_cached_fee_a(data: &NFTDisplayData): u64 { data.cached_fee_a }
    public fun display_cached_fee_b(data: &NFTDisplayData): u64 { data.cached_fee_b }
    public fun display_cached_il_bps(data: &NFTDisplayData): u64 { data.cached_il_bps }
    public fun display_image_url(data: &NFTDisplayData): string::String { data.image_url }
    public fun display_is_stale(data: &NFTDisplayData): bool { data.is_stale }
    public fun display_last_update_ms(data: &NFTDisplayData): u64 { data.last_update_ms }
    public fun display_staleness_threshold_ms(data: &NFTDisplayData): u64 { data.staleness_threshold_ms }

    // ═══════════════════════════════════════════════════════════════════════════
    // Display Formatting Helper Functions
    // These are optional convenience functions for clients to format display data
    // Requirements: 2.1 - Comprehensive NFT Display Data
    // ═══════════════════════════════════════════════════════════════════════════

    /// Format liquidity shares for human-readable display
    /// Example: 1000000 -> "1,000,000 shares"
    public fun format_liquidity_display(liquidity: u64): string::String {
        let mut formatted = sui_amm::string_utils::format_with_commas(liquidity);
        string::append(&mut formatted, string::utf8(b" shares"));
        formatted
    }

    /// Format impermanent loss for display as percentage
    /// Input is in basis points (10000 = 100%)
    /// Example: 250 bps -> "2.50%"
    public fun format_il_display(il_bps: u64): string::String {
        let mut formatted = sui_amm::string_utils::format_decimal(il_bps, 2);
        string::append(&mut formatted, string::utf8(b"%"));
        formatted
    }

    /// Format timestamp for display
    /// Converts milliseconds since epoch to human-readable format
    /// Example: 1609459200000 -> "1,609,459,200,000 ms"
    /// Note: Clients should convert this to their preferred date format
    public fun format_timestamp(timestamp_ms: u64): string::String {
        let mut formatted = sui_amm::string_utils::format_with_commas(timestamp_ms);
        string::append(&mut formatted, string::utf8(b" ms"));
        formatted
    }

    #[test_only]
    public fun destroy_for_testing(position: LPPosition) {
        destroy(position);
    }
}
