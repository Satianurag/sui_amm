/// Admin module for protocol management and emergency controls
///
/// This module provides administrative functions for the AMM protocol, including:
/// - Protocol fee withdrawal
/// - Emergency pause/unpause controls
/// - Stable pool amplification coefficient management
///
/// # Access Control
/// All administrative functions require the AdminCap capability, which is created
/// during module initialization and transferred to the deployer. This ensures only
/// authorized addresses can perform privileged operations.
///
/// # Security Model
/// The admin module follows a defense-in-depth approach:
/// - Critical parameter changes (fees, risk parameters) require governance proposals with timelock
/// - Emergency pause functions are available for immediate response to threats
/// - AdminCap is a non-transferable capability that must be carefully managed
module sui_amm::admin {
    use sui::coin;

    use sui_amm::pool;
    use sui_amm::stable_pool;

    /// Administrative capability for protocol management
    ///
    /// This capability grants access to privileged functions including fee withdrawal,
    /// emergency pause controls, and stable pool parameter adjustments. The capability
    /// is created once during module initialization and should be stored securely.
    ///
    /// # Security Considerations
    /// - Loss of AdminCap means permanent loss of administrative control
    /// - AdminCap should be stored in a multi-sig wallet or governance contract
    /// - Consider implementing time-delayed operations for critical changes
    public struct AdminCap has key {
        id: object::UID,
    }

    /// Initialize the admin module and create the administrative capability
    ///
    /// This function is called automatically when the module is published. It creates
    /// a single AdminCap and transfers it to the deployer address. This is the only
    /// time an AdminCap can be created, establishing the initial protocol administrator.
    ///
    /// # Parameters
    /// - `ctx`: Transaction context providing the deployer's address
    ///
    /// # Security Considerations
    /// The deployer address becomes the initial protocol administrator and should be
    /// a secure multi-sig wallet or governance contract, not an individual EOA.
    fun init(ctx: &mut tx_context::TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Withdraw accumulated protocol fees from a regular liquidity pool
    ///
    /// Protocol fees are collected from each swap and stored in the pool. This function
    /// allows the protocol administrator to withdraw these fees for treasury management,
    /// development funding, or distribution to governance token holders.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization (consumed by reference)
    /// - `pool`: The liquidity pool to withdraw fees from
    /// - `ctx`: Transaction context for creating coin objects
    ///
    /// # Returns
    /// A tuple of (CoinA, CoinB) containing the withdrawn protocol fees
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized fee withdrawal
    public fun withdraw_protocol_fees_from_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        sui_amm::pool::withdraw_protocol_fees(pool, ctx)
    }

    /// Withdraw accumulated protocol fees from a stable swap pool
    ///
    /// Similar to regular pools, stable swap pools accumulate protocol fees from each
    /// swap operation. This function allows the administrator to withdraw these fees.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The stable swap pool to withdraw fees from
    /// - `ctx`: Transaction context for creating coin objects
    ///
    /// # Returns
    /// A tuple of (CoinA, CoinB) containing the withdrawn protocol fees
    ///
    /// # Access Control
    /// Requires AdminCap to prevent unauthorized fee withdrawal
    public fun withdraw_protocol_fees_from_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        sui_amm::stable_pool::withdraw_protocol_fees(pool, ctx)
    }

    /// Initiate amplification coefficient ramping for a stable swap pool
    ///
    /// The amplification coefficient (amp) controls how "flat" the stable swap curve is.
    /// Higher amp values make the pool behave more like a constant-sum curve (better for
    /// stable pairs), while lower values behave more like constant-product curves.
    ///
    /// Ramping allows gradual adjustment of amp over time to prevent sudden price impacts.
    /// This is critical for maintaining pool stability and preventing arbitrage opportunities.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The stable swap pool to adjust
    /// - `target_amp`: The desired final amplification coefficient
    /// - `ramp_duration_ms`: Duration of the ramp in milliseconds (minimum 24 hours recommended)
    /// - `clock`: Clock object for timestamp validation
    ///
    /// # Security Considerations
    /// - Rapid amp changes can create arbitrage opportunities
    /// - Minimum ramp duration should be enforced to prevent manipulation
    /// - Consider governance approval for significant amp changes
    ///
    /// # Governance Integration
    /// Protocol fee changes and risk parameter updates must go through the governance
    /// module with a timelock. Direct setters have been removed to prevent unilateral
    /// parameter changes that could harm liquidity providers.
    public fun ramp_stable_pool_amp<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::ramp_amp(pool, target_amp, ramp_duration_ms, clock);
    }

    /// Stop an ongoing amplification coefficient ramp
    ///
    /// Immediately halts an in-progress amp ramp, freezing the amp value at its current
    /// level. This is useful if market conditions change or if the ramp is causing
    /// unexpected behavior.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The stable swap pool with an active ramp
    /// - `clock`: Clock object for timestamp validation
    ///
    /// # Use Cases
    /// - Emergency response to unexpected market volatility
    /// - Correcting an incorrectly configured ramp
    /// - Responding to governance decisions to halt parameter changes
    public fun stop_stable_pool_amp_ramp<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::stop_ramp_amp(pool, clock);
    }

    /// Pause a regular liquidity pool to prevent all trading activity
    ///
    /// Pausing a pool disables all swap, add liquidity, and remove liquidity operations.
    /// This is an emergency control mechanism for responding to security threats, oracle
    /// failures, or other critical issues that could harm liquidity providers.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The liquidity pool to pause
    /// - `clock`: Clock object for recording pause timestamp
    ///
    /// # Security Model
    /// Pause operations now require governance proposals with timelock delays. This prevents
    /// instant pause abuse where an administrator could pause a pool to manipulate prices
    /// or front-run large trades. The timelock provides transparency and allows the community
    /// to respond to potentially malicious pause attempts.
    ///
    /// For true emergencies, the governance timelock can be bypassed through a separate
    /// emergency pause mechanism that requires multiple signatures or a higher threshold.
    ///
    /// # Usage
    /// Use governance::propose_pause() to initiate a pause with the required timelock delay.
    /// This function should only be called after the governance proposal has been approved
    /// and the timelock has expired.
    ///
    /// # Impact
    /// - All swaps will revert with an error
    /// - Liquidity cannot be added or removed
    /// - Existing positions remain intact
    /// - Protocol fees continue to accrue
    public fun pause_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::pool::pause_pool(pool, clock);
    }

    /// Unpause a regular liquidity pool to restore normal trading activity
    ///
    /// Removes the pause state from a pool, allowing swaps and liquidity operations to
    /// resume. This should only be called after the issue that triggered the pause has
    /// been resolved and verified.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The paused liquidity pool to restore
    /// - `clock`: Clock object for recording unpause timestamp
    ///
    /// # Best Practices
    /// - Verify the security issue has been fully resolved
    /// - Communicate the unpause to the community in advance
    /// - Monitor pool activity closely after unpausing
    /// - Consider gradual re-enabling of features if possible
    public fun unpause_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut pool::LiquidityPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::pool::unpause_pool(pool, clock);
    }

    /// Pause a stable swap pool to prevent all trading activity
    ///
    /// Similar to regular pool pausing, this disables all operations on a stable swap pool.
    /// Stable pools may require pausing due to amplification coefficient issues, oracle
    /// failures for pegged assets, or de-pegging events.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The stable swap pool to pause
    /// - `clock`: Clock object for recording pause timestamp
    ///
    /// # Security Model
    /// Pause operations require governance proposals with timelock delays to prevent abuse.
    /// This ensures transparency and community oversight while maintaining emergency response
    /// capability through multi-sig or high-threshold emergency mechanisms.
    ///
    /// # Usage
    /// Use governance::propose_pause() to initiate a pause with the required timelock delay.
    /// This function executes the pause after governance approval and timelock expiration.
    ///
    /// # Stable Pool Specific Considerations
    /// - De-pegging events may require immediate pause to protect LPs
    /// - Amplification coefficient issues can cause unexpected price curves
    /// - Oracle failures for pegged assets create arbitrage risks
    public fun pause_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::pause_pool(pool, clock);
    }

    /// Unpause a stable swap pool to restore normal trading activity
    ///
    /// Removes the pause state from a stable swap pool after the triggering issue has
    /// been resolved. For stable pools, this may involve verifying that pegged assets
    /// have re-pegged or that oracle issues have been fixed.
    ///
    /// # Parameters
    /// - `_admin`: AdminCap proving authorization
    /// - `pool`: The paused stable swap pool to restore
    /// - `clock`: Clock object for recording unpause timestamp
    ///
    /// # Verification Steps Before Unpausing
    /// - Confirm pegged assets are within acceptable deviation
    /// - Verify oracle feeds are functioning correctly
    /// - Check amplification coefficient is at appropriate level
    /// - Ensure no ongoing security threats
    public fun unpause_stable_pool<CoinA, CoinB>(
        _admin: &AdminCap,
        pool: &mut stable_pool::StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ) {
        sui_amm::stable_pool::unpause_pool(pool, clock);
    }

    #[test_only]
    public fun test_init(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun create_admin_cap_for_testing(ctx: &mut tx_context::TxContext): AdminCap {
        AdminCap {
            id: object::new(ctx),
        }
    }
}
