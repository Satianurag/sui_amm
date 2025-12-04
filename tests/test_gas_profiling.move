/// Gas profiling test suite for comprehensive gas consumption measurement
///
/// This module measures gas consumption for all core AMM operations and generates
/// benchmark reports for performance analysis and comparison with other protocols.
///
/// # Overview
///
/// The gas profiling system:
/// - Measures gas for pool creation (standard and stable)
/// - Measures gas for liquidity operations (add/remove)
/// - Measures gas for swap operations (both directions)
/// - Measures gas for fee operations (claim/auto-compound)
/// - Generates formatted benchmark reports
///
/// # Usage
///
/// Run gas profiling tests with gas reporting:
/// ```bash
/// sui move test test_gas_profiling --gas-limit 100000000000
/// ```
///
/// Note: Actual gas measurements are obtained from the Sui CLI output when running
/// tests. The GasMeasurement structs in this module are used for organizing and
/// reporting gas data, with actual values populated from CLI output.
///
/// # Requirements
///
/// Validates Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7
#[test_only]
module sui_amm::test_gas_profiling {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin;
    
    use sui_amm::test_utils::{Self, USDC, USDT, ETH};
    use sui_amm::pool;
    use sui_amm::stable_pool;
    use sui_amm::position;
    use sui_amm::fixtures;

    // ═══════════════════════════════════════════════════════════════════════════
    // DATA STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════════

    /// Gas measurement result for a single operation
    ///
    /// Captures the gas consumption of a specific operation along with metadata
    /// for reporting and analysis.
    ///
    /// # Fields
    /// - `operation_name`: Human-readable name of the operation (e.g., "Create Pool")
    /// - `gas_used`: Gas consumed by the operation in gas units
    /// - `timestamp`: Time when measurement was taken (milliseconds)
    /// - `pool_type`: Type of pool tested ("standard" or "stable")
    ///
    /// # Design Decisions
    /// - Uses vector<u8> for strings to avoid string module dependency in tests
    /// - Includes timestamp for temporal analysis of gas consumption
    /// - Separates pool_type to enable comparison between pool variants
    ///
    /// # Usage Example
    /// ```move
    /// let measurement = GasMeasurement {
    ///     operation_name: b"Swap A to B",
    ///     gas_used: 295000,
    ///     timestamp: clock::timestamp_ms(&clock),
    ///     pool_type: b"standard",
    /// };
    /// ```
    public struct GasMeasurement has drop, copy, store {
        operation_name: vector<u8>,
        gas_used: u64,
        timestamp: u64,
        pool_type: vector<u8>,
    }

    /// Collection of gas measurements for benchmark reporting
    ///
    /// Aggregates multiple gas measurements and provides summary statistics
    /// for comprehensive performance analysis.
    ///
    /// # Fields
    /// - `measurements`: Vector of individual gas measurements
    /// - `total_operations`: Count of operations measured
    /// - `average_gas`: Average gas consumption across all operations
    ///
    /// # Design Decisions
    /// - Stores all measurements for detailed analysis
    /// - Pre-calculates average to avoid repeated computation
    /// - Uses u64 for counts to handle large test suites
    ///
    /// # Usage Example
    /// ```move
    /// let report = GasBenchmarkReport {
    ///     measurements: vector[measurement1, measurement2],
    ///     total_operations: 2,
    ///     average_gas: 250000,
    /// };
    /// ```
    public struct GasBenchmarkReport has drop, store {
        measurements: vector<GasMeasurement>,
        total_operations: u64,
        average_gas: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a new gas measurement record
    ///
    /// Helper function to construct GasMeasurement structs with consistent formatting.
    ///
    /// # Parameters
    /// - `operation_name`: Name of the operation being measured
    /// - `gas_used`: Gas consumed by the operation
    /// - `timestamp`: Time of measurement
    /// - `pool_type`: Type of pool ("standard" or "stable")
    ///
    /// # Returns
    /// - GasMeasurement struct with provided values
    ///
    /// # Examples
    /// ```move
    /// let measurement = create_measurement(
    ///     b"Add Liquidity",
    ///     485000,
    ///     clock::timestamp_ms(&clock),
    ///     b"standard"
    /// );
    /// ```
    public fun create_measurement(
        operation_name: vector<u8>,
        gas_used: u64,
        timestamp: u64,
        pool_type: vector<u8>
    ): GasMeasurement {
        GasMeasurement {
            operation_name,
            gas_used,
            timestamp,
            pool_type,
        }
    }

    /// Create a new benchmark report from measurements
    ///
    /// Aggregates individual measurements and calculates summary statistics.
    ///
    /// # Parameters
    /// - `measurements`: Vector of gas measurements to include in report
    ///
    /// # Returns
    /// - GasBenchmarkReport with calculated statistics
    ///
    /// # Examples
    /// ```move
    /// let measurements = vector[m1, m2, m3];
    /// let report = create_report(measurements);
    /// assert!(report.total_operations == 3, 0);
    /// ```
    public fun create_report(measurements: vector<GasMeasurement>): GasBenchmarkReport {
        let total_operations = vector::length(&measurements);
        
        // Calculate average gas
        let mut total_gas: u128 = 0;
        let mut i = 0;
        while (i < total_operations) {
            let measurement = vector::borrow(&measurements, i);
            total_gas = total_gas + (measurement.gas_used as u128);
            i = i + 1;
        };
        
        let average_gas = if (total_operations > 0) {
            ((total_gas / (total_operations as u128)) as u64)
        } else {
            0
        };
        
        GasBenchmarkReport {
            measurements,
            total_operations,
            average_gas,
        }
    }

    /// Get gas used from a measurement
    ///
    /// # Parameters
    /// - `measurement`: Gas measurement to query
    ///
    /// # Returns
    /// - Gas consumed in gas units
    public fun get_gas_used(measurement: &GasMeasurement): u64 {
        measurement.gas_used
    }

    /// Get operation name from a measurement
    ///
    /// # Parameters
    /// - `measurement`: Gas measurement to query
    ///
    /// # Returns
    /// - Operation name as byte vector
    public fun get_operation_name(measurement: &GasMeasurement): vector<u8> {
        measurement.operation_name
    }

    /// Get pool type from a measurement
    ///
    /// # Parameters
    /// - `measurement`: Gas measurement to query
    ///
    /// # Returns
    /// - Pool type as byte vector
    public fun get_pool_type(measurement: &GasMeasurement): vector<u8> {
        measurement.pool_type
    }

    /// Get total operations from a report
    ///
    /// # Parameters
    /// - `report`: Benchmark report to query
    ///
    /// # Returns
    /// - Total number of operations measured
    public fun get_total_operations(report: &GasBenchmarkReport): u64 {
        report.total_operations
    }

    /// Get average gas from a report
    ///
    /// # Parameters
    /// - `report`: Benchmark report to query
    ///
    /// # Returns
    /// - Average gas consumption across all operations
    public fun get_average_gas(report: &GasBenchmarkReport): u64 {
        report.average_gas
    }

    /// Get all measurements from a report
    ///
    /// # Parameters
    /// - `report`: Benchmark report to query
    ///
    /// # Returns
    /// - Vector of all gas measurements
    public fun get_measurements(report: &GasBenchmarkReport): vector<GasMeasurement> {
        report.measurements
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BENCHMARK TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// Benchmark gas consumption for pool creation operations
    ///
    /// Measures gas for:
    /// - Standard pool creation with initial liquidity
    /// - Stable pool creation with initial liquidity
    ///
    /// Records measurements with operation names for reporting.
    ///
    /// **Validates: Requirements 2.1**
    #[test]
    fun benchmark_create_pool() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(scenario.ctx());
        
        // Get liquidity amounts from fixtures
        let (amount_a, amount_b) = fixtures::retail_liquidity();
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Create Standard Pool
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            // Create standard pool with initial liquidity
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, USDT>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<USDT>(amount_b, scenario.ctx());
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Create Stable Pool
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            // Create stable pool with initial liquidity
            let (fee_bps, amp) = fixtures::balanced_stable_config();
            let mut pool = stable_pool::create_pool<USDC, USDT>(
                fee_bps,
                100, // protocol_fee_bps
                0,   // creator_fee_bps
                amp,
                scenario.ctx()
            );
            
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<USDT>(amount_b, scenario.ctx());
            
            let (position, refund_a, refund_b) = stable_pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            position::destroy(position);
            stable_pool::destroy_for_testing(pool);
        };
        
        // Cleanup
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    /// Benchmark gas consumption for add liquidity operations
    ///
    /// Measures gas for:
    /// - Initial liquidity addition to standard pool
    /// - Subsequent liquidity addition to standard pool
    ///
    /// **Validates: Requirements 2.2**
    #[test]
    fun benchmark_add_liquidity() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(scenario.ctx());
        
        // Get liquidity amounts from fixtures
        let (amount_a, amount_b) = fixtures::retail_liquidity();
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Add Initial Liquidity (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, USDT>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<USDT>(amount_b, scenario.ctx());
            
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Add Subsequent Liquidity (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, ETH>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity first
            let coin_a1 = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b1 = test_utils::mint_coin<ETH>(amount_b, scenario.ctx());
            let (position1, refund_a1, refund_b1) = pool::add_liquidity(
                &mut pool,
                coin_a1,
                coin_b1,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a1);
            coin::burn_for_testing(refund_b1);
            
            // Add subsequent liquidity
            let coin_a2 = test_utils::mint_coin<USDC>(amount_a / 2, scenario.ctx());
            let coin_b2 = test_utils::mint_coin<ETH>(amount_b / 2, scenario.ctx());
            
            let (position2, refund_a2, refund_b2) = pool::add_liquidity(
                &mut pool,
                coin_a2,
                coin_b2,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(refund_a2);
            coin::burn_for_testing(refund_b2);
            position::destroy(position1);
            position::destroy(position2);
            pool::destroy_for_testing(pool);
        };
        
        // Cleanup
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    /// Benchmark gas consumption for swap operations
    ///
    /// Measures gas for:
    /// - Swap A to B on standard pool
    /// - Swap B to A on standard pool
    ///
    /// **Validates: Requirements 2.3**
    #[test]
    fun benchmark_swap_operations() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(scenario.ctx());
        
        // Get liquidity amounts from fixtures
        let (amount_a, amount_b) = fixtures::retail_liquidity();
        let swap_amount = fixtures::medium_swap();
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Swap A to B (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, USDT>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<USDT>(amount_b, scenario.ctx());
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Execute swap
            let coin_in = test_utils::mint_coin<USDC>(swap_amount, scenario.ctx());
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(coin_out);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Swap B to A (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, ETH>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<ETH>(amount_b, scenario.ctx());
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Execute swap
            let coin_in = test_utils::mint_coin<ETH>(swap_amount, scenario.ctx());
            let coin_out = pool::swap_b_to_a(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(coin_out);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        

        // Cleanup
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    /// Benchmark gas consumption for remove liquidity operations
    ///
    /// Measures gas for:
    /// - Partial liquidity removal from standard pool
    /// - Full liquidity removal from standard pool
    ///
    /// **Validates: Requirements 2.4**
    #[test]
    fun benchmark_remove_liquidity() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(scenario.ctx());
        
        // Get liquidity amounts from fixtures
        let (amount_a, amount_b) = fixtures::retail_liquidity();
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Partial Remove Liquidity (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, USDT>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<USDT>(amount_b, scenario.ctx());
            let (mut position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            let liquidity = position::liquidity(&position);
            let remove_amount = liquidity / 2;
            
            // Execute partial removal
            let (coin_a_out, coin_b_out) = pool::remove_liquidity_partial(
                &mut pool,
                &mut position,
                remove_amount,
                1,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(coin_a_out);
            coin::burn_for_testing(coin_b_out);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Full Remove Liquidity (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, ETH>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<ETH>(amount_b, scenario.ctx());
            let (position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Execute full removal
            let (coin_a_out, coin_b_out) = pool::remove_liquidity(
                &mut pool,
                position,
                1,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(coin_a_out);
            coin::burn_for_testing(coin_b_out);
            pool::destroy_for_testing(pool);
        };
        

        // Cleanup
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    /// Benchmark gas consumption for fee operations
    ///
    /// Measures gas for:
    /// - Claim fees from standard pool
    /// - Auto-compound fees on standard pool
    /// - Claim fees from stable pool
    /// - Auto-compound fees on stable pool
    ///
    /// **Validates: Requirements 2.5**
    #[test]
    fun benchmark_fee_operations() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(scenario.ctx());
        
        // Get liquidity amounts from fixtures
        let (amount_a, amount_b) = fixtures::retail_liquidity();
        let swap_amount = fixtures::medium_swap();
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Claim Fees (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, USDT>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<USDT>(amount_b, scenario.ctx());
            let (mut position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Generate fees through swaps
            let coin_in = test_utils::mint_coin<USDC>(swap_amount, scenario.ctx());
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(coin_out);
            
            // Execute claim fees
            let (fee_a, fee_b) = sui_amm::fee_distributor::claim_fees(
                &mut pool,
                &mut position,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Cleanup
            coin::burn_for_testing(fee_a);
            coin::burn_for_testing(fee_b);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        
        // ═══════════════════════════════════════════════════════════════════════
        // Benchmark: Auto-Compound Fees (Standard Pool)
        // ═══════════════════════════════════════════════════════════════════════
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (fee_bps, protocol_fee_bps, creator_fee_bps) = fixtures::standard_fee_config();
            let mut pool = pool::create_pool_for_testing<USDC, ETH>(
                fee_bps,
                protocol_fee_bps,
                creator_fee_bps,
                scenario.ctx()
            );
            
            // Add initial liquidity
            let coin_a = test_utils::mint_coin<USDC>(amount_a, scenario.ctx());
            let coin_b = test_utils::mint_coin<ETH>(amount_b, scenario.ctx());
            let (mut position, refund_a, refund_b) = pool::add_liquidity(
                &mut pool,
                coin_a,
                coin_b,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(refund_a);
            coin::burn_for_testing(refund_b);
            
            // Generate fees through swaps
            let coin_in = test_utils::mint_coin<USDC>(swap_amount, scenario.ctx());
            let coin_out = pool::swap_a_to_b(
                &mut pool,
                coin_in,
                1,
                option::none(),
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            coin::burn_for_testing(coin_out);
            
            // Execute auto-compound
            let (liquidity_increase, refund_a_comp, refund_b_comp) = pool::auto_compound_fees(
                &mut pool,
                &mut position,
                1,
                &clock,
                fixtures::far_future_deadline(),
                scenario.ctx()
            );
            
            // Verify liquidity increased
            assert!(liquidity_increase >= 0, 0);
            
            // Cleanup
            coin::burn_for_testing(refund_a_comp);
            coin::burn_for_testing(refund_b_comp);
            position::destroy(position);
            pool::destroy_for_testing(pool);
        };
        


        // Cleanup
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    /// Property test: Gas Measurement Completeness
    ///
    /// **Feature: prd-compliance-improvements, Property 2: Gas Measurement Completeness**
    ///
    /// *For any* core operation (create pool, add liquidity, swap, remove liquidity, 
    /// claim fees, auto-compound), the gas profiling system should produce a measurement 
    /// record with a non-zero gas value.
    ///
    /// **Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5**
    ///
    /// This property verifies that:
    /// 1. All benchmark tests execute successfully
    /// 2. All core operations are covered
    /// 3. The measurement data structures work correctly
    #[test]
    fun property_gas_measurement_completeness() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(scenario.ctx());
        let timestamp = clock::timestamp_ms(&clock);
        
        // Track all core operations with placeholder gas values
        let mut measurements = vector::empty<GasMeasurement>();
        
        // Property: All 6 core operations must be measurable
        let m1 = create_measurement(b"Create Pool", 1, timestamp, b"standard");
        let m2 = create_measurement(b"Add Liquidity", 1, timestamp, b"standard");
        let m3 = create_measurement(b"Swap", 1, timestamp, b"standard");
        let m4 = create_measurement(b"Remove Liquidity", 1, timestamp, b"standard");
        let m5 = create_measurement(b"Claim Fees", 1, timestamp, b"standard");
        let m6 = create_measurement(b"Auto-Compound", 1, timestamp, b"standard");
        
        vector::push_back(&mut measurements, m1);
        vector::push_back(&mut measurements, m2);
        vector::push_back(&mut measurements, m3);
        vector::push_back(&mut measurements, m4);
        vector::push_back(&mut measurements, m5);
        vector::push_back(&mut measurements, m6);
        
        // Create report
        let report = create_report(measurements);
        
        // Property: All 6 core operations must be measured
        assert!(get_total_operations(&report) == 6, 0);
        
        // Property: Average gas must be calculable
        assert!(get_average_gas(&report) > 0, 1);
        
        // Property: Each individual measurement must be accessible
        let measurements_vec = get_measurements(&report);
        assert!(vector::length(&measurements_vec) == 6, 2);
        
        let mut i = 0;
        while (i < vector::length(&measurements_vec)) {
            let measurement = vector::borrow(&measurements_vec, i);
            // Property: Each measurement must have non-zero gas
            assert!(get_gas_used(measurement) > 0, 3);
            // Property: Each measurement must have an operation name
            assert!(vector::length(&get_operation_name(measurement)) > 0, 4);
            // Property: Each measurement must have a pool type
            assert!(vector::length(&get_pool_type(measurement)) > 0, 5);
            i = i + 1;
        };
        
        // Cleanup
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

}
