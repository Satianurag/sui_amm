#[test_only]
module sui_amm::factory_tests {
    use sui::test_scenario::{Self};
    use sui::coin;
    use std::option;
    use sui::transfer;
    use std::vector;
    use sui::clock::{Self};
    use sui::sui::SUI;
    
    use sui_amm::factory::{Self, PoolRegistry};

    struct BTC has drop {}
    struct USDC has drop {}
    struct ETH has drop {}

    #[test]
    fun test_pool_creation_and_lookup() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Initialize registry
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };
        
        // Create pool
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (position, refund_a, refund_b) = factory::create_pool<BTC, USDC>(registry, 30, 0, coin_a, coin_b, creation_fee, &clock, ctx);
            transfer::public_transfer(position, owner);
            transfer::public_transfer(refund_a, owner);
            transfer::public_transfer(refund_b, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Verify pool exists
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &registry_val;
            
            let pool_id_opt = factory::get_pool_id<BTC, USDC>(registry, 30, false);
            assert!(option::is_some(&pool_id_opt), 0);
            
            let count = factory::get_pool_count(registry);
            assert!(count == 1, 1);
            
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::factory::EPoolAlreadyExists)]
    fun test_duplicate_pool_creation() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            // Create pool with initial liquidity
            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);
            let creation_fee = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (position, refund_a, refund_b) = factory::create_pool<BTC, USDC>(registry, 30, 0, coin_a, coin_b, creation_fee, &clock, ctx);
            
            // Transfer returned objects
            transfer::public_transfer(position, owner);
            transfer::public_transfer(refund_a, owner);
            transfer::public_transfer(refund_b, owner);
            
            // Try to create duplicate - should fail
            let coin_a2 = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b2 = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee2 = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (_p, _ra, _rb) = factory::create_pool<BTC, USDC>(registry, 30, 0, coin_a2, coin_b2, creation_fee2, &clock, ctx);
            
            let p = _p; let ra = _ra; let rb = _rb;
            transfer::public_transfer(p, owner);
            transfer::public_transfer(ra, owner);
            transfer::public_transfer(rb, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = sui_amm::factory::EInvalidFeeTier)]
    fun test_invalid_fee_tier() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };
        
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            // Try to create pool with invalid fee tier (25 bps not in standard tiers)
            let coin_a = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(100000, ctx);
            let creation_fee = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (_p, _ra, _rb) = factory::create_pool<BTC, USDC>(registry, 25, 0, coin_a, coin_b, creation_fee, &clock, ctx);
            
            let p = _p; let ra = _ra; let rb = _rb;
            transfer::public_transfer(p, owner);
            transfer::public_transfer(ra, owner);
            transfer::public_transfer(rb, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_multiple_pools_enumeration() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        // Create multiple pools
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            // Different token pairs
            let coin_a1 = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b1 = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee1 = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (p1, ra1, rb1) = factory::create_pool<BTC, USDC>(registry, 30, 0, coin_a1, coin_b1, creation_fee1, &clock, ctx);
            transfer::public_transfer(p1, owner);
            transfer::public_transfer(ra1, owner);
            transfer::public_transfer(rb1, owner);

            let coin_a2 = coin::mint_for_testing<ETH>(200000, ctx);
            let coin_b2 = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee2 = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (p2, ra2, rb2) = factory::create_pool<ETH, USDC>(registry, 30, 0, coin_a2, coin_b2, creation_fee2, &clock, ctx);
            transfer::public_transfer(p2, owner);
            transfer::public_transfer(ra2, owner);
            transfer::public_transfer(rb2, owner);
            
            // Same pair, different fee tier (allowed)
            let coin_a3 = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b3 = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee3 = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (p3, ra3, rb3) = factory::create_pool<BTC, USDC>(registry, 100, 0, coin_a3, coin_b3, creation_fee3, &clock, ctx);
            transfer::public_transfer(p3, owner);
            transfer::public_transfer(ra3, owner);
            transfer::public_transfer(rb3, owner);
            
            // Stable pool
            let coin_a4 = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b4 = coin::mint_for_testing<ETH>(200000, ctx);
            let creation_fee4 = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (p4, ra4, rb4) = factory::create_stable_pool<BTC, ETH>(registry, 5, 0, 100, coin_a4, coin_b4, creation_fee4, &clock, ctx);
            transfer::public_transfer(p4, owner);
            transfer::public_transfer(ra4, owner);
            transfer::public_transfer(rb4, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Verify enumeration
        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &registry_val;
            
            let count = factory::get_pool_count(registry);
            assert!(count == 4, 0);
            
            let all_pools = factory::get_all_pools(registry);
            assert!(vector::length(&all_pools) == 4, 1);
            
            // Check fee tier indexing
            let fee_30_pools = factory::get_pools_by_fee_tier(registry, 30);
            assert!(vector::length(&fee_30_pools) == 2, 2); // BTC-USDC and ETH-USDC
            
            let fee_100_pools = factory::get_pools_by_fee_tier(registry, 100);
            assert!(vector::length(&fee_100_pools) == 1, 3); // BTC-USDC at 1%
            
            let fee_5_pools = factory::get_pools_by_fee_tier(registry, 5);
            assert!(vector::length(&fee_5_pools) == 1, 4); // Stable pool
            
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_standard_fee_tiers() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &registry_val;

            // Verify standard fee tier values
            assert!(factory::fee_tier_low() == 5, 0);      // 0.05%
            assert!(factory::fee_tier_medium() == 30, 1);  // 0.30%
            assert!(factory::fee_tier_high() == 100, 2);   // 1.00%
            
            // Verify validation
            assert!(factory::is_valid_fee_tier(registry, 5), 3);
            assert!(factory::is_valid_fee_tier(registry, 30), 4);
            assert!(factory::is_valid_fee_tier(registry, 100), 5);
            assert!(!factory::is_valid_fee_tier(registry, 25), 6);
            assert!(!factory::is_valid_fee_tier(registry, 50), 7);
            
            test_scenario::return_shared(registry_val);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_stable_pool_creation() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (position, refund_a, refund_b) = factory::create_stable_pool<BTC, USDC>(registry, 5, 0, 100, coin_a, coin_b, creation_fee, &clock, ctx);
            transfer::public_transfer(position, owner);
            transfer::public_transfer(refund_a, owner);
            transfer::public_transfer(refund_b, owner);
            
            // Verify stable pool was registered
            let pool_id_opt = factory::get_pool_id<BTC, USDC>(registry, 5, true);
            assert!(option::is_some(&pool_id_opt), 0);
            
            // Verify it's different from a regular pool
            let regular_pool_opt = factory::get_pool_id<BTC, USDC>(registry, 5, false);
            assert!(option::is_none(&regular_pool_opt), 1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_reverse_lookup_and_pair_lookup() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            // Create standard pool
            let coin_a = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (position, refund_a, refund_b) = factory::create_pool<BTC, USDC>(registry, 30, 0, coin_a, coin_b, creation_fee, &clock, ctx);
            transfer::public_transfer(position, owner);
            transfer::public_transfer(refund_a, owner);
            transfer::public_transfer(refund_b, owner);
            
            // Create stable pool
            let coin_a2 = coin::mint_for_testing<BTC>(200000, ctx);
            let coin_b2 = coin::mint_for_testing<USDC>(200000, ctx);
            let creation_fee2 = coin::mint_for_testing<SUI>(10_000_000_000, ctx);
            let (position2, refund_a2, refund_b2) = factory::create_stable_pool<BTC, USDC>(registry, 5, 0, 100, coin_a2, coin_b2, creation_fee2, &clock, ctx);
            transfer::public_transfer(position2, owner);
            transfer::public_transfer(refund_a2, owner);
            transfer::public_transfer(refund_b2, owner);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<PoolRegistry>(scenario);
            let registry = &registry_val;
            
            // Test get_pools_for_pair
            let pools = factory::get_pools_for_pair<BTC, USDC>(registry);
            assert!(vector::length(&pools) >= 1, 0);
            
            let pool_id = *vector::borrow(&pools, 0);
            
            // Test reverse lookup
            let key_opt = factory::get_pool_key(registry, pool_id);
            assert!(option::is_some(&key_opt), 1);
            
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }
}
