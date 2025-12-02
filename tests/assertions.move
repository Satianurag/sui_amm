/// Assertion helpers module providing specialized assertion functions for AMM testing
/// Includes invariant checks, fee calculations, LP share verification, and value conservation
/// All assertions use configurable tolerances to account for rounding in integer arithmetic
#[test_only]
module sui_amm::assertions {
    use sui_amm::test_utils::{Self, PoolSnapshot, StablePoolSnapshot, PositionSnapshot};

    // Error codes for assertion failures
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
    
    /// Verify K-invariant (reserve_a * reserve_b) is maintained or increased after operation
    /// K must never decrease from swaps due to fees being collected
    /// Tolerance accounts for rounding in integer division (typically 1-10 units)
    /// Used to verify constant product formula correctness
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
    
    /// Verify K-invariant strictly increases after liquidity addition
    /// Adding liquidity must always increase the product of reserves
    /// No tolerance needed as this should be a strict increase
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
    
    /// Verify K-invariant strictly decreases after liquidity removal
    /// Removing liquidity must always decrease the product of reserves
    /// No tolerance needed as this should be a strict decrease
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
    
    /// Verify D-invariant for StableSwap is maintained or increased after operation
    /// D represents the total value in the pool and must not decrease from swaps
    /// Allows 1 unit rounding error due to Newton's method approximation
    /// Used to verify StableSwap formula correctness
    public fun assert_d_invariant_maintained(
        before: &StablePoolSnapshot,
        after: &StablePoolSnapshot
    ) {
        let d_before = test_utils::get_stable_snapshot_d(before);
        let d_after = test_utils::get_stable_snapshot_d(after);
        // Allow small rounding error (1 unit)
        if (d_before > d_after) {
            assert!(d_before - d_after <= 1, EDInvariantViolation);
        } else {
            assert!(d_after >= d_before, EDInvariantViolation);
        };
    }
    
    /// Verify D-invariant strictly increases after liquidity addition to stable pool
    /// Adding liquidity must always increase total pool value
    public fun assert_d_increased(
        before: &StablePoolSnapshot,
        after: &StablePoolSnapshot
    ) {
        let d_before = test_utils::get_stable_snapshot_d(before);
        let d_after = test_utils::get_stable_snapshot_d(after);
        assert!(d_after > d_before, EDInvariantViolation);
    }
    
    /// Verify D-invariant strictly decreases after liquidity removal from stable pool
    /// Removing liquidity must always decrease total pool value
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
    
    /// Verify fee calculation matches expected formula: fee = amount * fee_bps / 10000
    /// Tolerance accounts for rounding in integer division
    /// Used to verify swap fees are calculated correctly
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
    
    /// Verify fee distribution is complete with no loss or creation of value
    /// Total fee must equal sum of protocol fee, creator fee, and LP fee
    /// Ensures all collected fees are properly accounted for
    public fun assert_fee_distribution_complete(
        total_fee: u64,
        protocol_fee: u64,
        creator_fee: u64,
        lp_fee: u64
    ) {
        assert!(protocol_fee + creator_fee + lp_fee == total_fee, EFeeDistributionMismatch);
    }
    
    /// Verify accumulated fees per share increased by expected amount
    /// Accumulated fees track total fees earned per unit of liquidity
    /// Formula: increase = (lp_fee * ACC_PRECISION) / total_liquidity
    /// Tolerance accounts for rounding in per-share calculations
    /// Skips check if no liquidity exists to avoid division by zero
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
    
    /// Verify position has no pending fees after claiming
    /// Used to ensure fees cannot be double-claimed
    /// Both token A and token B pending fees must be zero
    public fun assert_no_pending_fees(
        position: &PositionSnapshot
    ) {
        let (pending_a, pending_b) = test_utils::get_position_snapshot_pending_fees(position);
        assert!(pending_a == 0, EPendingFeesNotZero);
        assert!(pending_b == 0, EPendingFeesNotZero);
    }
    
    /// Verify pending fees match expected amounts within tolerance
    /// Pending fees = (liquidity * acc_fee_per_share) - fee_debt
    /// Tolerance accounts for rounding in per-share calculations
    /// Used to verify fee debt tracking is correct
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
    
    /// Verify LP's share of total liquidity matches expected percentage
    /// Share calculated in basis points (1 bps = 0.01%)
    /// Tolerance accounts for rounding in share calculations
    /// Used to verify fair liquidity distribution among LPs
    /// Skips check if no liquidity exists to avoid division by zero
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
    
    /// Verify initial liquidity minting uses formula: sqrt(a * b) - MINIMUM_LIQUIDITY
    /// MINIMUM_LIQUIDITY is permanently locked to prevent division by zero attacks
    /// Formula ensures geometric mean of deposits determines initial LP shares
    /// Used to verify first liquidity addition is calculated correctly
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
    
    /// Verify subsequent liquidity minting is proportional to existing reserves
    /// Formula: min(amount_a * total_supply / reserve_a, amount_b * total_supply / reserve_b)
    /// Takes minimum to prevent manipulation through imbalanced deposits
    /// Tolerance accounts for rounding in proportional calculations
    /// Skips check if reserves or supply are zero (invalid state)
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
    
    /// Verify constant product swap output matches expected formula
    /// Formula: output = (amount_in_after_fee * reserve_out) / (reserve_in + amount_in_after_fee)
    /// Fees are deducted from input before calculating output
    /// Tolerance accounts for rounding in division operations
    /// Skips check if reserves are zero (invalid state)
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
    
    /// Verify slippage (difference between expected and actual output) is within tolerance
    /// Slippage = (expected - actual) / expected * 10000 (in basis points)
    /// Used to verify slippage protection mechanisms work correctly
    /// Skips check if expected output is zero to avoid division by zero
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
    
    /// Verify price impact is within acceptable limits
    /// Price impact measures how much a swap moves the pool price
    /// Used to verify large swaps are rejected or properly limited
    public fun assert_price_impact_within(
        impact_bps: u64,
        max_impact_bps: u64
    ) {
        assert!(impact_bps <= max_impact_bps, EPriceImpactExceeded);
    }
    
    /// Calculate price impact from swap and verify it's within limits
    /// Price impact = (ideal_output - actual_output) / ideal_output * 10000
    /// Ideal output assumes no price movement (linear exchange rate)
    /// Actual output accounts for price movement due to constant product formula
    /// Used to verify swaps don't cause excessive price movement
    /// Skips check if reserves or ideal output are zero (invalid state)
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
    
    /// Verify total value in system is conserved across operations
    /// Total value = reserves + LP fees + protocol fees
    /// Conservation: total_before + external_in = total_after + external_out
    /// Ensures no tokens are created or destroyed during operations
    /// Used to verify accounting correctness for swaps and liquidity operations
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
    
    /// Verify K-invariant calculation won't overflow u128
    /// Max safe value is u128::MAX / 10000 to allow for fee calculations
    /// Used to verify pool reserves are within safe bounds
    public fun assert_k_no_overflow(reserve_a: u64, reserve_b: u64) {
        let max_safe = 340282366920938463463374607431768211455u128 / 10000;
        let k = (reserve_a as u128) * (reserve_b as u128);
        assert!(k <= max_safe, EKOverflow);
    }
    
    /// Verify both reserves remain positive after operation
    /// Zero reserves would break the constant product formula
    /// Used to verify pool never becomes empty
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
    
    /// Verify gas consumption is within target budget
    /// Used to ensure operations remain cost-effective for users
    /// Helps identify performance regressions
    public fun assert_gas_within_target(
        actual_gas: u64,
        target_gas: u64
    ) {
        assert!(actual_gas <= target_gas, EGasExceeded);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Calculate integer square root using Newton's method
    /// Used for initial liquidity calculations: sqrt(amount_a * amount_b)
    /// Returns floor of square root for values >= 4, special cases for 0-3
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
