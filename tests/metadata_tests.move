#[test_only]
module sui_amm::metadata_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    
    use sui_amm::factory;
    use sui_amm::position::{Self};

    struct TokenA has drop {}
    struct TokenB has drop {}

    #[test]
    fun test_manual_position_creation_metadata() {
        let owner = @0xA;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        
        // Create pool and add liquidity
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, owner);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<TokenA>(1000000, ctx);
            let coin_b = coin::mint_for_testing<TokenB>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool<TokenA, TokenB>(
                registry,
                30,
                0,
                coin_a,
                coin_b,
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Basic sanity: cached values should be initialized
            assert!(position::cached_value_a(&position) > 0, 0);
            assert!(position::cached_value_b(&position) > 0, 1);
            
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }


    #[test]
    fun test_cached_values_update() {
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
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<TokenA>(1000000, ctx);
            let coin_b = coin::mint_for_testing<TokenB>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool<TokenA, TokenB>(
                registry,
                30,
                0,
                coin_a,
                coin_b,
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Initial cached values should be set
            assert!(position::cached_value_a(&position) > 0, 0);
            assert!(position::cached_value_b(&position) > 0, 1);
            
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        test_scenario::end(scenario_val);
    }

}
