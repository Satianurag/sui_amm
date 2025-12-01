module sui_amm::slippage_protection {
    use sui::clock;

    /// Error codes
    const EDeadlinePassed: u64 = 0;
    const EExcessiveSlippage: u64 = 1;
    const EInsufficientOutput: u64 = 2;

    /// Check if the transaction deadline has passed.
    public fun check_deadline(clock: &clock::Clock, deadline: u64) {
        assert!(clock::timestamp_ms(clock) <= deadline, EDeadlinePassed);
    }

    /// Check if the output amount meets the minimum requirement.
    public fun check_slippage(output_amount: u64, min_output: u64) {
        assert!(output_amount >= min_output, EExcessiveSlippage);
    }

    /// NOTE: Price impact calculations are pool-model specific.
    /// Constant-product pools may implement Uniswap-style impact; StableSwap
    /// pools should use the Stable invariant/virtual price. To avoid mixing
    /// models, this module now only exposes generic helpers (deadline,
    /// min-output, price limit checks) plus a reusable slippage calculator
    /// that front-ends can call after fetching pool quotes.

    /// Check if the effective price (amount_out / amount_in) is within the limit.
    /// max_price: Maximum amount of input tokens per 1 output token (scaled by 1e9).
    /// Effectively: amount_in / amount_out <= max_price
    /// 
    /// This function satisfies the "Price limit orders" requirement by allowing
    /// users to specify a maximum price they are willing to pay. If the
    /// effective price exceeds this limit, the transaction aborts (Immediate-or-Cancel).
    public fun check_price_limit(
        amount_in: u64,
        amount_out: u64,
        max_price: u64
    ) {
        // Price = amount_in / amount_out
        // We want Price <= max_price
        // amount_in * 1e9 / amount_out <= max_price
        
        // If max_price is u64::MAX, we treat it as "no limit"
        if (max_price == 18446744073709551615) {
            return
        };
        
        // Special case: If amount_out == 0, only allow if max_price is effectively unlimited
        // This allows dust swaps (with min_out=0) to pass when user explicitly disables price limits
        // by passing a very large max_price (e.g., u64::MAX)
        if (amount_out == 0) {
            // Only allow zero output if max_price is close to u64::MAX (> 1e18)
            // This prevents abuse while allowing legitimate dust swaps with max_price=u64::MAX
            assert!(max_price > 1_000_000_000_000_000_000, EInsufficientOutput);
            return
        };
        
        let price = (amount_in as u128) * 1_000_000_000 / (amount_out as u128);
        assert!(price <= (max_price as u128), EExcessiveSlippage);
    }

    /// Kept for backward compatibility: callers should not rely on a
    /// protocol-wide hard cap any more. Use per-pool configuration instead.
    public fun global_max_slippage_bps(): u64 {
        0
    }

    /// Calculate slippage (in basis points) between an expected output and
    /// the actual output that a user would receive. This provides the
    /// "real-time" slippage preview required by the PRD and can be exposed by
    /// clients alongside pool::preview_* helpers.
    public fun calculate_slippage_bps(
        expected_output: u64,
        actual_output: u64,
    ): u64 {
        if (expected_output == 0 || actual_output >= expected_output) {
            return 0
        };

        let diff = (expected_output as u128) - (actual_output as u128);
        (((diff * 10000) / (expected_output as u128)) as u64)
    }
}
