module sui_amm::stable_math {
    /// Error codes
    const EConvergenceFailed: u64 = 0;
    const EOverflow: u64 = 1;
    const EInvalidInput: u64 = 2;

    /// Maximum iterations for convergence
    /// Note: 64 provides good balance between gas cost and edge case handling
    /// - Most pools converge in < 10 iterations
    /// - Extreme imbalances may need 20-40 iterations
    /// - 64 is sufficient while preventing DoS via unbounded iterations
    const MAX_ITERATIONS: u64 = 64;

    // Curve uses A.
    
    /// Calculate D invariant
    /// A * n^n * sum(x_i) + D = A * n^n * D + D^(n+1) / (n^n * prod(x_i))
    /// For n=2: 4A(x+y) + D = 4AD + D^3 / (4xy)
    /// 
    /// # Aborts
    /// Aborts with EConvergenceFailed if convergence fails
    public fun get_d(x: u64, y: u64, amp: u64): u64 {
        let sum = (x as u256) + (y as u256);
        if (sum == 0) return 0;
        if (x == 0 || y == 0) return (sum as u64);

        let ann = (amp as u256) * 4;
        let n_coins = 2u256;

        let mut_d = sum;
        let mut_prev_d;
        
        let mut_i = 0;
        while (mut_i < MAX_ITERATIONS) {
            // D_{i+1} = (Ann * S + D_p * n) * D / ((Ann - 1) * D + (n + 1) * D_p)
            
            // D_p = D^3 / (4xy)
            // We compute D_p iteratively:
            // D_p = D
            // D_p = D_p * D / (x * 2)
            // D_p = D_p * D / (y * 2)
            
            let d_p = mut_d;
            d_p = (d_p * mut_d) / ((x as u256) * 2);
            d_p = (d_p * mut_d) / ((y as u256) * 2);
            
            mut_prev_d = mut_d;
            
            let numerator = (ann * sum + d_p * n_coins) * mut_d;
            let denominator = (ann - 1) * mut_d + (n_coins + 1) * d_p;
            
            if (denominator == 0) {
                 // Degenerate configuration - abort instead of silently failing
                 abort EInvalidInput
            };
            
            mut_d = numerator / denominator;
            
            // Check convergence
            let diff = if (mut_d > mut_prev_d) mut_d - mut_prev_d else mut_prev_d - mut_d;
            if (diff <= 1 || diff * 1000000000000000 <= mut_d) {
                break
            };
            mut_i = mut_i + 1;
        };
        
        // Abort if convergence was not reached within the iteration budget
        assert!(mut_i < MAX_ITERATIONS, EConvergenceFailed);
        
        // Check for u64 overflow - CRITICAL: abort instead of returning 0
        assert!(mut_d <= 18446744073709551615, EOverflow);

        (mut_d as u64)
    }

    /// Calculate y given x, D, A
    public fun get_y(x: u64, d: u64, amp: u64): u64 {
        let ann = (amp as u256) * 4;
        
        let d_val = (d as u256);
        if (d_val == 0) return 0;
        
        let c = d_val;
        
        // c = D^(n+1) / (n^n * P) * P_inputs
        // c = D^3 / (4 * x)
        // c = c * D / (x * 2)
        // c = c * D / (Ann * 2) ? No, Ann is in the denominator of the equation?
        // 
        // General equation:
        // y^2 + ( S' + D/Ann - D )y = D^(n+1) / (n^n * P' * Ann)
        // where S' = sum(x_i), P' = prod(x_i)
        // For n=2:
        // y^2 + (x + D/Ann - D)y = D^3 / (4x * Ann)
        // Let c = D^3 / (4x * Ann)
        
        c = (c * d_val) / ((x as u256) * 2);
        c = (c * d_val) / (ann * 2);
        
        let b = (x as u256) + (d_val / ann); // b = x + D/Ann
        // We need y^2 + (b - D)y = c
        // y_new = (y^2 + c) / (2y + b - D)
        
        let mut_y = d_val;
        let mut_prev_y;
        let mut_i = 0;
        
        while (mut_i < MAX_ITERATIONS) {
            mut_prev_y = mut_y;
            
            // y_new = (y^2 + c) / (2y + b - D)
            
            let y_sq = mut_y * mut_y;
            let term_top = y_sq + c;
            
            let term_bottom_part = 2 * mut_y + b;
            
            if (term_bottom_part < d_val) {
                // CRITICAL FIX: Abort on degenerate configuration to prevent pool draining
                // Previously returned 0, which could allow attackers to drain reserves
                abort EInvalidInput
            };
            
            let denominator = term_bottom_part - d_val;
             
            if (denominator == 0) {
                 // Degenerate configuration - abort instead of returning 0
                 abort EInvalidInput
            };
            
            mut_y = term_top / denominator;
            
            // Check convergence
            let diff = if (mut_y > mut_prev_y) mut_y - mut_prev_y else mut_prev_y - mut_y;
            if (diff <= 1 || diff * 1000000000000000 <= mut_y) {
                break
            };
            mut_i = mut_i + 1;
        };
        
        // Abort if convergence was not reached
        assert!(mut_i < MAX_ITERATIONS, EConvergenceFailed);
        
        // Check for u64 overflow - CRITICAL: abort instead of returning 0
        assert!(mut_y <= 18446744073709551615, EOverflow);
        
        (mut_y as u64)
    }
}
