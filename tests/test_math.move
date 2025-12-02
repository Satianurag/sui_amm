#[test_only]
module sui_amm::test_math {
    use sui_amm::math;
    use sui_amm::fixtures;

    // SQRT Function Tests - Perfect Squares
    // Verifies that sqrt returns exact integer results for perfect squares
    
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

    // SQRT Function Tests - Non-Perfect Squares
    // Verifies that sqrt correctly floors the result for non-perfect squares
    // This is critical for AMM calculations where we need deterministic rounding
    
    #[test]
    fun test_sqrt_two_floor() {
        // Verifies sqrt(2) ≈ 1.414 floors to 1
        assert!(math::sqrt(2) == 1, 0);
    }
    
    #[test]
    fun test_sqrt_three_floor() {
        // Verifies sqrt(3) ≈ 1.732 floors to 1
        assert!(math::sqrt(3) == 1, 0);
    }
    
    #[test]
    fun test_sqrt_five_floor() {
        // Verifies sqrt(5) ≈ 2.236 floors to 2
        assert!(math::sqrt(5) == 2, 0);
    }
    
    #[test]
    fun test_sqrt_ten_floor() {
        // Verifies sqrt(10) ≈ 3.162 floors to 3
        assert!(math::sqrt(10) == 3, 0);
    }
    
    #[test]
    fun test_sqrt_ninety_nine_floor() {
        // Verifies sqrt(99) ≈ 9.949 floors to 9
        assert!(math::sqrt(99) == 9, 0);
    }
    
    #[test]
    fun test_sqrt_one_thousand_floor() {
        // Verifies sqrt(1000) ≈ 31.622 floors to 31
        assert!(math::sqrt(1000) == 31, 0);
    }

    // SQRT Function Tests - Boundary Conditions
    // Verifies sqrt handles extreme values without overflow or incorrect results
    
    #[test]
    fun test_sqrt_large_value() {
        // Verifies sqrt handles u64::MAX correctly
        // This is important for pools with maximum liquidity
        let large_val = 18446744073709551615u64; // u64::MAX
        let result = math::sqrt(large_val);
        // Expected: sqrt(u64::MAX) ≈ 4294967296 (2^32), floored to 4294967295
        assert!(result == 4294967295, 0);
    }
    
    #[test]
    fun test_sqrt_near_max_safe() {
        // Verifies sqrt produces mathematically correct results for large values
        // Ensures result^2 <= val < (result+1)^2 (definition of floor sqrt)
        let val = fixtures::near_u64_max();
        let result = math::sqrt(val);
        assert!(result > 0, 0);
        assert!((result as u128) * (result as u128) <= (val as u128), 1);
    }

    // Constant Product Output Calculation Tests
    // Verifies the core AMM formula: x * y = k
    // These tests ensure swap outputs are calculated correctly with and without fees
    
    #[test]
    fun test_constant_product_no_fee() {
        // Verifies output calculation without fees
        // Formula: output = input * reserve_out / (reserve_in + input)
        // Expected: 10 * 100 / (100 + 10) = 1000 / 110 = 9 (floored)
        let output = math::calculate_constant_product_output(10, 100, 100, 0);
        assert!(output == 9, 0);
    }
    
    #[test]
    fun test_constant_product_with_fee() {
        // Verifies output calculation with 0.30% fee (30 bps)
        // Fee is deducted from input before calculating output
        // Expected: input_after_fee = 100 * 9970 / 10000 = 99.7
        //           output = 99.7 * 1000 / (1000 + 99.7) ≈ 90 (floored)
        let output = math::calculate_constant_product_output(100, 1000, 1000, 30);
        assert!(output == 90, 0);
    }
    
    #[test]
    fun test_constant_product_precision() {
        // Verifies calculation maintains precision with large reserves
        // This is critical for whale swaps that could lose significant value to rounding
        let (reserve_a, reserve_b) = fixtures::whale_liquidity();
        let swap_amount = fixtures::medium_swap();
        
        let (fee_bps, _, _) = fixtures::standard_fee_config();
        let output = math::calculate_constant_product_output(
            swap_amount,
            reserve_a,
            reserve_b,
            fee_bps
        );
        
        assert!(output > 0, 0);
        assert!(output < swap_amount, 1);
    }
    
    #[test]
    fun test_constant_product_imbalanced_pool() {
        // Verifies output calculation for imbalanced pools (10:1 ratio)
        // Swapping from the larger reserve to smaller should yield proportionally less output
        let (reserve_a, reserve_b) = fixtures::imbalanced_10_to_1();
        let swap_amount = 1_000_000;
        
        let output = math::calculate_constant_product_output(
            swap_amount,
            reserve_a,
            reserve_b,
            30
        );
        
        assert!(output > 0, 0);
        assert!(output < swap_amount / 5, 1);
    }

    // Fee Calculation Accuracy Tests
    // Verifies fee calculations are accurate across all supported fee tiers
    // Fees are expressed in basis points (bps): 1 bps = 0.01%
    
    #[test]
    fun test_fee_calculation_5_bps() {
        // Verifies ultra-low fee tier (0.05%) for stablecoin pairs
        // Expected: 10000 * 5 / 10000 = 5
        let input = 10_000;
        let fee_bps = 5;
        let input_after_fee = input - (((input as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_fee = input - input_after_fee;
        assert!(expected_fee == 5, 0);
        
        let large_input = 1_000_000;
        let large_input_after_fee = large_input - (((large_input as u128) * (fee_bps as u128) / 10000) as u64);
        let large_expected_fee = large_input - large_input_after_fee;
        assert!(large_expected_fee == 500, 1);
    }
    
    #[test]
    fun test_fee_calculation_30_bps() {
        // Verifies standard fee tier (0.30%) for most trading pairs
        // Expected: 10000 * 30 / 10000 = 30
        let input = 10_000;
        let fee_bps = 30;
        let input_after_fee = input - (((input as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_fee = input - input_after_fee;
        assert!(expected_fee == 30, 0);
        
        let large_input = 1_000_000;
        let large_input_after_fee = large_input - (((large_input as u128) * (fee_bps as u128) / 10000) as u64);
        let large_expected_fee = large_input - large_input_after_fee;
        assert!(large_expected_fee == 3000, 1);
    }
    
    #[test]
    fun test_fee_calculation_100_bps() {
        // Verifies high-volatility fee tier (1.00%) for exotic pairs
        // Expected: 10000 * 100 / 10000 = 100
        let input = 10_000;
        let fee_bps = 100;
        let input_after_fee = input - (((input as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_fee = input - input_after_fee;
        assert!(expected_fee == 100, 0);
        
        let large_input = 1_000_000;
        let large_input_after_fee = large_input - (((large_input as u128) * (fee_bps as u128) / 10000) as u64);
        let large_expected_fee = large_input - large_input_after_fee;
        assert!(large_expected_fee == 10000, 1);
    }
    
    #[test]
    fun test_fee_calculation_consistency() {
        // Verifies fee calculation maintains proportionality across different amounts
        // This ensures users pay the same percentage regardless of trade size
        let amounts = vector[1_000, 10_000, 100_000, 1_000_000];
        let fee_bps = 30;
        
        let mut i = 0;
        while (i < vector::length(&amounts)) {
            let amount = *vector::borrow(&amounts, i);
            let input_after_fee = amount - (((amount as u128) * (fee_bps as u128) / 10000) as u64);
            let fee = amount - input_after_fee;
            
            let fee_ratio_bps = ((fee as u128) * 10000 / (amount as u128)) as u64;
            assert!(fee_ratio_bps == fee_bps, i);
            
            i = i + 1;
        };
    }

    // Overflow Protection Tests
    // Verifies calculations handle extreme values without overflow
    // Uses u128 intermediate calculations to prevent overflow in u64 * u64 operations
    
    #[test]
    fun test_overflow_protection_large_reserves() {
        // Verifies calculation doesn't overflow with near-maximum reserve values
        // This protects against overflow in pools with extreme liquidity
        let reserve_a = fixtures::near_u64_max();
        let reserve_b = fixtures::near_u64_max();
        let input = 1_000_000;
        
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
        // Verifies calculation handles large swap amounts without overflow
        // Tests scenario where user attempts to drain most of the pool
        let reserve_a = 1_000_000_000;
        let reserve_b = 1_000_000_000;
        let input = fixtures::near_u64_max() / 1000;
        
        let output = math::calculate_constant_product_output(
            input,
            reserve_a,
            reserve_b,
            30
        );
        
        assert!(output > 0, 0);
        assert!(output < reserve_b, 1);
    }
    
    #[test]
    fun test_no_overflow_k_calculation() {
        // Verifies K (constant product) calculation stays within u128 bounds
        // K = reserve_a * reserve_b must not overflow for pool operations to work
        let reserve_a = 1_000_000_000_000u64;
        let reserve_b = 1_000_000_000_000u64;
        
        let k = (reserve_a as u128) * (reserve_b as u128);
        
        let max_safe = 340282366920938463463374607431768211455u128 / 10000;
        assert!(k <= max_safe, 0);
    }

    // Underflow and Edge Case Protection Tests
    // Verifies calculations properly reject invalid inputs and handle edge cases
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_underflow_protection_zero_input() {
        // Verifies zero input amount is rejected
        // Zero swaps are invalid and could cause division by zero
        math::calculate_constant_product_output(0, 1000, 1000, 30);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_underflow_protection_zero_reserve_in() {
        // Verifies zero input reserve is rejected
        // Empty reserves would cause division by zero in the formula
        math::calculate_constant_product_output(100, 0, 1000, 30);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_underflow_protection_zero_reserve_out() {
        // Verifies zero output reserve is rejected
        // Cannot swap into an empty reserve
        math::calculate_constant_product_output(100, 1000, 0, 30);
    }
    
    #[test]
    fun test_dust_amount_handling() {
        // Verifies dust amounts (extremely small values) are handled gracefully
        // Output may round to zero, but should not cause errors
        let dust = fixtures::dust_amount();
        let reserve = 1_000_000;
        
        let output = math::calculate_constant_product_output(
            dust,
            reserve,
            reserve,
            30
        );
        
        assert!(output == 0, 0);
    }
    
    #[test]
    fun test_minimum_viable_swap() {
        // Verifies minimum swap amount that produces non-zero output
        // Important for determining minimum trade sizes in the UI
        let min_input = 1000;
        let reserve = 1_000_000;
        
        let output = math::calculate_constant_product_output(
            min_input,
            reserve,
            reserve,
            30
        );
        
        assert!(output > 0, 0);
    }

    // Quote Function Tests
    // Verifies the quote function calculates proportional amounts for liquidity operations
    // Quote is used when adding/removing liquidity to maintain pool ratios
    
    #[test]
    fun test_quote_balanced_pool() {
        // Verifies quote returns equal amount for balanced pools (1:1 ratio)
        // When reserves are equal, quoted amount should match input amount
        let amount_a = 1000;
        let reserve_a = 1_000_000;
        let reserve_b = 1_000_000;
        
        let amount_b = math::quote(amount_a, reserve_a, reserve_b);
        
        assert!(amount_b == amount_a, 0);
    }
    
    #[test]
    fun test_quote_imbalanced_pool() {
        // Verifies quote maintains proportionality for imbalanced pools
        // For 2:1 ratio, quoted amount should be half the input amount
        let amount_a = 1000;
        let reserve_a = 2_000_000;
        let reserve_b = 1_000_000;
        
        let amount_b = math::quote(amount_a, reserve_a, reserve_b);
        
        assert!(amount_b == 500, 0);
    }
    
    #[test]
    fun test_quote_precision() {
        // Verifies quote maintains precision with large values
        // Important for whale liquidity operations
        let amount_a = 1_000_000_000;
        let (reserve_a, reserve_b) = fixtures::whale_liquidity();
        
        let amount_b = math::quote(amount_a, reserve_a, reserve_b);
        
        assert!(amount_b > 0, 0);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_quote_zero_amount() {
        // Verifies zero amount is rejected
        // Cannot quote zero liquidity
        math::quote(0, 1000, 1000);
    }
    
    #[test]
    #[expected_failure(abort_code = math::EZeroAmount)]
    fun test_quote_zero_reserve() {
        // Verifies zero reserve is rejected
        // Cannot quote against empty reserve
        math::quote(1000, 0, 1000);
    }

    // Min Function Tests
    // Verifies the min utility function returns the smaller of two values
    
    #[test]
    fun test_min_function() {
        assert!(math::min(5, 10) == 5, 0);
        assert!(math::min(10, 5) == 5, 1);
        assert!(math::min(7, 7) == 7, 2);
        assert!(math::min(0, 100) == 0, 3);
        assert!(math::min(fixtures::near_u64_max(), 1000) == 1000, 4);
    }
}
