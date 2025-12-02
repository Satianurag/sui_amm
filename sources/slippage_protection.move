/// Slippage protection and deadline validation utilities
///
/// This module provides protection mechanisms against unfavorable trade execution
/// and MEV (Maximal Extractable Value) attacks. It implements three key protections:
///
/// 1. **Deadline Checks**: Prevent transactions from executing after a specified time,
///    protecting against delayed execution that could result in unfavorable prices.
///
/// 2. **Minimum Output Checks**: Ensure trades receive at least a minimum amount of
///    output tokens, protecting against excessive slippage.
///
/// 3. **Price Limit Checks**: Verify the effective price doesn't exceed a maximum,
///    implementing "Immediate-or-Cancel" limit order semantics.
///
/// # MEV Protection
/// These mechanisms protect users from sandwich attacks and other MEV strategies by:
/// - Preventing stale transactions from executing (deadline)
/// - Ensuring minimum acceptable outputs (slippage tolerance)
/// - Enforcing maximum acceptable prices (price limits)
module sui_amm::slippage_protection {
    use sui::clock;

    /// Transaction deadline has passed
    const EDeadlinePassed: u64 = 0;
    /// Output amount is below minimum acceptable (excessive slippage)
    const EExcessiveSlippage: u64 = 1;
    /// Output amount is insufficient (used for zero-output validation)
    const EInsufficientOutput: u64 = 2;

    /// Verify transaction deadline has not passed
    ///
    /// Prevents delayed execution that could result in unfavorable prices due to
    /// market movement. This is a critical MEV protection mechanism.
    ///
    /// # Parameters
    /// - `clock`: Current blockchain time
    /// - `deadline`: Maximum timestamp (in milliseconds) for execution
    ///
    /// # Aborts
    /// - `EDeadlinePassed`: If current time exceeds deadline
    public fun check_deadline(clock: &clock::Clock, deadline: u64) {
        assert!(clock::timestamp_ms(clock) <= deadline, EDeadlinePassed);
    }

    /// Verify output amount meets minimum requirement
    ///
    /// Ensures the trade receives at least the minimum acceptable output, protecting
    /// against excessive slippage. Users specify their slippage tolerance by setting
    /// min_output based on expected output and acceptable slippage percentage.
    ///
    /// # Parameters
    /// - `output_amount`: Actual output amount from the trade
    /// - `min_output`: Minimum acceptable output amount
    ///
    /// # Aborts
    /// - `EExcessiveSlippage`: If output_amount < min_output
    public fun check_slippage(output_amount: u64, min_output: u64) {
        assert!(output_amount >= min_output, EExcessiveSlippage);
    }

    /// Verify the effective price is within acceptable limits
    ///
    /// Implements "Immediate-or-Cancel" limit order semantics by checking if the
    /// effective price (amount_in / amount_out) exceeds the maximum acceptable price.
    /// This provides an additional layer of protection beyond minimum output checks.
    ///
    /// # Price Calculation
    /// - Effective price = amount_in / amount_out (how much input per 1 output)
    /// - Price is scaled by 1e9 for precision
    /// - Condition: effective_price <= max_price
    ///
    /// # Special Cases
    /// - max_price = u64::MAX: Treated as "no limit" (always passes)
    /// - amount_out = 0: Only allowed if max_price is very large (> 1e18)
    ///   This prevents abuse while allowing legitimate dust swaps when explicitly disabled
    ///
    /// # Parameters
    /// - `amount_in`: Input token amount
    /// - `amount_out`: Output token amount
    /// - `max_price`: Maximum acceptable price (scaled by 1e9)
    ///
    /// # Aborts
    /// - `EExcessiveSlippage`: If effective price exceeds max_price
    /// - `EInsufficientOutput`: If amount_out is 0 and max_price is not very large
    ///
    /// # Note on Pool Models
    /// This is a generic price check that works across different pool types
    /// (constant product, stable swap, etc.). Pool-specific price impact
    /// calculations should be done at the pool level before calling this function.
    public fun check_price_limit(
        amount_in: u64,
        amount_out: u64,
        max_price: u64
    ) {
        // Treat u64::MAX as "no price limit"
        if (max_price == 18446744073709551615) {
            return
        };
        
        // Handle zero output case
        // Only allow if user explicitly disabled price limits with very large max_price
        // This prevents abuse while supporting legitimate dust swaps
        if (amount_out == 0) {
            assert!(max_price > 1_000_000_000_000_000_000, EInsufficientOutput);
            return
        };
        
        // Calculate effective price and verify it's within limit
        let price = (amount_in as u128) * 1_000_000_000 / (amount_out as u128);
        assert!(price <= (max_price as u128), EExcessiveSlippage);
    }

    /// Get the global maximum slippage in basis points
    ///
    /// Returns 0 to indicate no protocol-wide hard cap. This function is kept
    /// for backward compatibility, but callers should use per-pool slippage
    /// configuration instead of relying on a global limit.
    ///
    /// # Returns
    /// Always returns 0 (no global limit)
    public fun global_max_slippage_bps(): u64 {
        0
    }

    /// Calculate slippage percentage between expected and actual output
    ///
    /// Computes the slippage as a percentage in basis points (1 bp = 0.01%).
    /// This provides a real-time slippage preview that UIs can display to users
    /// before they submit transactions.
    ///
    /// # Formula
    /// slippage_bps = ((expected - actual) / expected) * 10000
    ///
    /// # Parameters
    /// - `expected_output`: Expected output amount (e.g., from pool preview)
    /// - `actual_output`: Actual output amount that would be received
    ///
    /// # Returns
    /// Slippage in basis points (0-10000, where 10000 = 100%)
    /// Returns 0 if actual >= expected (no slippage or favorable execution)
    ///
    /// # Examples
    /// - Expected 1000, Actual 990: Returns 100 (1% slippage)
    /// - Expected 1000, Actual 950: Returns 500 (5% slippage)
    /// - Expected 1000, Actual 1010: Returns 0 (favorable execution)
    public fun calculate_slippage_bps(
        expected_output: u64,
        actual_output: u64,
    ): u64 {
        // No slippage if expected is zero or actual meets/exceeds expected
        if (expected_output == 0 || actual_output >= expected_output) {
            return 0
        };

        // Calculate slippage percentage in basis points
        let diff = (expected_output as u128) - (actual_output as u128);
        (((diff * 10000) / (expected_output as u128)) as u64)
    }
}
