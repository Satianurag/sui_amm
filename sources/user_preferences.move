/// Module: user_preferences
/// Description: Stores user preferences for slippage tolerance and other settings.
/// This satisfies PRD requirement: "Set slippage tolerance preferences"
module sui_amm::user_preferences {
    use sui::event;

    // Error codes
    const EInvalidSlippage: u64 = 0;
    const EInvalidDeadline: u64 = 1;

    // Constants
    const MAX_SLIPPAGE_BPS: u64 = 5000; // 50% max slippage tolerance
    const DEFAULT_SLIPPAGE_BPS: u64 = 50; // 0.5% default
    const DEFAULT_DEADLINE_SECONDS: u64 = 1200; // 20 minutes default
    const MIN_DEADLINE_SECONDS: u64 = 60; // 1 minute minimum
    const MAX_DEADLINE_SECONDS: u64 = 86400; // 24 hours maximum

    /// User preferences object - owned by user
    public struct UserPreferences has key, store {
        id: object::UID,
        owner: address,
        /// Default slippage tolerance in basis points (e.g., 50 = 0.5%)
        default_slippage_bps: u64,
        /// Default transaction deadline in seconds from submission
        default_deadline_seconds: u64,
        /// Whether to auto-compound fees when claiming
        auto_compound: bool,
        /// Maximum price impact tolerance in basis points
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

    /// Create default user preferences
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

    /// Create and transfer preferences to recipient
    public fun create_and_transfer(recipient: address, ctx: &mut tx_context::TxContext) {
        let prefs = create_preferences(ctx);
        transfer::transfer(prefs, recipient);
    }

    /// Update slippage tolerance
    public fun set_slippage_tolerance(
        prefs: &mut UserPreferences,
        slippage_bps: u64
    ) {
        assert!(slippage_bps <= MAX_SLIPPAGE_BPS, EInvalidSlippage);
        prefs.default_slippage_bps = slippage_bps;
    }

    /// Update deadline preference
    public fun set_deadline(
        prefs: &mut UserPreferences,
        deadline_seconds: u64
    ) {
        assert!(deadline_seconds >= MIN_DEADLINE_SECONDS, EInvalidDeadline);
        assert!(deadline_seconds <= MAX_DEADLINE_SECONDS, EInvalidDeadline);
        prefs.default_deadline_seconds = deadline_seconds;
    }

    /// Update auto-compound preference
    public fun set_auto_compound(
        prefs: &mut UserPreferences,
        auto_compound: bool
    ) {
        prefs.auto_compound = auto_compound;
    }

    /// Update max price impact tolerance
    public fun set_max_price_impact(
        prefs: &mut UserPreferences,
        max_price_impact_bps: u64
    ) {
        assert!(max_price_impact_bps <= MAX_SLIPPAGE_BPS, EInvalidSlippage);
        prefs.max_price_impact_bps = max_price_impact_bps;
    }

    /// Update all preferences at once
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

    // View functions
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

    /// Calculate minimum output based on expected output and user's slippage tolerance
    public fun calculate_min_output(
        prefs: &UserPreferences,
        expected_output: u64
    ): u64 {
        let slippage_amount = (expected_output * prefs.default_slippage_bps) / 10000;
        if (slippage_amount >= expected_output) {
            0
        } else {
            expected_output - slippage_amount
        }
    }

    /// Calculate deadline timestamp from current time
    public fun calculate_deadline_ms(
        prefs: &UserPreferences,
        current_time_ms: u64
    ): u64 {
        current_time_ms + (prefs.default_deadline_seconds * 1000)
    }

    // Constants getters for clients
    public fun max_slippage_bps(): u64 { MAX_SLIPPAGE_BPS }
    public fun default_slippage_bps(): u64 { DEFAULT_SLIPPAGE_BPS }
    public fun default_deadline_seconds(): u64 { DEFAULT_DEADLINE_SECONDS }
    public fun min_deadline_seconds(): u64 { MIN_DEADLINE_SECONDS }
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
