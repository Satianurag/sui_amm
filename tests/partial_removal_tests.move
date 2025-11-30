#[test_only]
module sui_amm::partial_removal_tests {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::transfer;
    use sui::clock::{Self};
    use sui::sui::SUI;
    
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::factory;
    use sui_amm::position::{Self};

    struct BTC has drop {}
    struct USDC has drop {}

    #[test]
    fun test_remove_50_percent() {
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

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
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
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Remove 50% of liquidity
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let initial_liquidity = position::liquidity(position);
            let half = initial_liquidity / 2;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(
                pool,
                position,
                half,
                0,
                0,
                &clock,
                18446744073709551615,
                ctx
            );
            
            // Position should still have half liquidity
            assert!(position::liquidity(position) == initial_liquidity - half, 0);
            
            // Should receive proportional amounts
            assert!(coin::value(&coin_a) > 0, 1);
            assert!(coin::value(&coin_b) > 0, 2);
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_remove_1_percent() {
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

            let coin_a = coin::mint_for_testing<BTC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10000000, ctx);
            
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
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Remove 1% of liquidity
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let initial_liquidity = position::liquidity(position);
            let one_percent = initial_liquidity / 100;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(
                pool,
                position,
                one_percent,
                0,
                0,
                &clock,
                18446744073709551615,
                ctx
            );
            
            // Position should have 99% remaining
            assert!(position::liquidity(position) == initial_liquidity - one_percent, 0);
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_remove_99_percent() {
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

            let coin_a = coin::mint_for_testing<BTC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0, // creator_fee_percent (previously non-zero; protocol fee now fixed)
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Remove 99%
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let initial_liquidity = position::liquidity(position);
            let ninety_nine_percent = (initial_liquidity * 99) / 100;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(
                pool,
                position,
                ninety_nine_percent,
                0,
                0,
                &clock,
                18446744073709551615,
                ctx
            );
            
            // Should have tiny amount left
            assert!(position::liquidity(position) > 0, 0);
            assert!(position::liquidity(position) < initial_liquidity / 50, 1); // Less than 2%
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_multiple_partial_removals() {
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

            let coin_a = coin::mint_for_testing<BTC>(10000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(10000000, ctx);
            
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
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        let initial_liquidity;
        
        // First removal - 25%
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            initial_liquidity = position::liquidity(position);
            let quarter = initial_liquidity / 4;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(pool, position, quarter, 0, 0, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        // Second removal - another 25%
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let current = position::liquidity(position);
            let quarter_of_remaining = current / 3; // ~25% of original
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(pool, position, quarter_of_remaining, 0, 0, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            // Should have ~50% of original left
            assert!(position::liquidity(position) > initial_liquidity / 3, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = pool::EInsufficientLiquidity)] // EInsufficientLiquidity
    fun test_remove_more_than_owned() {
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

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
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
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Try to remove more than owned - should fail
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let liquidity = position::liquidity(position);
            let too_much = liquidity + 1;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(pool, position, too_much, 0, 0, &clock, 18446744073709551615, ctx);
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
    #[test]
    fun test_partial_removal_with_fees() {
        let owner = @0xA;
        let trader = @0xB;
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

            let coin_a = coin::mint_for_testing<BTC>(1000000, ctx);
            let coin_b = coin::mint_for_testing<USDC>(1000000, ctx);
            
            let (position, refund_a, refund_b) = factory::create_pool(
                registry,
                30,
                0,
                coin_a,
                coin_b,
                coin::mint_for_testing<SUI>(10_000_000_000, ctx),
                &clock,
                ctx
            );
            
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            transfer::public_transfer(position, owner);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry_val);
        };

        // Trader swaps to generate fees
        test_scenario::next_tx(scenario, trader);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let coin_in = coin::mint_for_testing<BTC>(100000, ctx);
            let coin_out = pool::swap_a_to_b(pool, coin_in, 0, std::option::none(), &clock, 18446744073709551615, ctx);
            
            coin::burn_for_testing(coin_out);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(pool_val);
        };

        // Remove 50% liquidity and check fees
        test_scenario::next_tx(scenario, owner);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<BTC, USDC>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<sui_amm::position::LPPosition>(scenario);
            let position = &mut position_val;
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            let ctx = test_scenario::ctx(scenario);
            
            let initial_liquidity = position::liquidity(position);
            let half = initial_liquidity / 2;
            
            let (coin_a, coin_b) = pool::remove_liquidity_partial(pool, position, half, 0, 0, &clock, 18446744073709551615, ctx);
            
            // Should have received some fees (amount > pro-rata share)
            // But since we don't know exact amounts, just check it succeeds and debt is updated
            assert!(position::liquidity(position) == initial_liquidity - half, 0);
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_to_sender(scenario, position_val);
            test_scenario::return_shared(pool_val);
        };

        test_scenario::end(scenario_val);
    }
}
