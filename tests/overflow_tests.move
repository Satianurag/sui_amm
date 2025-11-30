#[test_only]
module sui_amm::overflow_tests {
    use sui_amm::stable_math;

    #[test]
    fun test_get_d_near_overflow() {
        // Test with large reserves within u64 range
        // u64::MAX is ~1.84e19
        
        let x: u64 = 9_000_000_000_000_000_000; // 0.9e19
        let y: u64 = 9_000_000_000_000_000_000; // 0.9e19
        let amp: u64 = 100;

        // This should NOT abort with the fix
        let d = stable_math::get_d(x, y, amp);
        
        // D should be roughly sum for balanced pool
        assert!(d >= 17_999_999_999_999_999_000, 0);
        assert!(d <= 18_000_000_000_000_001_000, 0);
    }

    #[test]
    fun test_get_y_near_overflow() {
        // Similar setup for get_y
        let x: u64 = 9_000_000_000_000_000_000; // 0.9e19
        let d: u64 = 18_000_000_000_000_000_000; // 1.8e19
        let amp: u64 = 100;

        // This should NOT abort
        let y = stable_math::get_y(x, d, amp);
        
        // Should be close to x for balanced pool
        assert!(y >= 8_999_999_999_999_999_000, 0);
        assert!(y <= 9_000_000_000_000_001_000, 0);
    }
    
    #[test]
    fun test_extreme_imbalance_overflow() {
        // One small, one huge
        // This causes D*D/x to be very large if not handled carefully
        let x: u64 = 1_000_000_000_000_000_000; // 1e18
        let y: u64 = 10_000_000_000_000_000_000; // 1e19
        let amp: u64 = 100;
        
        let d = stable_math::get_d(x, y, amp);
        // For extreme imbalance, D can be less than the larger reserve
        // But it should be positive and less than sum
        assert!(d > 0, 0);
        assert!(d <= x + y, 0);
        
        let y_calc = stable_math::get_y(x, d, amp);
        // Should be close to original y
        // Allow some error due to precision loss in large numbers
        let diff = if (y > y_calc) y - y_calc else y_calc - y;
        assert!(diff < 1_000_000_000_000, 0); // Tolerance 1e12 (0.0001% of 1e19)
    }
}
