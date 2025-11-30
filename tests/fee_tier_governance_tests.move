/// Comprehensive tests for dynamic fee tier governance
/// Tests V3: Dynamic fee tier mutation and governance validation
#[test_only]
module sui_amm::fee_tier_governance_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::transfer;
    use sui::sui::SUI;
    use sui_amm::factory::{Self, PoolRegistry};
    use sui_amm::admin::{Self, AdminCap};

    struct USDC has drop {}
    struct DAI has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xCAFE;


    #[test]
    fun test_add_custom_fee_tier() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Add custom fee tier
            factory::add_fee_tier(&admin_cap, &mut registry, 15); // 0.15%
            assert!(factory::is_valid_fee_tier(&registry, 15), 0);
            
            // Add another
            factory::add_fee_tier(&admin_cap, &mut registry, 200); // 2.00%
            assert!(factory::is_valid_fee_tier(&registry, 200), 1);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_remove_fee_tier() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Verify default fee tier exists
            assert!(factory::is_valid_fee_tier(&registry, 30), 0); // 0.30%
            
            // Remove it
            factory::remove_fee_tier(&admin_cap, &mut registry, 30);
            assert!(!factory::is_valid_fee_tier(&registry, 30), 1);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_add_fee_tier_idempotent() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Add fee tier twice - should not fail
            factory::add_fee_tier(&admin_cap, &mut registry, 75);
            factory::add_fee_tier(&admin_cap, &mut registry, 75);
            
            assert!(factory::is_valid_fee_tier(&registry, 75), 0);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_remove_nonexistent_fee_tier() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Remove non-existent fee tier - should not fail
            factory::remove_fee_tier(&admin_cap, &mut registry, 999);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::factory::EFeeTierTooHigh)]
    fun test_add_fee_tier_above_max() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Default max is 10000 BPS (100%)
            // Try to add 200% fee tier - should fail
            factory::add_fee_tier(&admin_cap, &mut registry, 20000);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_increase_max_fee_tier_then_add() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Increase max to allow exotic fee tiers
            factory::set_max_fee_tier_bps(&admin_cap, &mut registry, 50000); // 500%
            assert!(factory::get_max_fee_tier_bps(&registry) == 50000, 0);
            
            // Now we can add 200% fee tier
            factory::add_fee_tier(&admin_cap, &mut registry, 20000);
            assert!(factory::is_valid_fee_tier(&registry, 20000), 1);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_create_pool_with_custom_fee_tier() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        // Add custom fee tier
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            factory::add_fee_tier(&admin_cap, &mut registry, 15);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        // Create pool with custom fee tier
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_pool<USDC, DAI>(
                &mut registry,
                15, // Custom fee tier
                0,
                coin_a,
                coin_b,
                fee_coin,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_transfer(position, USER);
            transfer::public_transfer(refund_a, USER);
            transfer::public_transfer(refund_b, USER);
            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::factory::EInvalidFeeTier)]
    fun test_create_pool_with_removed_fee_tier() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        // Remove standard fee tier
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            factory::remove_fee_tier(&admin_cap, &mut registry, 30);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        // Try to create pool with removed fee tier - should fail
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_pool<USDC, DAI>(
                &mut registry,
                30, // Removed fee tier
                0,
                coin_a,
                coin_b,
                fee_coin,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_transfer(position, USER);
            transfer::public_transfer(refund_a, USER);
            transfer::public_transfer(refund_b, USER);
            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_zero_fee_tier() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Add 0% fee tier (no fees)
            factory::add_fee_tier(&admin_cap, &mut registry, 0);
            assert!(factory::is_valid_fee_tier(&registry, 0), 0);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        // Create pool with zero fees
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_pool<USDC, DAI>(
                &mut registry,
                0, // Zero fees
                0,
                coin_a,
                coin_b,
                fee_coin,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_transfer(position, USER);
            transfer::public_transfer(refund_a, USER);
            transfer::public_transfer(refund_b, USER);
            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_set_max_fee_tier_no_upper_limit() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            
            // Set extremely high max for future extensibility
            factory::set_max_fee_tier_bps(&admin_cap, &mut registry, 1000000); // 10,000%
            assert!(factory::get_max_fee_tier_bps(&registry) == 1000000, 0);
            
            // Can now add very high fee tier
            factory::add_fee_tier(&admin_cap, &mut registry, 500000); // 5,000%
            assert!(factory::is_valid_fee_tier(&registry, 500000), 1);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }
}
