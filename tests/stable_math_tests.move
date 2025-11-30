#[test_only]
module sui_amm::stable_math_tests {
    use sui_amm::stable_math;

    #[test]
    fun test_get_d() {
        // Balanced
        // x=1000, y=1000, A=100 -> D=2000
        let d = stable_math::get_d(1000, 1000, 100);
        assert!(d == 2000, 0);

        // x=1000000, y=1000000, A=100 -> D=2000000
        let d2 = stable_math::get_d(1000000, 1000000, 100);
        assert!(d2 == 2000000, 1);
    }

    #[test]
    fun test_get_y() {
        // D=2000, A=100, x=1000 -> y=1000
        let y = stable_math::get_y(1000, 2000, 100);
        assert!(y == 1000, 0);

        // D=2000, A=100, x=1010 -> y should be slightly less than 990 because of slippage
        // In Constant Product: 1000*1000 = 1,000,000. 1,000,000 / 1010 = 990.099...
        // In StableSwap, it should be closer to 990 (linear).
        // Let's just check it returns a value and it satisfies D roughly.
        let y2 = stable_math::get_y(1010, 2000, 100);
        
        // Calculate D back from x=1010, y=y2
        let d_check = stable_math::get_d(1010, y2, 100);
        
        // D should be very close to 2000
        // Allow small error due to integer math
        assert!(d_check >= 1999 && d_check <= 2001, 1);
    }
    
    #[test]
    fun test_amplification() {
        // Higher A = closer to constant sum (linear)
        // Lower A = closer to constant product
        
        // A = 1 (Constant Product-ish)
        // x=1000, y=1000 -> D=2000
        // x=1100 -> y?
        let y_low_amp = stable_math::get_y(1100, 2000, 1);
        
        // A = 1000 (Constant Sum-ish)
        let y_high_amp = stable_math::get_y(1100, 2000, 1000);
        
        // With high amp, y should be closer to 900 (2000 - 1100)
        // With low amp, y should be closer to 909 (1000*1000/1100)
        
        // 900 < y_high_amp < y_low_amp < 909
        assert!(y_high_amp < y_low_amp, 0);
        assert!(y_high_amp >= 900, 1);
    }
}
