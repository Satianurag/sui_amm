module sui_amm::slippage_protection {
    use sui::clock::{Self, Clock};

    /// Error codes
    const EDeadlinePassed: u64 = 0;
    const EExcessiveSlippage: u64 = 1;
    const EInsufficientOutput: u64 = 2;

    /// Check if the transaction deadline has passed.
    public fun check_deadline(clock: &Clock, deadline: u64) {
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
    /// min-output and price limit checks). Pools are responsible for doing
    /// their own price-impact math and enforcing any per-pool caps.

    /// Check if the effective price (amount_out / amount_in) is within the limit.
    /// max_price: Maximum amount of input tokens per 1 output token (scaled by 1e9).
    /// Effectively: amount_in / amount_out <= max_price
    public fun check_price_limit(
        amount_in: u64,
        amount_out: u64,
        max_price: u64
    ) {
        // Price = amount_in / amount_out
        // We want Price <= max_price
        // amount_in * 1e9 / amount_out <= max_price
        
        assert!(amount_out > 0, EInsufficientOutput);
        
        let price = (amount_in as u128) * 1_000_000_000 / (amount_out as u128);
        assert!(price <= (max_price as u128), EExcessiveSlippage);
    }

    /// Kept for backward compatibility: callers should not rely on a
    /// protocol-wide hard cap any more. Use per-pool configuration instead.
    public fun global_max_slippage_bps(): u64 {
        0
    }
}
