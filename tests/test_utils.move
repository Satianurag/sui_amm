#[test_only]
module sui_amm::test_utils {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::tx_context::{TxContext};
    
    // Test address constants
    const ADMIN: address = @0xAD;
    const USER_A: address = @0xA;
    const USER_B: address = @0xB;
    const USER_C: address = @0xC;
    
    // Test amount constants
    const INITIAL_BALANCE: u64 = 1_000_000_000_000; // 1000 tokens with 9 decimals
    const SMALL_AMOUNT: u64 = 1_000;
    const LARGE_AMOUNT: u64 = 1_000_000_000_000_000; // 1M tokens
    
    // Test fee tier constants (in basis points)
    const FEE_LOW: u64 = 5;      // 0.05%
    const FEE_MEDIUM: u64 = 30;  // 0.30%
    const FEE_HIGH: u64 = 100;   // 1.00%
    
    // Getter functions for test addresses
    public fun admin(): address { ADMIN }
    public fun user_a(): address { USER_A }
    public fun user_b(): address { USER_B }
    public fun user_c(): address { USER_C }
    
    // Getter functions for test amounts
    public fun initial_balance(): u64 { INITIAL_BALANCE }
    public fun small_amount(): u64 { SMALL_AMOUNT }
    public fun large_amount(): u64 { LARGE_AMOUNT }
    
    // Getter functions for test fee tiers
    public fun fee_low(): u64 { FEE_LOW }
    public fun fee_medium(): u64 { FEE_MEDIUM }
    public fun fee_high(): u64 { FEE_HIGH }
}
