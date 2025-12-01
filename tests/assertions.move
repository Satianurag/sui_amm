#[test_only]
module sui_amm::assertions {
    use sui_amm::test_utils::{Self, PoolSnapshot, StablePoolSnapshot, PositionSnapshot};

    // Error codes for assertions
    const EKInvariantViolation: u64 = 0;
    const EKNotIncreased: u64 = 1;
    const EDInvariantViolation: u64 = 2;
    const EFeeCalculationMismatch: u64 = 3;
    const EFeeDistributionMismatch: u64 = 4;
    const EFeeAccumulationMismatch: u64 = 5;
    const EPendingFeesNotZero: u64 = 6;
    const EPendingFeesMismatch: u64 = 7;
    const ELPShareMismatch: u64 = 8;
    const EInitialLiquidityMismatch: u64 = 9;
    const ESwapOutputMismatch: u64 = 10;
    const ESlippageExceeded: u64 = 11;
    const EPriceImpactExceeded: u64 = 12;
    const EValueNotConserved: u64 = 13;
    const EValueNotConservedB: u64 = 14;
    const EKOverflow: u64 = 15;
    const EReserveAZero: u64 = 16;
    const EReserveBZero: u64 = 17;
    const EGasExceeded: u64 = 18;

    // ═══════════════════════════════════════════════════════════════════════════
    // INVARIANT ASSERTIONS - Core mathematical guarantees
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// K-invariant: K_after >= K_before (must never decrease from swaps)
    /// Tolerance in absolute units (typically 1-10 for rounding)
    public fun assert_k_invariant_maintained(
        before: &PoolSnapshot,
        after: &PoolSnapshot,
        tolerance: u128
    ) {
        let (before_a, before_b) = test_utils::get_snapshot_reserves(before);
        let (after_a, after_b) = test_utils::get_snapshot_reserves(after);
        let k_before = (before_a as u128) * (before_b as u128);
        let k_after = (after_a as u128) * (after_b as u128);
        assert!(k_after + tolerance >= k_before, EKInvariantViolation);
    }
    
    /// K-invariant strict: K must increase (for liquidity additions)
    public fun assert_k_increased(
        before: &PoolSnapshot,
        after: &PoolSnapshot
    ) {
        let (before_a, before_b) = test_utils::get_snapshot_reserves(before);
        let (after_a, after_b) = test_utils::get_snapshot_reserves(after);
        let k_before = (before_a as u128) * (before_b as u128);
        let k_after = (after_a as u128) * (after_b as u128);
        assert!(k_after > k_before, EKNotIncreased);
    }
    
    /// K-invariant strict: K must decrease (for liquidity removals)
    public fun assert_k_decreased(
        before: &PoolSnapshot,
        after: &PoolSnapshot
    ) {
        let (before_a, before_b) = test_utils::get_snapshot_reserves(before);
        let (after_a, after_b) = test_utils::get_snapshot_reserves(after);
        let k_before = (before_a as u128) * (before_b as u128);
        let k_after = (after_a as u128) * (after_b as u128);
        assert!(k_after < k_before, EKInvariantViolation);
    }
    
    /// D-invariant for StableSwap: D_after >= D_before
    public fun assert_d_invariant_maintained(
        before: &StablePoolSnapshot,
        after: &StablePoolSnapshot
    ) {
        let d_before = test_utils::get_stable_snapshot_d(before);
        let d_after = test_utils::get_stable_snapshot_d(after);
        assert!(d_after >= d_before, EDInvariantViolation);
    }
    
    /// D-invariant strict: D must increase (for liquidity additions)
    public fun assert_d_increased(
        before: &StablePoolSnapshot,
        after: &StablePoolSnapshot
    ) {
        let d_before = test_utils::get_stable_snapshot_d(before);
        let d_after = test_utils::get_stable_snapshot_d(after);
        assert!(d_after > d_before, EDInvariantViolation);
    }
    
    /// D-invariant strict: D must decrease (for liquidity removals)
    public fun assert_d_decreased(
        before: &StablePoolSnapshot,
        after: &StablePoolSnapshot
    ) {
        let d_before = test_utils::get_stable_snapshot_d(before);
        let d_after = test_utils::get_stable_snapshot_d(after);
        assert!(d_after < d_before, EDInvariantViolation);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE ASSERTIONS - Fee calculation correctness
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify fee calculation: fee = amount * fee_bps / 10000
    public fun assert_fee_calculation(
        amount_in: u64,
        fee_bps: u64,
        actual_fee: u64,
        tolerance: u64
    ) {
        let expected_fee = ((amount_in as u128) * (fee_bps as u128) / 10000) as u64;
        let diff = if (actual_fee > expected_fee) { 
            actual_fee - expected_fee 
        } else { 
            expected_fee - actual_fee 
        };
        assert!(diff <= tolerance, EFeeCalculationMismatch);
    }
    
    /// Verify fee distribution: protocol + creator + lp = total
    public fun assert_fee_distribution_complete(
        total_fee: u64,
        protocol_fee: u64,
        creator_fee: u64,
        lp_fee: u64
    ) {
        assert!(protocol_fee + creator_fee + lp_fee == total_fee, EFeeDistributionMismatch);
    }
    
    /// Verify fee accumulation increased correctly
    public fun assert_fee_accumulation(
        before: &PoolSnapshot,
        after: &PoolSnapshot,
        expected_lp_fee: u64,
        tolerance: u128
    ) {
        let before_liquidity = test_utils::get_snapshot_liquidity(before);
        if (before_liquidity == 0) {
            return // Skip if no liquidity
        };
        
        let (before_acc_a, _) = test_utils::get_snapshot_acc_fees(before);
        let (after_acc_a, _) = test_utils::get_snapshot_acc_fees(after);
        let expected_increase = (expected_lp_fee as u128) * 1_000_000_000_000 / (before_liquidity as u128);
        let actual_increase = after_acc_a - before_acc_a;
        let diff = if (actual_increase > expected_increase) {
            actual_increase - expected_increase
        } else {
            expected_increase - actual_increase
        };
        assert!(diff <= tolerance, EFeeAccumulationMismatch);
    }
    
    /// Verify fee accumulation increased for both tokens
    public fun assert_fee_accumulation_both(
        before: &PoolSnapshot,
        after: &PoolSnapshot,
        expected_lp_fee_a: u64,
        expected_lp_fee_b: u64,
        tolerance: u128
    ) {
        let before_liquidity = test_utils::get_snapshot_liquidity(before);
        if (before_liquidity == 0) {
            return // Skip if no liquidity
        };
        
        let (before_acc_a, before_acc_b) = test_utils::get_snapshot_acc_fees(before);
        let (after_acc_a, after_acc_b) = test_utils::get_snapshot_acc_fees(after);
        
        // Check token A
        let expected_increase_a = (expected_lp_fee_a as u128) * 1_000_000_000_000 / (before_liquidity as u128);
        let actual_increase_a = after_acc_a - before_acc_a;
        let diff_a = if (actual_increase_a > expected_increase_a) {
            actual_increase_a - expected_increase_a
        } else {
            expected_increase_a - actual_increase_a
        };
        assert!(diff_a <= tolerance, EFeeAccumulationMismatch);
        
        // Check token B
        let expected_increase_b = (expected_lp_fee_b as u128) * 1_000_000_000_000 / (before_liquidity as u128);
        let actual_increase_b = after_acc_b - before_acc_b;
        let diff_b = if (actual_increase_b > expected_increase_b) {
            actual_increase_b - expected_increase_b
        } else {
            expected_increase_b - actual_increase_b
        };
        assert!(diff_b <= tolerance, EFeeAccumulationMismatch);
    }
    
    /// Verify no fee double-claiming possible
    public fun assert_no_pending_fees(
        position: &PositionSnapshot
    ) {
        let (pending_a, pending_b) = test_utils::get_position_snapshot_pending_fees(position);
        assert!(pending_a == 0, EPendingFeesNotZero);
        assert!(pending_b == 0, EPendingFeesNotZero);
    }
    
    /// Verify pending fees match expected
    public fun assert_pending_fees(
        position: &PositionSnapshot,
        expected_fee_a: u64,
        expected_fee_b: u64,
        tolerance: u64
    ) {
        let (pending_a, pending_b) = test_utils::get_position_snapshot_pending_fees(position);
        let diff_a = if (pending_a > expected_fee_a) {
            pending_a - expected_fee_a
        } else {
            expected_fee_a - pending_a
        };
        assert!(diff_a <= tolerance, EPendingFeesMismatch);
        
        let diff_b = if (pending_b > expected_fee_b) {
            pending_b - expected_fee_b
        } else {
            expected_fee_b - pending_b
        };
        assert!(diff_b <= tolerance, EPendingFeesMismatch);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LP SHARE ASSERTIONS - Liquidity distribution fairness
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify LP share is proportional to contribution
    public fun assert_lp_share_proportional(
        lp_liquidity: u64,
        total_liquidity: u64,
        expected_share_bps: u64,
        tolerance_bps: u64
    ) {
        if (total_liquidity == 0) {
            return // Skip if no liquidity
        };
        
        let actual_share_bps = ((lp_liquidity as u128) * 10000 / (total_liquidity as u128)) as u64;
        let diff = if (actual_share_bps > expected_share_bps) {
            actual_share_bps - expected_share_bps
        } else {
            expected_share_bps - actual_share_bps
        };
        assert!(diff <= tolerance_bps, ELPShareMismatch);
    }
    
    /// Verify initial liquidity calculation: sqrt(a * b) - MINIMUM_LIQUIDITY
    public fun assert_initial_liquidity_correct(
        amount_a: u64,
        amount_b: u64,
        minted_liquidity: u64,
        minimum_liquidity: u64
    ) {
        // Calculate sqrt(a * b)
        let product = (amount_a as u128) * (amount_b as u128);
        let sqrt_product = sqrt_u128(product);
        let expected = if (sqrt_product > (minimum_liquidity as u128)) {
            (sqrt_product - (minimum_liquidity as u128)) as u64
        } else {
            0
        };
        assert!(minted_liquidity == expected, EInitialLiquidityMismatch);
    }
    
    /// Verify subsequent liquidity minting is proportional
    public fun assert_subsequent_liquidity_correct(
        amount_a: u64,
        amount_b: u64,
        reserve_a: u64,
        reserve_b: u64,
        total_supply: u64,
        minted_liquidity: u64,
        tolerance: u64
    ) {
        if (reserve_a == 0 || reserve_b == 0 || total_supply == 0) {
            return // Skip if invalid state
        };
        
        let liquidity_a = ((amount_a as u128) * (total_supply as u128) / (reserve_a as u128)) as u64;
        let liquidity_b = ((amount_b as u128) * (total_supply as u128) / (reserve_b as u128)) as u64;
        let expected = if (liquidity_a < liquidity_b) { liquidity_a } else { liquidity_b };
        
        let diff = if (minted_liquidity > expected) {
            minted_liquidity - expected
        } else {
            expected - minted_liquidity
        };
        assert!(diff <= tolerance, EInitialLiquidityMismatch);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP OUTPUT ASSERTIONS - AMM formula correctness
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify constant product swap output formula
    public fun assert_swap_output_correct(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        fee_bps: u64,
        actual_output: u64,
        tolerance: u64
    ) {
        if (reserve_in == 0 || reserve_out == 0) {
            return // Skip if invalid state
        };
        
        let amount_in_after_fee = amount_in - (((amount_in as u128) * (fee_bps as u128) / 10000) as u64);
        let expected_output = ((amount_in_after_fee as u128) * (reserve_out as u128) / 
            ((reserve_in as u128) + (amount_in_after_fee as u128))) as u64;
        let diff = if (actual_output > expected_output) {
            actual_output - expected_output
        } else {
            expected_output - actual_output
        };
        assert!(diff <= tolerance, ESwapOutputMismatch);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SLIPPAGE & PRICE IMPACT ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify slippage within tolerance
    public fun assert_slippage_within(
        expected_out: u64,
        actual_out: u64,
        max_slippage_bps: u64
    ) {
        if (expected_out == 0) return;
        
        let slippage_bps = if (actual_out >= expected_out) {
            0
        } else {
            (((expected_out - actual_out) as u128) * 10000 / (expected_out as u128)) as u64
        };
        assert!(slippage_bps <= max_slippage_bps, ESlippageExceeded);
    }
    
    /// Verify price impact within pool limits
    public fun assert_price_impact_within(
        impact_bps: u64,
        max_impact_bps: u64
    ) {
        assert!(impact_bps <= max_impact_bps, EPriceImpactExceeded);
    }
    
    /// Calculate and verify price impact
    public fun assert_price_impact_calculated(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        actual_output: u64,
        max_impact_bps: u64
    ) {
        if (reserve_in == 0 || reserve_out == 0) {
            return // Skip if invalid state
        };
        
        // Ideal output without price impact: amount_in * reserve_out / reserve_in
        let ideal_output = ((amount_in as u128) * (reserve_out as u128) / (reserve_in as u128)) as u64;
        
        if (ideal_output == 0) return;
        
        // Price impact = (1 - actual / ideal) * 10000
        let impact_bps = if (actual_output >= ideal_output) {
            0
        } else {
            (((ideal_output - actual_output) as u128) * 10000 / (ideal_output as u128)) as u64
        };
        
        assert!(impact_bps <= max_impact_bps, EPriceImpactExceeded);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VALUE CONSERVATION ASSERTIONS - No value creation/destruction
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify total value in system is conserved (reserves + fees)
    public fun assert_value_conserved(
        before: &PoolSnapshot,
        after: &PoolSnapshot,
        external_in_a: u64,
        external_in_b: u64,
        external_out_a: u64,
        external_out_b: u64
    ) {
        let (before_reserve_a, before_reserve_b) = test_utils::get_snapshot_reserves(before);
        let (before_fee_a, before_fee_b) = test_utils::get_snapshot_fees(before);
        let (before_protocol_a, before_protocol_b) = test_utils::get_snapshot_protocol_fees(before);
        let (after_reserve_a, after_reserve_b) = test_utils::get_snapshot_reserves(after);
        let (after_fee_a, after_fee_b) = test_utils::get_snapshot_fees(after);
        let (after_protocol_a, after_protocol_b) = test_utils::get_snapshot_protocol_fees(after);
        
        let total_a_before = before_reserve_a + before_fee_a + before_protocol_a;
        let total_b_before = before_reserve_b + before_fee_b + before_protocol_b;
        let total_a_after = after_reserve_a + after_fee_a + after_protocol_a;
        let total_b_after = after_reserve_b + after_fee_b + after_protocol_b;
        
        assert!(total_a_before + external_in_a == total_a_after + external_out_a, EValueNotConserved);
        assert!(total_b_before + external_in_b == total_b_after + external_out_b, EValueNotConservedB);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OVERFLOW/UNDERFLOW ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify no overflow in K calculation
    public fun assert_k_no_overflow(reserve_a: u64, reserve_b: u64) {
        let max_safe = 340282366920938463463374607431768211455u128 / 10000;
        let k = (reserve_a as u128) * (reserve_b as u128);
        assert!(k <= max_safe, EKOverflow);
    }
    
    /// Verify reserves never reach zero
    public fun assert_reserves_positive(
        after: &PoolSnapshot
    ) {
        let (reserve_a, reserve_b) = test_utils::get_snapshot_reserves(after);
        assert!(reserve_a > 0, EReserveAZero);
        assert!(reserve_b > 0, EReserveBZero);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GAS CONSUMPTION ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Verify gas consumption is within target
    public fun assert_gas_within_target(
        actual_gas: u64,
        target_gas: u64
    ) {
        assert!(actual_gas <= target_gas, EGasExceeded);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Calculate square root of u128 (for liquidity calculations)
    fun sqrt_u128(y: u128): u128 {
        if (y < 4) {
            if (y == 0) {
                0
            } else {
                1
            }
        } else {
            let mut z = y;
            let mut x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            z
        }
    }
}
