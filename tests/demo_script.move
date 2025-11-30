#[test_only]
module sui_amm::demo_script {
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::sui::SUI;
    use sui::clock::{Self};
    use sui::transfer;
    use std::string;
    use std::debug;

    use sui_amm::factory::{Self, PoolRegistry};
    use sui_amm::pool::{Self, LiquidityPool};
    use sui_amm::position::{Self, LPPosition};
    use sui_amm::fee_distributor::{Self};

    // Test Coins
    struct USDC has drop {}
    struct ETH has drop {}

    const ADMIN: address = @0xA;
    const CREATOR: address = @0xB;
    const TRADER: address = @0xC;

    #[test]
    fun run_demo() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(test_scenario::ctx(scenario));

        // 1. Setup Registry and FeeDistributor
        test_scenario::next_tx(scenario, ADMIN);
        {
            factory::test_init(test_scenario::ctx(scenario));
            // fee_distributor::test_init(test_scenario::ctx(scenario));
        };

        // 2. Create Pool (by CREATOR)
        test_scenario::next_tx(scenario, CREATOR);
        {
            let registry = test_scenario::take_shared<PoolRegistry>(scenario);
            
            let coin_a = coin::mint_for_testing<USDC>(100_000_000_000, test_scenario::ctx(scenario)); // 100k USDC
            let coin_b = coin::mint_for_testing<ETH>(100_000_000_000, test_scenario::ctx(scenario));  // 100 ETH (assuming 1000 USDC/ETH for simplicity)
            let creation_fee = coin::mint_for_testing<SUI>(5_000_000_000, test_scenario::ctx(scenario));

            let (pos, refund_a, refund_b) = factory::create_pool<USDC, ETH>(
                &mut registry,
                30, // 0.3%
                0,  // 0% creator fee
                coin_a,
                coin_b,
                creation_fee,
                &clock,
                test_scenario::ctx(scenario)
            );

            debug::print(&string::utf8(b"Step 1: Pool Created"));

            transfer::public_transfer(pos, CREATOR);
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            test_scenario::return_shared(registry);
        };

        // 3. Execute Swap (by TRADER)
        test_scenario::next_tx(scenario, TRADER);
        {
            let pool = test_scenario::take_shared<LiquidityPool<USDC, ETH>>(scenario);
            
            // Swap 5,000 USDC for ETH (Enough for IL, safe for price impact)
            let coin_in = coin::mint_for_testing<USDC>(5_000_000_000, test_scenario::ctx(scenario));
            
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                0, // min_out
                std::option::none(),
                &clock,
                18446744073709551615, // max u64
                test_scenario::ctx(scenario)
            );

            debug::print(&string::utf8(b"Step 2: Swaps Executed"));
            
            coin::burn_for_testing(coin_out);
            test_scenario::return_shared(pool);
        };

        // 4. Verify Metadata & Claim Fees (by CREATOR)
        test_scenario::next_tx(scenario, CREATOR);
        {
            let pool_val = test_scenario::take_shared<LiquidityPool<USDC, ETH>>(scenario);
            let pool = &mut pool_val;
            let position_val = test_scenario::take_from_sender<LPPosition>(scenario);
            let position = &mut position_val;

            // Refresh metadata manually to check values
            pool::refresh_position_metadata(pool, position);
            
            let fees_a = position::cached_fee_a(position);
            let il_bps = position::cached_il_bps(position);

            // Verify fees accumulated (0.3% of 1000 USDC = 3 USDC)
            // Protocol fee might take a cut, but cached_fee_a should be > 0
            assert!(fees_a > 0, 1);
            
            // Verify IL is calculated (reserves changed, so IL > 0)
            assert!(il_bps > 0, 2);

            debug::print(&string::utf8(b"Step 3: Metadata Verified - Fees accumulated & IL detected"));

            // Claim Fees (use the outer clock, not a new one)
            let (fee_a, fee_b) = fee_distributor::claim_fees(
                pool,
                position,
                &clock,
                18446744073709551615, // Max u64 deadline
                test_scenario::ctx(scenario)
            );

            debug::print(&string::utf8(b"Step 4: Fees Claimed"));
            
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);

            // 5. Remove Liquidity
            let (out_a, out_b) = pool::remove_liquidity(
                pool,
                position_val,
                0, 0,
                &clock,
                18446744073709551615,
                test_scenario::ctx(scenario)
            );

            debug::print(&string::utf8(b"Step 5: Liquidity Removed"));

            coin::burn_for_testing(out_a);
            coin::burn_for_testing(out_b);
            
            test_scenario::return_shared(pool_val);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario_val);
    }
}
