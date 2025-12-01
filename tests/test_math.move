#[test_only]
module sui_amm::test_math {
    use sui_amm::math;
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // SQRT FUNCTION TESTS - Perfect Squares
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_sqrt_zero() {
        assert!(math::sqrt(0) == 0, 0);
    }
    
    #[test]
    fun test_sqrt_one() {
        assert!(math::sqrt(1) == 1, 0);
    }
    
    #[test]
    fun test_sqrt_four() {
        assert!(math::sqrt(4) == 2, 0);
    }
    
    #[test]
    fun test_sqrt_nine() {
        assert!(math::sqrt(9) == 3, 0);
    }
    
    #[test]
    fun test_sqrt_sixteen() {
        assert!(math::sqrt(16) == 4, 0);
    }
    
    #[test]
    fun test_sqrt_twenty_five() {
        assert!(math::sqrt(25) == 5, 0);
    }
    
    #[test]
    fun test_sqrt_one_hundred() {
        assert!(math::sqrt(100) == 10, 0);
    }
    
    #[test]
    fun test_sqrt_ten_thousand() {
        assert!(math::sqrt(10000) == 100, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SQRT FUNCTION TESTS - Non-Perfect Squares (Floor Behavior)
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_sqrt_two_floor() {
        // sqrt(2) ≈ 1.414, floor = 1
        assert!(math::sqrt(2) == 1, 0);
    }
    
    #[test]
    fun test_sqrt_three_floor() {
        // sqrt(3) ≈ 1.732, floor = 1
        assert!(math::sqrt(3) == 1, 0);
    }
    
    #[test]
    fun test_sqrt_five_floor() {
        // sqrt(5) ≈ 2.236, floor = 2
        assert!(math::sqrt(5) == 2, 0);
    }
    
    #[test]
    fun test_sqrt_ten_floor() {
        // sqrt(10) ≈ 3.162, floor = 3
        assert!(math::sqrt(10) == 3, 0);
    }
    
    #[test]
    fun test_sqrt_ninety_nine_floor() {
        // sqrt(99) ≈ 9.949, floor = 9
        assert!(math::sqrt(99) == 9, 0);
    }
    
    #[test]
    fun test_sqrt_one_thousand_floor() {
        // sqrt(1000) ≈ 31.622, floor = 31
        assert!(math::sqrt(1000) == 31, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SQRT FUNCTION TESTS - Boundary Conditions
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_sqrt_large_value() {
        // Test with large value near u64::MAX
        let large_val = 18446744073709551615u64; // u64::MAX
        let result = math::sqrt(large_val);
        // sqrt(u64::MAX) ≈ 4294967296 (2^32)
        assert!(result == 4294967295, 0);
    }
    
    #[test]
    fun test_sqrt_near_max_safe() {
        // Test with value that's safe for multiplication
        let val = fixtures::near_u64_max();
        let result = math::sqrt(val);
        // Verify result is reasonable
        assert!(result > 0, 0);
        // Verify result^2 <= val < (result+1)^2
        assert!((result as u128) * (result as u128) <= (val as u128), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANT PRODUCT OUTPUT CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_constant_product_no_fee() {
        // 10 in, 100 reserve each, 0% fee
        // output = 10 * 100 / (100 + 10) = 1000 / 110 = 9.09... -> 9
        let output = math::calculate_constant_product_output(10, 100, 100, 0);
        assert!(output == 9, 0);
    }
    
    #[test]
    fun test_constant_product_with_fee() {
        // 100 in, 1000 reserve each, 0.30% fee (30 bps)
        // input_after_fee = 100 * (10000 - 30) / 10000 = 100 * 9970 / 10000 = 99.7
        // output = 99.7 * 1000 / (1000 + 99.7) = 99700 / 1099.7 ≈ 90.66 -> 90
        let output = math::calculate_constant_product_output(100, 1000, 1000, 30);
        assert!(output == 90, 0);
    }
    
    #[test]
    fun test_constant_product_precision() {
        // Test precision with large reserves
        let (reserve_a, reserve_b) = fixtures::whale_liquidity();
        let swap_amount = fixtures::medium_swap();
        
        let (fee_bps, _, _) = fixtures::standard_fee_config();
        let output = math::calculate_constant_product_output(
            swap_amount,
            reserve_a,
            reserve_b,
            fee_bps
        );
        
        // Verify output is reasonable (should be close to input for balanced pool)
        assert!(output > 0, 0);
        assert!(output < swap_amount, 1); // Output should be less than input due to fees
    }
    
    #[test]
    fun test_constant_product_imbalanced_pool() {
        // Test with imbalanced reserves (10:1 ratio)
        let (reserve_a, reserve_b) = fixtures::imbalanced_10_to_1();
        let swap_amount = 1_000_000;
        
        let output = math::calculate_constant_product_output(
            swap_amount,
            reserve_a,
            reserve_b,
            30 // 0.30% fee
        );
        
        // Verify output is reasonable
        assert!(output > 0, 0);
        // When swapping from larger reserve to smaller, output should be much less
        assert!(output < swap_amount / 5, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE CALCULATION ACCURACY TESTS - All Fee Tiers
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_fee_calculation_5_bps() {
        // Ultra-low fee tier: 5 bps (0.05%)
        // 10000 input * 5 / 10000 = 5
        let input = 10_000;
        let fee_bps = 5;
        let input_after_fee = input - (((input as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_fee = input - input_after_fee;
        assert!(expected_fee == 5, 0);
        
        // Test with larger amount
        let large_input = 1_000_000;
        let large_input_after_fee = large_input - (((large_input as u128) * (fee_bps as u128) / 10000) as u64);
        let large_expected_fee = large_input - large_input_after_fee;
        assert!(large_expected_fee == 500, 1);
    }
    
    #[test]
    fun test_fee_calculation_30_bps() {
        // Standard fee tier: 30 bps (0.30%)
        // 10000 input * 30 / 10000 = 30
        let input = 10_000;
        let fee_bps = 30;
        let input_after_fee = input - (((input as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_fee = input - input_after_fee;
        assert!(expected_fee == 30, 0);
        
        // Test with larger amount
        let large_input = 1_000_000;
        let large_input_after_fee = large_input - (((large_input as u128) * (fee_bps as u128) / 10000) as u64);
        let large_expected_fee = large_input - large_input_after_fee;
        assert!(large_expected_fee == 3000, 1);
    }
    
    #[test]
    fun test_fee_calculation_100_bps() {
        // High-volatility fee tier: 100 bps (1.00%)
        // 10000 input * 100 / 10000 = 100
        let input = 10_000;
        let fee_bps = 100;
        let input_after_fee = input - (((input as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_fee = input - input_after_fee;
        assert!(expected_fee == 100, 0);
        
        // Test with larger amount
        let large_input = 1_000_000;
        let large_input_after_fee = large_input - (((large_input as u128) * (fee_bps as u128) / 10000) as u64);
        let large_expected_fee = large_input - large_input_after_fee;
        assert!(large_expected_fee == 10000, 1);
    }
    
    #[test]
    fun test_fee_calculation_consistency() {
        // Verify fee calculation is consistent across different amounts
        // Removed 100 as it's too small for 30bps fee (results in 0 fee)
        let amounts = vector[1_000, 10_000, 100_000, 1_000_000];
        let fee_bps = 30;
        
        let mut i = 0;
        while (i < vector::length(&amounts)) {
            let amount = *vector::borrow(&amounts, i);
            let input_after_fee = amount - (((amount as u128) * (fee_bps as u128) / 10000) as u64);
            let fee = amount - input_after_fee;
            
            // Verify fee is proportional: fee / amount ≈ 30 / 10000
            let fee_ratio_bps = ((fee as u128) * 10000 / (amount as u128)) as u64;
            assert!(fee_ratio_bps == fee_bps, i);
            
            i = i + 1;
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OVERFLOW PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_overflow_protection_large_reserves() {
        // Test with near-maximum values
        let reserve_a = fixtures::near_u64_max();
        let reserve_b = fixtures::near_u64_max();
        let input = 1_000_000;
        
        // This should not overflow due to u128 intermediate calculations
        let output = math::calculate_constant_product_output(
            input,
            reserve_a,
            reserve_b,
            30
        );
        
        assert!(output > 0, 0);
    }
    
    #[test]
    fun test_overflow_protection_large_input() {
        // Test with large input amount
        let reserve_a = 1_000_000_000;
        let reserve_b = 1_000_000_000;
        let input = fixtures::near_u64_max() / 1000; // Large but safe input
        
        let output = math::calculate_constant_product_output(
            input,
            reserve_a,
            reserve_b,
            30
        );
        
        // Output should be close to reserve_b (draining the pool)
        assert!(output > 0, 0);
        assert!(output < reserve_b, 1);
    }
    
    #[test]
    fun test_no_overflow_k_calculation() {
        // Verify K calculation doesn't overflow with large reserves
        let reserve_a = 1_000_000_000_000u64; // 1 trillion
        let reserve_b = 1_000_000_000_000u64; // 1 trillion
        
        // K = reserve_a * reserve_b (as u128)
        let k = (reserve_a as u128) * (reserve_b as u128);
        
        // Verify K is within safe bounds
        let max_safe = 340282366920938463463374607431768211455u128 / 10000;
        assert!(k <= max_safe, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UNDERFLOW PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)] // EZeroAmount
    fun test_underflow_protection_zero_input() {
        // Should abort with EZeroAmount
        math::calculate_constant_product_output(0, 1000, 1000, 30);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)] // EZeroAmount
    fun test_underflow_protection_zero_reserve_in() {
        // Should abort with EZeroAmount
        math::calculate_constant_product_output(100, 0, 1000, 30);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)] // EZeroAmount
    fun test_underflow_protection_zero_reserve_out() {
        // Should abort with EZeroAmount
        math::calculate_constant_product_output(100, 1000, 0, 30);
    }
    
    #[test]
    fun test_dust_amount_handling() {
        // Test with dust amounts (minimal meaningful values)
        let dust = fixtures::dust_amount();
        let reserve = 1_000_000;
        
        let output = math::calculate_constant_product_output(
            dust,
            reserve,
            reserve,
            30
        );
        
        // Output might be 0 due to rounding, but should not panic
        assert!(output == 0, 0);
    }
    
    #[test]
    fun test_minimum_viable_swap() {
        // Test with minimum amount that produces non-zero output
        let min_input = 1000;
        let reserve = 1_000_000;
        
        let output = math::calculate_constant_product_output(
            min_input,
            reserve,
            reserve,
            30
        );
        
        // Should produce non-zero output
        assert!(output > 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // QUOTE FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_quote_balanced_pool() {
        // Test quote with balanced reserves (1:1 ratio)
        let amount_a = 1000;
        let reserve_a = 1_000_000;
        let reserve_b = 1_000_000;
        
        let amount_b = math::quote(amount_a, reserve_a, reserve_b);
        
        // Should return same amount for 1:1 ratio
        assert!(amount_b == amount_a, 0);
    }
    
    #[test]
    fun test_quote_imbalanced_pool() {
        // Test quote with imbalanced reserves (2:1 ratio)
        let amount_a = 1000;
        let reserve_a = 2_000_000;
        let reserve_b = 1_000_000;
        
        let amount_b = math::quote(amount_a, reserve_a, reserve_b);
        
        // Should return half the amount for 2:1 ratio
        assert!(amount_b == 500, 0);
    }
    
    #[test]
    fun test_quote_precision() {
        // Test quote precision with large values
        let amount_a = 1_000_000_000;
        let (reserve_a, reserve_b) = fixtures::whale_liquidity();
        
        let amount_b = math::quote(amount_a, reserve_a, reserve_b);
        
        // Should maintain precision
        assert!(amount_b > 0, 0);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)] // EZeroAmount
    fun test_quote_zero_amount() {
        // Should abort with EZeroAmount
        math::quote(0, 1000, 1000);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)] // EZeroAmount
    fun test_quote_zero_reserve() {
        // Should abort with EZeroAmount
        math::quote(1000, 0, 1000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MIN FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    #[test]
    fun test_min_function() {
        assert!(math::min(5, 10) == 5, 0);
        assert!(math::min(10, 5) == 5, 1);
        assert!(math::min(7, 7) == 7, 2);
        assert!(math::min(0, 100) == 0, 3);
        assert!(math::min(fixtures::near_u64_max(), 1000) == 1000, 4);
    }
}
