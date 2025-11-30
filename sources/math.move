module sui_amm::math {
    const EZeroAmount: u64 = 0;

    public fun sqrt(y: u64): u64 {
        if (y < 4) {
            if (y == 0) {
                0
            } else {
                1
            }
        } else {
            let z = y;
            let x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            z
        }
    }

    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    public fun calculate_constant_product_output(
        input_amount: u64,
        input_reserve: u64,
        output_reserve: u64,
        fee_percent: u64
    ): u64 {
        assert!(input_amount > 0, EZeroAmount);
        assert!(input_reserve > 0 && output_reserve > 0, EZeroAmount);

        let input_amount_with_fee = (input_amount as u128) * ((10000 - fee_percent) as u128);
        let numerator = input_amount_with_fee * (output_reserve as u128);
        let denominator = (input_reserve as u128) * 10000 + input_amount_with_fee;

        ((numerator / denominator) as u64)
    }

    public fun quote(
        amount_a: u64,
        reserve_a: u64,
        reserve_b: u64
    ): u64 {
        assert!(amount_a > 0, EZeroAmount);
        assert!(reserve_a > 0 && reserve_b > 0, EZeroAmount);

        (((amount_a as u128) * (reserve_b as u128) / (reserve_a as u128)) as u64)
    }
}
