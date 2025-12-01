module sui_amm::math {
    const EZeroAmount: u64 = 0;

    public fun sqrt(y: u64): u64 {
        if (y < 4) {
            if (y == 0) {
                0
            } else {
                1
            }
        } else {
            let mut z = y;
            let mut x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            z
        }
    }

    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    public fun calculate_constant_product_output(
        input_amount: u64,
        input_reserve: u64,
        output_reserve: u64,
        fee_percent: u64
    ): u64 {
        assert!(input_amount > 0, EZeroAmount);
        assert!(input_reserve > 0 && output_reserve > 0, EZeroAmount);

        let input_amount_with_fee = (input_amount as u128) * ((10000 - fee_percent) as u128);
        let numerator = input_amount_with_fee * (output_reserve as u128);
        let denominator = (input_reserve as u128) * 10000 + input_amount_with_fee;

        ((numerator / denominator) as u64)
    }

    /// FIX [P2-19.3]: Quote function with u128 precision throughout
    /// 
    /// Calculates the equivalent amount of token B for a given amount of token A
    /// based on current pool reserves, maintaining maximum precision.
    /// 
    /// # Parameters
    /// - amount_a: Amount of token A to quote
    /// - reserve_a: Current reserve of token A in pool
    /// - reserve_b: Current reserve of token B in pool
    /// 
    /// # Returns
    /// Equivalent amount of token B (rounded down)
    /// 
    /// # Precision
    /// - Uses u128 for all intermediate calculations to prevent precision loss
    /// - Only downcasts to u64 at the final step
    /// - Formula: amount_b = (amount_a * reserve_b) / reserve_a
    /// 
    /// # Aborts
    /// - EZeroAmount: If any input is zero
    public fun quote(
        amount_a: u64,
        reserve_a: u64,
        reserve_b: u64
    ): u64 {
        assert!(amount_a > 0, EZeroAmount);
        assert!(reserve_a > 0 && reserve_b > 0, EZeroAmount);

        // FIX [P2-19.3]: Use u128 throughout to prevent precision loss
        // Keep intermediate result in u128 until final downcast
        let amount_a_u128 = (amount_a as u128);
        let reserve_a_u128 = (reserve_a as u128);
        let reserve_b_u128 = (reserve_b as u128);
        
        // Calculate: (amount_a * reserve_b) / reserve_a
        let numerator = amount_a_u128 * reserve_b_u128;
        let result_u128 = numerator / reserve_a_u128;
        
        // Only downcast at the final step
        (result_u128 as u64)
    }
}
