/// User preference management for trading parameters
///
/// This module allows users to store and manage their trading preferences including
/// slippage tolerance, transaction deadlines, auto-compounding settings, and price
/// impact limits. Preferences are stored in owned objects that users can update
/// at any time.
///
/// Default values are provided for all settings, with validation to ensure values
/// stay within safe ranges.
module sui_amm::user_preferences {
    use sui::event;

    // Error codes
    const EInvalidSlippage: u64 = 0;
    const EInvalidDeadline: u64 = 1;

    // Preference limits and defaults
    const MAX_SLIPPAGE_BPS: u64 = 5000;        // 50% maximum (very high, for edge cases)
    const DEFAULT_SLIPPAGE_BPS: u64 = 50;      // 0.5% default (reasonable for most trades)
    const DEFAULT_DEADLINE_SECONDS: u64 = 1200; // 20 minutes default
    const MIN_DEADLINE_SECONDS: u64 = 60;      // 1 minute minimum
    const MAX_DEADLINE_SECONDS: u64 = 86400;   // 24 hours maximum

    /// User's trading preferences
    ///
    /// Owned object storing customizable trading parameters. Users can update
    /// these values at any time to match their risk tolerance and trading style.
    public struct UserPreferences has key, store {
        id: object::UID,
        owner: address,
        /// Slippage tolerance in basis points (e.g., 50 = 0.5%)
        default_slippage_bps: u64,
        /// Transaction deadline in seconds from submission
        default_deadline_seconds: u64,
        /// Whether to automatically reinvest fees when claiming
        auto_compound: bool,
        /// Maximum acceptable price impact in basis points
        max_price_impact_bps: u64,
    }

    // Events
    public struct PreferencesCreated has copy, drop {
        owner: address,
        default_slippage_bps: u64,
        default_deadline_seconds: u64,
    }

    public struct PreferencesUpdated has copy, drop {
        owner: address,
        default_slippage_bps: u64,
        default_deadline_seconds: u64,
        auto_compound: bool,
        max_price_impact_bps: u64,
    }

    /// Create a new preferences object with default values
    ///
    /// Initializes preferences with conservative defaults suitable for most users.
    /// Users can update these values later based on their risk tolerance.
    ///
    /// # Returns
    /// New UserPreferences object with default settings
    public fun create_preferences(ctx: &mut tx_context::TxContext): UserPreferences {
        let owner = tx_context::sender(ctx);
        
        event::emit(PreferencesCreated {
            owner,
            default_slippage_bps: DEFAULT_SLIPPAGE_BPS,
            default_deadline_seconds: DEFAULT_DEADLINE_SECONDS,
        });

        UserPreferences {
            id: object::new(ctx),
            owner,
            default_slippage_bps: DEFAULT_SLIPPAGE_BPS,
            default_deadline_seconds: DEFAULT_DEADLINE_SECONDS,
            auto_compound: false,
            max_price_impact_bps: 1000, // 10% default
        }
    }

    /// Create preferences and transfer to a specific recipient
    ///
    /// Convenience function for creating preference objects for other users.
    public fun create_and_transfer(recipient: address, ctx: &mut tx_context::TxContext) {
        let prefs = create_preferences(ctx);
        transfer::transfer(prefs, recipient);
    }

    /// Update the default slippage tolerance
    ///
    /// Sets the maximum acceptable slippage for trades. Lower values provide
    /// better price protection but may cause more transaction failures.
    ///
    /// # Parameters
    /// - `prefs`: The preferences object to update
    /// - `slippage_bps`: New slippage tolerance in basis points (0-5000)
    ///
    /// # Aborts
    /// - `EInvalidSlippage`: If slippage_bps exceeds MAX_SLIPPAGE_BPS
    public fun set_slippage_tolerance(
        prefs: &mut UserPreferences,
        slippage_bps: u64
    ) {
        assert!(slippage_bps <= MAX_SLIPPAGE_BPS, EInvalidSlippage);
        prefs.default_slippage_bps = slippage_bps;
    }

    /// Update the default transaction deadline
    ///
    /// Sets how long transactions remain valid before expiring. Shorter deadlines
    /// provide better protection against stale prices but require faster execution.
    ///
    /// # Parameters
    /// - `prefs`: The preferences object to update
    /// - `deadline_seconds`: New deadline in seconds (60-86400)
    ///
    /// # Aborts
    /// - `EInvalidDeadline`: If deadline is outside valid range
    public fun set_deadline(
        prefs: &mut UserPreferences,
        deadline_seconds: u64
    ) {
        assert!(deadline_seconds >= MIN_DEADLINE_SECONDS, EInvalidDeadline);
        assert!(deadline_seconds <= MAX_DEADLINE_SECONDS, EInvalidDeadline);
        prefs.default_deadline_seconds = deadline_seconds;
    }

    /// Update the auto-compound preference
    ///
    /// When enabled, accumulated fees are automatically reinvested into the
    /// liquidity position when claiming, maximizing compound growth.
    ///
    /// # Parameters
    /// - `prefs`: The preferences object to update
    /// - `auto_compound`: true to enable auto-compounding, false to disable
    public fun set_auto_compound(
        prefs: &mut UserPreferences,
        auto_compound: bool
    ) {
        prefs.auto_compound = auto_compound;
    }

    /// Update the maximum acceptable price impact
    ///
    /// Prevents trades that would move the price too much, protecting against
    /// unfavorable execution in low-liquidity conditions.
    ///
    /// # Parameters
    /// - `prefs`: The preferences object to update
    /// - `max_price_impact_bps`: Maximum price impact in basis points (0-5000)
    ///
    /// # Aborts
    /// - `EInvalidSlippage`: If max_price_impact_bps exceeds MAX_SLIPPAGE_BPS
    public fun set_max_price_impact(
        prefs: &mut UserPreferences,
        max_price_impact_bps: u64
    ) {
        assert!(max_price_impact_bps <= MAX_SLIPPAGE_BPS, EInvalidSlippage);
        prefs.max_price_impact_bps = max_price_impact_bps;
    }

    /// Update all preferences in a single transaction
    ///
    /// Convenience function for updating multiple preferences atomically.
    /// Validates all parameters before applying any changes.
    ///
    /// # Parameters
    /// - `prefs`: The preferences object to update
    /// - `slippage_bps`: New slippage tolerance (0-5000)
    /// - `deadline_seconds`: New deadline (60-86400)
    /// - `auto_compound`: New auto-compound setting
    /// - `max_price_impact_bps`: New max price impact (0-5000)
    /// - `ctx`: Transaction context
    ///
    /// # Aborts
    /// - `EInvalidSlippage`: If slippage or price impact exceeds limits
    /// - `EInvalidDeadline`: If deadline is outside valid range
    public fun update_all(
        prefs: &mut UserPreferences,
        slippage_bps: u64,
        deadline_seconds: u64,
        auto_compound: bool,
        max_price_impact_bps: u64,
        ctx: &mut TxContext
    ) {
        assert!(slippage_bps <= MAX_SLIPPAGE_BPS, EInvalidSlippage);
        assert!(deadline_seconds >= MIN_DEADLINE_SECONDS, EInvalidDeadline);
        assert!(deadline_seconds <= MAX_DEADLINE_SECONDS, EInvalidDeadline);
        assert!(max_price_impact_bps <= MAX_SLIPPAGE_BPS, EInvalidSlippage);

        prefs.default_slippage_bps = slippage_bps;
        prefs.default_deadline_seconds = deadline_seconds;
        prefs.auto_compound = auto_compound;
        prefs.max_price_impact_bps = max_price_impact_bps;

        event::emit(PreferencesUpdated {
            owner: tx_context::sender(ctx),
            default_slippage_bps: slippage_bps,
            default_deadline_seconds: deadline_seconds,
            auto_compound,
            max_price_impact_bps,
        });
    }

    // ============ View Functions ============
    // These functions provide read-only access to preference values

    public fun get_slippage_tolerance(prefs: &UserPreferences): u64 {
        prefs.default_slippage_bps
    }

    public fun get_deadline(prefs: &UserPreferences): u64 {
        prefs.default_deadline_seconds
    }

    public fun get_auto_compound(prefs: &UserPreferences): bool {
        prefs.auto_compound
    }

    public fun get_max_price_impact(prefs: &UserPreferences): u64 {
        prefs.max_price_impact_bps
    }

    public fun get_owner(prefs: &UserPreferences): address {
        prefs.owner
    }

    /// Calculate minimum acceptable output based on slippage tolerance
    ///
    /// Applies the user's slippage tolerance to an expected output amount to
    /// determine the minimum acceptable amount. Used for slippage protection
    /// in swap transactions.
    ///
    /// # Parameters
    /// - `prefs`: The user's preferences
    /// - `expected_output`: The expected output amount
    ///
    /// # Returns
    /// Minimum acceptable output (expected_output * (1 - slippage_tolerance))
    ///
    /// # Examples
    /// - With 0.5% slippage and expected output of 1000: returns 995
    /// - With 1% slippage and expected output of 1000: returns 990
    public fun calculate_min_output(
        prefs: &UserPreferences,
        expected_output: u64
    ): u64 {
        let slippage_amount = (expected_output * prefs.default_slippage_bps) / 10000;
        // Handle edge case where slippage would exceed output (shouldn't happen with valid settings)
        if (slippage_amount >= expected_output) {
            0
        } else {
            expected_output - slippage_amount
        }
    }

    /// Calculate absolute deadline timestamp from current time
    ///
    /// Converts the user's deadline preference (in seconds) to an absolute
    /// timestamp by adding it to the current time.
    ///
    /// # Parameters
    /// - `prefs`: The user's preferences
    /// - `current_time_ms`: Current timestamp in milliseconds
    ///
    /// # Returns
    /// Absolute deadline timestamp in milliseconds
    public fun calculate_deadline_ms(
        prefs: &UserPreferences,
        current_time_ms: u64
    ): u64 {
        current_time_ms + (prefs.default_deadline_seconds * 1000)
    }

    // ============ Constant Getters ============
    // These functions expose module constants for client applications

    /// Get the maximum allowed slippage tolerance
    public fun max_slippage_bps(): u64 { MAX_SLIPPAGE_BPS }
    
    /// Get the default slippage tolerance
    public fun default_slippage_bps(): u64 { DEFAULT_SLIPPAGE_BPS }
    
    /// Get the default deadline duration
    public fun default_deadline_seconds(): u64 { DEFAULT_DEADLINE_SECONDS }
    
    /// Get the minimum allowed deadline
    public fun min_deadline_seconds(): u64 { MIN_DEADLINE_SECONDS }
    
    /// Get the maximum allowed deadline
    public fun max_deadline_seconds(): u64 { MAX_DEADLINE_SECONDS }

    #[test_only]
    public fun create_for_testing(ctx: &mut tx_context::TxContext): UserPreferences {
        create_preferences(ctx)
    }

    #[test_only]
    public fun destroy_for_testing(prefs: UserPreferences) {
        let UserPreferences {
            id,
            owner: _,
            default_slippage_bps: _,
            default_deadline_seconds: _,
            auto_compound: _,
            max_price_impact_bps: _,
        } = prefs;
        object::delete(id);
    }
}
