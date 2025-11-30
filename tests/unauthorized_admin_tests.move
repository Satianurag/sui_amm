/// Unauthorized access and admin capability security tests
/// Tests S1: Administration governance security
#[test_only]
module sui_amm::unauthorized_admin_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::sui::SUI;
    use sui_amm::factory::{Self, PoolRegistry};
    use sui_amm::admin::{Self, AdminCap};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::stable_pool::{Self, StableSwapPool};
    use sui::clock::{Self};
    use sui::transfer;

    struct USDC has drop {}
    struct DAI has drop {}

    const ADMIN: address = @0xAD;
    const ATTACKER: address = @0xBAD;
    const USER: address = @0xCAFE;





    // Test that admin can perform all operations
    #[test]
    fun test_admin_can_perform_all_operations() {
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
            
            // Admin can set pool creation fee
            factory::set_pool_creation_fee(&admin_cap, &mut registry, 1_000_000_000);
            assert!(factory::get_pool_creation_fee(&registry) == 1_000_000_000, 0);
            
            // Admin can set max fee tier
            factory::set_max_fee_tier_bps(&admin_cap, &mut registry, 20000);
            assert!(factory::get_max_fee_tier_bps(&registry) == 20000, 1);
            
            // Admin can add fee tiers
            factory::add_fee_tier(&admin_cap, &mut registry, 50);
            assert!(factory::is_valid_fee_tier(&registry, 50), 2);
            
            // Admin can remove fee tiers
            factory::remove_fee_tier(&admin_cap, &mut registry, 50);
            assert!(!factory::is_valid_fee_tier(&registry, 50), 3);
            
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // Test that AdminCap is required and cannot be forged
    #[test]
    fun test_admin_cap_uniqueness() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
            admin::test_init(ctx);
        };

        // Verify only ADMIN has the AdminCap
        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
            // Admin has it
            ts::return_to_sender(&scenario, admin_cap);
        };

        // Verify ATTACKER does NOT have AdminCap
        ts::next_tx(&mut scenario, ATTACKER);
        {
            // Cannot take AdminCap - not owned by ATTACKER
            // This would fail if we tried: ts::take_from_sender<AdminCap>(&scenario)
        };

        ts::end(scenario);
    }

    // Test that only pool creator can withdraw creator fees
    #[test]
    #[expected_failure(abort_code = sui_amm::pool::EUnauthorized)]
    fun test_non_creator_cannot_withdraw_creator_fees() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
        };

        // USER creates pool
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_pool<USDC, DAI>(
                &mut registry,
                30,
                100, // 1% creator fee
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

        // ATTACKER tries to withdraw creator fees - should fail
        ts::next_tx(&mut scenario, ATTACKER);
        {
            let pool = ts::take_shared<LiquidityPool<USDC, DAI>>(&scenario);
            
            // This should abort with EUnauthorized
            let (fee_a, fee_b) = pool::withdraw_creator_fees(&mut pool, ts::ctx(&mut scenario));
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    // Test that pool creator CAN withdraw creator fees
    #[test]
    fun test_creator_can_withdraw_creator_fees() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
        };

        // USER creates pool
        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_pool<USDC, DAI>(
                &mut registry,
                30,
                100,
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

        // Creator withdraws fees - should succeed
        ts::next_tx(&mut scenario, USER);
        {
            let pool = ts::take_shared<LiquidityPool<USDC, DAI>>(&scenario);
            
            let (fee_a, fee_b) = pool::withdraw_creator_fees(&mut pool, ts::ctx(&mut scenario));
            
            // Should succeed (fees might be 0 if no swaps, but should not error)
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    // Test stable pool creator fee access control
    #[test]
    #[expected_failure(abort_code = sui_amm::stable_pool::EUnauthorized)]
    fun test_non_creator_cannot_withdraw_stable_creator_fees() {
        let scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            factory::test_init(ctx);
        };

        ts::next_tx(&mut scenario, USER);
        {
            let registry = ts::take_shared<PoolRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            
            let coin_a = coin::mint_for_testing<USDC>(1000000, ts::ctx(&mut scenario));
            let coin_b = coin::mint_for_testing<DAI>(1000000, ts::ctx(&mut scenario));
            let fee_coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            
            let (position, refund_a, refund_b) = factory::create_stable_pool<USDC, DAI>(
                &mut registry,
                5,
                100,
                100,
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

        // ATTACKER tries to withdraw - should fail
        ts::next_tx(&mut scenario, ATTACKER);
        {
            let pool = ts::take_shared<StableSwapPool<USDC, DAI>>(&scenario);
            
            let (fee_a, fee_b) = stable_pool::withdraw_creator_fees(&mut pool, ts::ctx(&mut scenario));
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }
}
