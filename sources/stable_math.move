/// Mathematical functions for StableSwap invariant calculations
///
/// This module implements the core StableSwap (Curve-like) mathematics using Newton's method
/// to solve for the invariant D and reserve values. The StableSwap invariant provides low
/// slippage for stable asset pairs by combining constant-sum and constant-product curves.
///
/// # StableSwap Invariant
/// For two tokens with reserves x and y, and amplification coefficient A:
/// A * n^n * sum(x_i) + D = A * n^n * D + D^(n+1) / (n^n * prod(x_i))
///
/// For n=2 (two tokens):
/// 4A(x+y) + D = 4AD + D^3 / (4xy)
///
/// # Newton's Method
/// Both get_d() and get_y() use iterative Newton's method to solve for unknowns.
/// Convergence is typically fast (< 10 iterations) but may require more iterations
/// for extreme pool imbalances.
module sui_amm::stable_math {
    /// Error codes
    const EConvergenceFailed: u64 = 0;
    const EOverflow: u64 = 1;
    const EInvalidInput: u64 = 2;

    /// Maximum iterations for Newton's method convergence
    ///
    /// # Convergence Behavior
    /// - Normal conditions: < 10 iterations
    /// - Extreme imbalances (99:1 ratio): 20-40 iterations
    /// - Maximum 64 iterations prevents DoS while providing safety margin
    ///
    /// # Convergence Criteria
    /// - Absolute difference <= 1 (within 1 unit)
    /// - OR relative difference <= 1e-15 (0.0000000000001%)
    ///
    /// # Failure Cases
    /// - Degenerate pool states (zero reserves, extreme amplification)
    /// - Invalid amplification parameters
    /// - Numerical instability in edge cases
    ///
    /// If convergence fails, the transaction aborts to prevent incorrect calculations
    /// that could drain the pool.
    const MAX_ITERATIONS: u64 = 64;
    
    /// Calculate the D invariant using Newton's method
    ///
    /// The D invariant represents the total value in the pool and is used to calculate
    /// swap outputs and LP token amounts. It's analogous to the constant k in x*y=k pools.
    ///
    /// # StableSwap Formula (n=2)
    /// 4A(x+y) + D = 4AD + D^3 / (4xy)
    ///
    /// Solved iteratively using Newton's method:
    /// D_{i+1} = (Ann * S + D_p * n) * D / ((Ann - 1) * D + (n + 1) * D_p)
    /// where D_p = D^3 / (4xy)
    ///
    /// # Parameters
    /// - `x`: First token reserve
    /// - `y`: Second token reserve  
    /// - `amp`: Amplification coefficient (must be > 0)
    ///
    /// # Returns
    /// - The D invariant value
    ///
    /// # Aborts
    /// - `EConvergenceFailed`: Newton's method did not converge within MAX_ITERATIONS
    /// - `EInvalidInput`: Degenerate configuration (zero denominator, invalid amp)
    /// - `EOverflow`: Result exceeds u64::MAX
    ///
    /// # Edge Cases
    /// - If both reserves are zero, returns 0
    /// - If one reserve is zero, returns sum of reserves
    public fun get_d(x: u64, y: u64, amp: u64): u64 {
        let sum = (x as u256) + (y as u256);
        if (sum == 0) return 0;
        if (x == 0 || y == 0) return (sum as u64);

        let ann = (amp as u256) * 4;
        let n_coins = 2u256;

        let mut mut_d = sum;
        let mut mut_prev_d;
        
        let mut mut_i = 0;
        while (mut_i < MAX_ITERATIONS) {
            // Newton's method iteration
            // D_{i+1} = (Ann * S + D_p * n) * D / ((Ann - 1) * D + (n + 1) * D_p)
            
            // Calculate D_p = D^3 / (4xy) iteratively to avoid overflow
            let mut d_p = mut_d;
            d_p = (d_p * mut_d) / ((x as u256) * 2);
            d_p = (d_p * mut_d) / ((y as u256) * 2);
            
            mut_prev_d = mut_d;
            
            let numerator = (ann * sum + d_p * n_coins) * mut_d;
            let denominator = (ann - 1) * mut_d + (n_coins + 1) * d_p;
            
            if (denominator == 0) {
                 abort EInvalidInput
            };
            
            mut_d = numerator / denominator;
            
            // Check convergence: absolute diff <= 1 OR relative diff <= 1e-15
            let diff = if (mut_d > mut_prev_d) mut_d - mut_prev_d else mut_prev_d - mut_d;
            if (diff <= 1 || diff * 1000000000000000 <= mut_d) {
                break
            };
            mut_i = mut_i + 1;
        };
        
        // Ensure convergence was reached
        assert!(mut_i < MAX_ITERATIONS, EConvergenceFailed);
        
        // Validate result fits in u64
        assert!(mut_d <= 18446744073709551615, EOverflow);

        (mut_d as u64)
    }

    /// Calculate y reserve given x, D, and amp using Newton's method
    ///
    /// Used during swaps to determine the output amount. Given one reserve (x),
    /// the invariant (D), and amplification (amp), solves for the other reserve (y).
    ///
    /// # Equation to Solve
    /// y^2 + (x + D/Ann - D)y = D^3 / (4x * Ann)
    ///
    /// # Newton's Method
    /// y_new = (y^2 + c) / (2y + b - D)
    /// where:
    /// - c = D^3 / (4x * Ann)
    /// - b = x + D/Ann
    ///
    /// # Parameters
    /// - `x`: Known token reserve
    /// - `d`: D invariant (from get_d)
    /// - `amp`: Amplification coefficient
    ///
    /// # Returns
    /// - The calculated y reserve value
    ///
    /// # Aborts
    /// - `EConvergenceFailed`: Newton's method did not converge within MAX_ITERATIONS
    /// - `EInvalidInput`: Degenerate configuration (zero denominator, invalid parameters)
    /// - `EOverflow`: Result exceeds u64::MAX
    ///
    /// # Edge Cases
    /// - If D is zero, returns 0
    public fun get_y(x: u64, d: u64, amp: u64): u64 {
        let ann = (amp as u256) * 4;
        
        let d_val = (d as u256);
        if (d_val == 0) return 0;
        
        let mut c = d_val;
        
        // Calculate c = D^3 / (4x * Ann) iteratively to avoid overflow
        c = (c * d_val) / ((x as u256) * 2);
        c = (c * d_val) / (ann * 2);
        
        // Calculate b = x + D/Ann
        let b = (x as u256) + (d_val / ann);
        
        // Solve: y^2 + (b - D)y = c
        // Newton's method: y_new = (y^2 + c) / (2y + b - D)
        
        let mut mut_y = d_val;
        let mut mut_prev_y;
        let mut mut_i = 0;
        
        while (mut_i < MAX_ITERATIONS) {
            mut_prev_y = mut_y;
            
            // Newton's method iteration: y_new = (y^2 + c) / (2y + b - D)
            let y_sq = mut_y * mut_y;
            let term_top = y_sq + c;
            
            let term_bottom_part = 2 * mut_y + b;
            
            if (term_bottom_part < d_val) {
                // Degenerate configuration that could allow pool draining
                abort EInvalidInput
            };
            
            let denominator = term_bottom_part - d_val;
             
            if (denominator == 0) {
                 abort EInvalidInput
            };
            
            mut_y = term_top / denominator;
            
            // Check convergence: absolute diff <= 1 OR relative diff <= 1e-15
            let diff = if (mut_y > mut_prev_y) mut_y - mut_prev_y else mut_prev_y - mut_y;
            if (diff <= 1 || diff * 1000000000000000 <= mut_y) {
                break
            };
            mut_i = mut_i + 1;
        };
        
        // Ensure convergence was reached
        assert!(mut_i < MAX_ITERATIONS, EConvergenceFailed);
        
        // Validate result fits in u64
        assert!(mut_y <= 18446744073709551615, EOverflow);
        
        (mut_y as u64)
    }
}
