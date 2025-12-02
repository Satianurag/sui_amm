/// Mathematical utility functions for AMM calculations
///
/// This module provides core mathematical operations used throughout the AMM,
/// including square root calculation, constant product formula, and price quoting.
/// All functions use u128 for intermediate calculations to prevent overflow and
/// maintain precision, only downcasting to u64 for final results.
module sui_amm::math {
    const EZeroAmount: u64 = 0;

    /// Calculates the integer square root of a number using Newton's method
    ///
    /// Uses an iterative approximation algorithm that converges to the floor of sqrt(y).
    /// This is essential for calculating geometric mean in liquidity operations.
    ///
    /// # Parameters
    /// - `y`: The number to calculate the square root of
    ///
    /// # Returns
    /// The largest integer z such that z² ≤ y
    ///
    /// # Algorithm
    /// For y < 4: Returns 0 for y=0, 1 for y=1,2,3 (since floor(sqrt(3)) = 1)
    /// For y ≥ 4: Uses Newton's method with iteration: x_next = (y/x + x) / 2
    /// Converges when x ≥ z (no further improvement possible)
    ///
    /// # Examples
    /// - sqrt(0) = 0
    /// - sqrt(1) = 1
    /// - sqrt(4) = 2
    /// - sqrt(15) = 3 (floor of 3.87...)
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
            
            // Newton's method iteration: converge to floor(sqrt(y))
            // Each iteration improves the approximation until x >= z
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            z
        }
    }

    /// Returns the minimum of two u64 values
    ///
    /// # Parameters
    /// - `a`: First value
    /// - `b`: Second value
    ///
    /// # Returns
    /// The smaller of a and b
    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    /// Calculates output amount for a constant product AMM swap with fees
    ///
    /// Implements the constant product formula: x * y = k
    /// The output is calculated such that (x + Δx_with_fee) * (y - Δy) = k
    /// where Δx_with_fee = Δx * (1 - fee_rate)
    ///
    /// # Parameters
    /// - `input_amount`: Amount of input token being swapped (Δx)
    /// - `input_reserve`: Current reserve of input token in pool (x)
    /// - `output_reserve`: Current reserve of output token in pool (y)
    /// - `fee_percent`: Fee in basis points (e.g., 30 = 0.30%)
    ///
    /// # Returns
    /// Amount of output token to be received (Δy)
    ///
    /// # Formula
    /// Δy = (Δx * (10000 - fee) * y) / (x * 10000 + Δx * (10000 - fee))
    ///
    /// # Precision
    /// Uses u128 for all intermediate calculations to prevent overflow
    /// Fee is applied before the swap calculation to ensure K-invariant holds
    ///
    /// # Aborts
    /// - EZeroAmount: If input_amount is zero
    /// - EZeroAmount: If either reserve is zero
    public fun calculate_constant_product_output(
        input_amount: u64,
        input_reserve: u64,
        output_reserve: u64,
        fee_percent: u64
    ): u64 {
        assert!(input_amount > 0, EZeroAmount);
        assert!(input_reserve > 0 && output_reserve > 0, EZeroAmount);

        // Apply fee to input amount: effective_input = input * (1 - fee_rate)
        // Fee is deducted before swap to maintain K-invariant after fee collection
        let input_amount_with_fee = (input_amount as u128) * ((10000 - fee_percent) as u128);
        let numerator = input_amount_with_fee * (output_reserve as u128);
        let denominator = (input_reserve as u128) * 10000 + input_amount_with_fee;

        ((numerator / denominator) as u64)
    }

    /// Calculates the equivalent amount of one token for a given amount of another
    ///
    /// This function performs price quoting based on current pool reserves, maintaining
    /// the ratio: amount_b / amount_a = reserve_b / reserve_a
    /// Used for calculating expected amounts in liquidity operations and price displays.
    ///
    /// # Parameters
    /// - `amount_a`: Amount of token A to quote
    /// - `reserve_a`: Current reserve of token A in pool
    /// - `reserve_b`: Current reserve of token B in pool
    ///
    /// # Returns
    /// Equivalent amount of token B (rounded down)
    ///
    /// # Formula
    /// amount_b = (amount_a * reserve_b) / reserve_a
    ///
    /// # Precision
    /// Uses u128 for all intermediate calculations to prevent precision loss and overflow
    /// This is critical for large reserve values where u64 multiplication would overflow
    /// Only downcasts to u64 at the final step after division
    ///
    /// # Aborts
    /// - EZeroAmount: If amount_a is zero
    /// - EZeroAmount: If either reserve is zero
    public fun quote(
        amount_a: u64,
        reserve_a: u64,
        reserve_b: u64
    ): u64 {
        assert!(amount_a > 0, EZeroAmount);
        assert!(reserve_a > 0 && reserve_b > 0, EZeroAmount);

        // Upcast to u128 to prevent overflow in multiplication
        // This allows handling reserves up to 2^64-1 without overflow
        let amount_a_u128 = (amount_a as u128);
        let reserve_a_u128 = (reserve_a as u128);
        let reserve_b_u128 = (reserve_b as u128);
        
        let numerator = amount_a_u128 * reserve_b_u128;
        let result_u128 = numerator / reserve_a_u128;
        
        (result_u128 as u64)
    }
}
