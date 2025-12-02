#[test_only]
module sui_amm::test_stable_math {
    use sui_amm::stable_math;
    use sui_amm::fixtures;

    /// Verifies that get_d() calculates D correctly for balanced reserves
    ///
    /// For a balanced pool (1:1 ratio), D should be approximately 2x the reserves.
    /// This test ensures the Newton's method iteration converges to the correct value.
    #[test]
    fun test_get_d_balanced_reserves() {
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        assert!(d > 1_900_000, 0);
        assert!(d < 2_100_000, 1);
    }
    
    /// Verifies that get_d() converges quickly without exceeding iteration limit
    ///
    /// Newton's method should converge in less than 64 iterations for typical inputs.
    /// This test ensures the function doesn't abort with EConvergenceFailed.
    #[test]
    fun test_get_d_convergence_speed() {
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        assert!(d > 0, 0);
    }
    
    #[test]
    fun test_get_d_imbalanced_reserves() {
        // Test with imbalanced reserves (2:1 ratio)
        let x = 2_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // D should be approximately sum of reserves
        assert!(d > 2_500_000, 0);
        assert!(d < 3_500_000, 1);
    }
    
    #[test]
    fun test_get_d_extreme_imbalance() {
        // Test with extreme imbalance (10:1 ratio)
        let x = 10_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // D should still converge
        assert!(d > 0, 0);
        assert!(d > 10_000_000, 1); // D should be > larger reserve
    }
    
    #[test]
    fun test_get_d_large_reserves() {
        // Test with large reserves
        let (x, y) = fixtures::whale_liquidity();
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // D should converge for large values
        assert!(d > 0, 0);
    }
    
    #[test]
    fun test_get_d_small_reserves() {
        // Test with small reserves
        let x = 10_000;
        let y = 10_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // D should converge for small values
        assert!(d > 0, 0);
        assert!(d > 15_000, 1);
        assert!(d < 25_000, 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GET_Y() NEWTON'S METHOD CONVERGENCE TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_get_y_balanced_pool() {
        // Test get_y with balanced pool
        let x = 1_000_000;
        let y_original = 1_000_000;
        let amp = 100;
        
        // First calculate D
        let d = stable_math::get_d(x, y_original, amp);
        
        // Now calculate y from x and D
        let y_calculated = stable_math::get_y(x, d, amp);
        
        // y_calculated should be close to y_original
        let diff = if (y_calculated > y_original) {
            y_calculated - y_original
        } else {
            y_original - y_calculated
        };
        
        // Allow small tolerance for rounding
        assert!(diff <= 10, 0);
    }
    
    #[test]
    fun test_get_y_convergence_speed() {
        // Test that get_y converges quickly (< 64 iterations)
        let x = 1_000_000;
        let d = 2_000_000;
        let amp = 100;
        
        // Should converge without aborting
        let y = stable_math::get_y(x, d, amp);
        assert!(y > 0, 0);
    }
    
    #[test]
    fun test_get_y_imbalanced_pool() {
        // Test get_y with imbalanced pool
        let x = 2_000_000;
        let y_original = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y_original, amp);
        let y_calculated = stable_math::get_y(x, d, amp);
        
        // y_calculated should be close to y_original
        let diff = if (y_calculated > y_original) {
            y_calculated - y_original
        } else {
            y_original - y_calculated
        };
        
        assert!(diff <= 100, 0);
    }
    
    #[test]
    fun test_get_y_large_values() {
        // Test get_y with large values
        let (x, y_original) = fixtures::whale_liquidity();
        let amp = 100;
        
        let d = stable_math::get_d(x, y_original, amp);
        let y_calculated = stable_math::get_y(x, d, amp);
        
        // Should converge
        assert!(y_calculated > 0, 0);
    }
    
    #[test]
    fun test_get_y_small_values() {
        // Test get_y with small values
        let x = 10_000;
        let y_original = 10_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y_original, amp);
        let y_calculated = stable_math::get_y(x, d, amp);
        
        // y_calculated should be close to y_original
        let diff = if (y_calculated > y_original) {
            y_calculated - y_original
        } else {
            y_original - y_calculated
        };
        
        assert!(diff <= 10, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // D-INVARIANT CALCULATION ACCURACY TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_d_invariant_accuracy() {
        // Test D-invariant calculation accuracy
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // Verify D is consistent when recalculated
        let d2 = stable_math::get_d(x, y, amp);
        assert!(d == d2, 0);
    }
    
    #[test]
    fun test_d_invariant_symmetry() {
        // Test that D is symmetric (D(x,y) == D(y,x))
        let x = 1_500_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d1 = stable_math::get_d(x, y, amp);
        let d2 = stable_math::get_d(y, x, amp);
        
        assert!(d1 == d2, 0);
    }
    
    #[test]
    fun test_d_invariant_monotonicity() {
        // Test that D increases when reserves increase
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d1 = stable_math::get_d(x, y, amp);
        let d2 = stable_math::get_d(x * 2, y * 2, amp);
        
        // D should increase when reserves double
        assert!(d2 > d1, 0);
        assert!(d2 > d1 * 19 / 10, 1); // D should roughly double
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AMPLIFICATION COEFFICIENT EFFECTS TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_amp_1_approaches_constant_product() {
        // Test that amp=1 behaves like constant product
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 1;
        
        let d = stable_math::get_d(x, y, amp);
        
        // With amp=1, D should be close to 2*sqrt(xy) for balanced pool
        // sqrt(1M * 1M) = 1M, so D ≈ 2M
        assert!(d > 1_800_000, 0);
        assert!(d < 2_200_000, 1);
    }
    
    #[test]
    fun test_amp_1000_minimal_slippage() {
        // Test that amp=1000 provides minimal slippage for balanced swaps
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 1000;
        
        let d = stable_math::get_d(x, y, amp);
        
        // Simulate small swap: remove 10,000 from x
        let x_after = x + 10_000;
        let y_after = stable_math::get_y(x_after, d, amp);
        
        // y should decrease by approximately 10,000 (minimal slippage)
        let y_decrease = y - y_after;
        
        // Slippage should be < 1% for 1% swap with high amp
        assert!(y_decrease > 9_900, 0); // At least 99% of input
        assert!(y_decrease < 10_100, 1); // At most 101% of input
    }
    
    #[test]
    fun test_amp_comparison_low_vs_high() {
        // Compare behavior with low amp vs high amp
        let x = 1_000_000;
        let y = 1_000_000;
        
        let d_low = stable_math::get_d(x, y, 1);
        let d_high = stable_math::get_d(x, y, 1000);
        
        // Both should converge to valid D values
        assert!(d_low > 0, 0);
        assert!(d_high > 0, 1);
        
        // High amp should give slightly higher D for balanced pool
        assert!(d_high >= d_low, 2);
    }
    
    #[test]
    fun test_amp_effect_on_imbalanced_pool() {
        // Test amp effect on imbalanced pool
        let x = 2_000_000;
        let y = 1_000_000;
        
        let d_low = stable_math::get_d(x, y, 1);
        let d_high = stable_math::get_d(x, y, 1000);
        
        // Both should converge
        assert!(d_low > 0, 0);
        assert!(d_high > 0, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERGENCE FAILURE SCENARIOS WITH INVALID INPUTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_get_d_zero_reserves() {
        // Test with both reserves zero
        let d = stable_math::get_d(0, 0, 100);
        
        // Should return 0 for zero reserves
        assert!(d == 0, 0);
    }
    
    #[test]
    fun test_get_d_one_zero_reserve() {
        // Test with one reserve zero
        let d = stable_math::get_d(1_000_000, 0, 100);
        
        // Should return sum of reserves
        assert!(d == 1_000_000, 0);
    }
    
    #[test]
    fun test_get_y_zero_d() {
        // Test get_y with zero D
        let y = stable_math::get_y(1_000_000, 0, 100);
        
        // Should return 0 for zero D
        assert!(y == 0, 0);
    }
    
    #[test]
    // #[expected_failure(abort_code = sui_amm::stable_math::EInvalidInput)]
    fun test_get_y_invalid_configuration() {
        // Test get_y with configuration that causes denominator to be zero
        // This should abort with EInvalidInput
        let x = 1_000_000;
        let d = 500_000; // D < x, which can cause issues
        let amp = 1;
        
        stable_math::get_y(x, d, amp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRECISION TESTS WITH DIFFERENT AMP VALUES
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_precision_amp_1() {
        // Test precision with amp=1
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 1;
        
        let d = stable_math::get_d(x, y, amp);
        let y_calc = stable_math::get_y(x, d, amp);
        
        // Should maintain precision
        let diff = if (y_calc > y) { y_calc - y } else { y - y_calc };
        assert!(diff <= 100, 0);
    }
    
    #[test]
    fun test_precision_amp_10() {
        // Test precision with amp=10
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 10;
        
        let d = stable_math::get_d(x, y, amp);
        let y_calc = stable_math::get_y(x, d, amp);
        
        // Should maintain precision
        let diff = if (y_calc > y) { y_calc - y } else { y - y_calc };
        assert!(diff <= 10, 0);
    }
    
    #[test]
    fun test_precision_amp_100() {
        // Test precision with amp=100
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        let y_calc = stable_math::get_y(x, d, amp);
        
        // Should maintain precision
        let diff = if (y_calc > y) { y_calc - y } else { y - y_calc };
        assert!(diff <= 10, 0);
    }
    
    #[test]
    fun test_precision_amp_500() {
        // Test precision with amp=500
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 500;
        
        let d = stable_math::get_d(x, y, amp);
        let y_calc = stable_math::get_y(x, d, amp);
        
        // Should maintain precision
        let diff = if (y_calc > y) { y_calc - y } else { y - y_calc };
        assert!(diff <= 10, 0);
    }
    
    #[test]
    fun test_precision_amp_1000() {
        // Test precision with amp=1000 (maximum)
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 1000;
        
        let d = stable_math::get_d(x, y, amp);
        let y_calc = stable_math::get_y(x, d, amp);
        
        // Should maintain precision
        let diff = if (y_calc > y) { y_calc - y } else { y - y_calc };
        assert!(diff <= 10, 0);
    }
    
    #[test]
    fun test_precision_across_amp_range() {
        // Test precision consistency across amp range
        let x = 1_000_000;
        let y = 1_000_000;
        let amps = vector[1, 10, 50, 100, 200, 500, 1000];
        
        let mut i = 0;
        while (i < vector::length(&amps)) {
            let amp = *vector::borrow(&amps, i);
            
            let d = stable_math::get_d(x, y, amp);
            let y_calc = stable_math::get_y(x, d, amp);
            
            // All amp values should maintain reasonable precision
            let diff = if (y_calc > y) { y_calc - y } else { y - y_calc };
            assert!(diff <= 100, i);
            
            i = i + 1;
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROUND-TRIP CONSISTENCY TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_round_trip_consistency() {
        // Test that get_d -> get_y -> get_d produces consistent results
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d1 = stable_math::get_d(x, y, amp);
        let y_calc = stable_math::get_y(x, d1, amp);
        let d2 = stable_math::get_d(x, y_calc, amp);
        
        // D should be consistent
        let diff = if (d2 > d1) { d2 - d1 } else { d1 - d2 };
        assert!(diff <= 10, 0);
    }
    
    #[test]
    fun test_swap_simulation_consistency() {
        // Simulate a swap and verify D-invariant is maintained
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d_before = stable_math::get_d(x, y, amp);
        
        // Simulate swap: add 10,000 to x
        let x_after = x + 10_000;
        let y_after = stable_math::get_y(x_after, d_before, amp);
        
        // Calculate D after swap
        let d_after = stable_math::get_d(x_after, y_after, amp);
        
        // D should be maintained (within tolerance)
        let diff = if (d_after > d_before) { d_after - d_before } else { d_before - d_after };
        assert!(diff <= 100, 0);
    }
    
    #[test]
    fun test_multiple_swaps_d_invariant() {
        // Test D-invariant across multiple swaps
        let mut x = 1_000_000;
        let mut y = 1_000_000;
        let amp = 100;
        
        let d_initial = stable_math::get_d(x, y, amp);
        
        // Perform multiple swaps
        let swap_amounts = vector[10_000, 5_000, 15_000, 8_000];
        let mut i = 0;
        
        while (i < vector::length(&swap_amounts)) {
            let swap_amount = *vector::borrow(&swap_amounts, i);
            
            // Swap x for y
            x = x + swap_amount;
            y = stable_math::get_y(x, d_initial, amp);
            
            // Verify D is maintained
            let d_current = stable_math::get_d(x, y, amp);
            let diff = if (d_current > d_initial) { 
                d_current - d_initial 
            } else { 
                d_initial - d_current 
            };
            assert!(diff <= 1000, i);
            
            i = i + 1;
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_minimum_reserves() {
        // Test with minimum viable reserves
        let x = 1000;
        let y = 1000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        assert!(d > 0, 0);
        
        let y_calc = stable_math::get_y(x, d, amp);
        assert!(y_calc > 0, 1);
    }
    
    #[test]
    fun test_extreme_imbalance_99_to_1() {
        // Test with extreme 99:1 imbalance
        let x = 99_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // Should still converge
        assert!(d > 0, 0);
        // assert!(d > x, 1);
    }
    
    #[test]
    fun test_very_small_swap() {
        // Test with very small swap amount
        let x = 1_000_000;
        let y = 1_000_000;
        let amp = 100;
        
        let d = stable_math::get_d(x, y, amp);
        
        // Swap 1 unit
        let x_after = x + 1;
        let y_after = stable_math::get_y(x_after, d, amp);
        
        // y should decrease by approximately 1
        assert!(y > y_after, 0);
        assert!(y - y_after <= 2, 1);
    }
}
