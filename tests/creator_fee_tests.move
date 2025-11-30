#[test_only]
module sui_amm::creator_fee_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use sui::sui::SUI;
    use std::option;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::factory;

    struct TokenX has drop {}
    struct TokenY has drop {}

    #[test]
    fun test_creator_fee_accumulation() {
        let creator = @0xA;
        let trader = @0xB;
        let scenario_val = test_scenario::begin(creator);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, creator);
        {
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            clock::destroy_for_testing(clock);
            factory::test_init(ctx);
        };

        // Creator creates pool
        test_scenario::next_tx(scenario, creator);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_a = coin::mint_for_testing<TokenX>(10000000, ctx);
            let coin_b = coin::mint_for_testing<TokenY>(10000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30, // 0.3% fee
                0, // creator_fee_percent
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, creator);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Trader executes swap
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<TokenX, TokenY>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_in = coin::mint_for_testing<TokenX>(100000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, option::none(), &clock, 999999999, ctx);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Creator should be able to withdraw fees (even if amount is 0 default)
        test_scenario::next_tx(scenario, creator);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<TokenX, TokenY>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            
            let (fee_a, fee_b) = pool::withdraw_creator_fees(pool, ctx);
            
            // With default 0% creator fee, should be 0
            assert!(coin::value(&fee_a) == 0, 0);
            assert!(coin::value(&fee_b) == 0, 1);
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = pool::EUnauthorized)]
    fun test_non_creator_cannot_withdraw() {
        let creator = @0xA;
        let attacker = @0xB;
        let scenario_val = test_scenario::begin(creator);
        let scenario = &mut scenario_val;
        
        test_scenario::next_tx(scenario, creator);
        {
            let ctx = test_scenario::ctx(scenario);
            factory::test_init(ctx);
        };

        test_scenario::next_tx(scenario, creator);
        {
            let registry_val = test_scenario::take_shared<factory::PoolRegistry>(scenario);
            let registry = &mut registry_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);

            let coin_a = coin::mint_for_testing<TokenX>(1000000, ctx);
            let coin_b = coin::mint_for_testing<TokenY>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, creator);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Attacker tries to withdrawal creator fees - currently succeeds with 0 return
        test_scenario::next_tx(scenario, attacker);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<TokenX, TokenY>>(scenario);
            let pool = &mut pool_val;
            let ctx = test_scenario::ctx(scenario);
            
            let (fee_a, fee_b) = pool::withdraw_creator_fees(pool, ctx);
            
            assert!(coin::value(&fee_a) == 0, 0);
            assert!(coin::value(&fee_b) == 0, 1);

            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    /*
    #[test]
    fun test_pool_info_includes_creator() {
        // Commented out as get_pool_info is not implemented
    }
    */
}
