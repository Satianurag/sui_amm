#[test_only]
module sui_amm::stable_math_edge_tests {
    use sui_amm::stable_math;

    #[test]
    fun test_get_d_equal_amounts() {
        // Equal amounts should return stable D
        let d = stable_math::get_d(1000, 1000, 100);
        assert!(d > 0, 0);
        // D should be approximately 2x the amount for equal reserves
        assert!(d >= 1900 && d <= 2100, 1);
    }

    #[test]
    fun test_get_d_zero_amounts() {
        // Zero amounts should return zero D
        let d = stable_math::get_d(0, 0, 100);
        assert!(d == 0, 0);
    }

    #[test]
    fun test_get_d_one_zero() {
        // One very small amount should still calculate
        let d = stable_math::get_d(1000, 1, 100);
        assert!(d > 0, 0);
    }

    #[test]
    fun test_get_d_unbalanced() {
        // Heavily unbalanced reserves
        let d = stable_math::get_d(10000, 1000, 100);
        assert!(d > 0, 0);
        // D should be between sum and geometric mean
        assert!(d >= 1000, 1);
    }

    #[test]
    fun test_get_d_low_amplification() {
        // Low amp = more like constant product
        let d_low = stable_math::get_d(1000, 1000, 1);
        assert!(d_low > 0, 0);
    }

    #[test]
    fun test_get_d_high_amplification() {
        // High amp = more like constant sum
        let d_high = stable_math::get_d(1000, 1000, 10000);
        assert!(d_high > 0, 0);
        
        // Higher amp should give D closer to sum
        let d_low = stable_math::get_d(1000, 1000, 1);
        assert!(d_high >= d_low, 1);
    }

    #[test]
    fun test_get_d_very_large_amounts() {
        // Test with large numbers (but not overflow)
        let d = stable_math::get_d(100000000, 100000000, 100);
        assert!(d > 0, 0);
        assert!(d >= 100000000, 1);
    }

    #[test]
    fun test_get_y_basic() {
        // Get y given x and D
        let d = stable_math::get_d(1000, 1000, 100);
        let y = stable_math::get_y(1000, d, 100);
        
        // y should be close to 1000 for balanced pool
        assert!(y >= 900 && y <= 1100, 0);
    }

    #[test]
    fun test_get_y_after_swap() {
        // Simulate a swap: x increases, y should decrease
        let d = stable_math::get_d(1000, 1000, 100);
        let y_new = stable_math::get_y(1100, d, 100); // x increased by 100
        
        // y should be less than 1000
        assert!(y_new < 1000, 0);
    }

    #[test]
    fun test_get_y_convergence() {
        // Test that get_y converges properly
        let d = stable_math::get_d(10000, 10000, 100);
        let y1 = stable_math::get_y(11000, d, 100);
        let y2 = stable_math::get_y(11000, d, 100);
        
        // Should be deterministic
        assert!(y1 == y2, 0);
    }

    #[test]
    fun test_get_y_extreme_x() {
        let d = stable_math::get_d(1000, 1000, 100);
        
        // Very small x
        let y_large = stable_math::get_y(100, d, 100);
        assert!(y_large > 1000, 0); // y should be larger when x is smaller
        
        // Very large x (relative to original)
        let y_small = stable_math::get_y(10000, d, 100);
        assert!(y_small < 1000, 1); // y should be smaller when x is larger
    }

    #[test]
    fun test_amplification_effect() {
        let d = stable_math::get_d(1000, 1000, 100);
        
        // Same swap with different amplifications
        let y_low_amp = stable_math::get_y(1100, d, 1);  // Low amp
        let y_mid_amp = stable_math::get_y(1100, d, 100); // Mid amp
        let y_high_amp = stable_math::get_y(1100, d, 1000); // High amp
        
        // All should give valid results
        assert!(y_low_amp > 0, 0);
        assert!(y_mid_amp > 0, 1);
        assert!(y_high_amp > 0, 2);
        
        // Higher amplification should give less price impact (y closer to original)
        assert!(y_high_amp >= y_mid_amp, 3);
    }

    #[test]
    fun test_d_invariant_maintained() {
        // After a swap, D should remain constant
        let x1 = 1000;
        let y1 = 1000;
        let amp = 100;
        
        let d1 = stable_math::get_d(x1, y1, amp);
        
        // Simulate swap: increase x
        let x2 = 1100;
        let y2 = stable_math::get_y(x2, d1, amp);
        
        // Recalculate D with new x,y
        let d2 = stable_math::get_d(x2, y2, amp);
        
        // D should be approximately the same (allow small deviation due to rounding)
        let diff = if (d2 > d1) { d2 - d1 } else { d1 - d2 };
        assert!(diff <= 5, 0); // Allow up to 5 unit deviation
    }

    #[test]
    fun test_get_y_with_small_d() {
        // Edge case: very small D value
        let y = stable_math::get_y(10, 20, 100);
        assert!(y > 0, 0);
    }

    #[test]
    fun test_symmetry() {
        // get_d should be symmetric in x and y
        let d1 = stable_math::get_d(1000, 2000, 100);
        let d2 = stable_math::get_d(2000, 1000, 100);
        assert!(d1 == d2, 0);
    }
}
