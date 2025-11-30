#[test_only]
module sui_amm::math_edge_tests {
    use sui_amm::math;

    #[test]
    fun test_sqrt_edge_cases() {
        // Test sqrt(0)
        assert!(math::sqrt(0) == 0, 0);
        
        // Test sqrt(1)
        assert!(math::sqrt(1) == 1, 1);
        
        // Test sqrt(2) and sqrt(3) 
        assert!(math::sqrt(2) == 1, 2);
        assert!(math::sqrt(3) == 1, 3);
        
        // Test sqrt(4)
        assert!(math::sqrt(4) == 2, 4);
        
        // Test large numbers
        assert!(math::sqrt(1000000) == 1000, 5);
        assert!(math::sqrt(999999) == 999, 6);
        
        // Test very large number (near u64 max would be sqrt(~18.4M))
        let large = 100000000; // 10^8
        let sqrt_large = math::sqrt(large);
        assert!(sqrt_large == 10000, 7);
    }

    #[test]
    fun test_min_edge_cases() {
        assert!(math::min(0, 0) == 0, 0);
        assert!(math::min(0, 100) == 0, 1);
        assert!(math::min(100, 0) == 0, 2);
        assert!(math::min(100, 100) == 100, 3);
        
        // Test with max values
        let max_u64 = 18446744073709551615;
        assert!(math::min(max_u64, max_u64 - 1) == max_u64 - 1, 4);
        assert!(math::min(0, max_u64) == 0, 5);
    }

    #[test]
    fun test_constant_product_output() {
        // Standard case
        let output = math::calculate_constant_product_output(
            1000,   // input_amount
            10000,  // input_reserve  
            10000,  // output_reserve
            30      // fee_percent (0.3%)
        );
        // Expected: ~906 (with 0.3% fee)
        assert!(output > 900 && output < 910, 0);
    }

    #[test]
    fun test_constant_product_small_amounts() {
        // Very small swap
        let output = math::calculate_constant_product_output(
            1,      // input_amount (minimum)
            1000000,// input_reserve
            1000000,// output_reserve
            30      // fee_percent
        );
        // Should get zero due to rounding
        assert!(output == 0, 0);
    }

    #[test]
    fun test_constant_product_large_amounts() {
        // Large swap with high price impact
        let output = math::calculate_constant_product_output(
            50000,  // input_amount (50% of reserve)
            100000, // input_reserve
            100000, // output_reserve
            30      // fee_percent
        );
        // Should get less than 50k due to price impact
        assert!(output < 50000, 0);
        assert!(output > 30000, 1); // But still significant
    }

    #[test]
    fun test_constant_product_zero_fee() {
        let output = math::calculate_constant_product_output(
            1000,
            10000,
            10000,
            0  // No fee
        );
        // With no fee, output should be slightly higher
        assert!(output > 900, 0);
    }

    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_constant_product_zero_input() {
        math::calculate_constant_product_output(0, 10000, 10000, 30);
    }

    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_constant_product_zero_reserve() {
        math::calculate_constant_product_output(1000, 0, 10000, 30);
    }

    #[test]
    fun test_quote() {
        // Test exact proportional quote
        let result = math::quote(100, 1000, 2000);
        assert!(result == 200, 0);
        
        // Test with small amounts
        let result2 = math::quote(1, 1000, 1000);
        assert!(result2 == 1, 1);
        
        // Test asymmetric reserves
        let result3 = math::quote(100, 10000, 5000);
        assert!(result3 == 50, 2);
    }

    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_quote_zero_amount() {
        math::quote(0, 1000, 1000);
    }

    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_quote_zero_reserve_a() {
        math::quote(100, 0, 1000);
    }

    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_quote_zero_reserve_b() {
        math::quote(100, 1000, 0);
    }

    #[test]
    fun test_quote_precision() {
        // Test precision with division that doesn't result in whole number
        let result = math::quote(333, 1000, 1000);
        assert!(result == 333, 0);
        
        // Test rounding behavior
        let result2 = math::quote(1, 3, 1);
        assert!(result2 == 0, 1); // Rounds down
    }
}
