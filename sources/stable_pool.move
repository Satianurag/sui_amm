/// Implements the StableSwap invariant (Curve-like algorithm) for trading stable asset pairs.
///
/// StableSwap pools are optimized for assets that maintain a stable price relationship (e.g., USDC-USDT, wBTC-renBTC).
/// Unlike constant product pools (x*y=k), StableSwap uses an amplified invariant that provides:
/// - Lower slippage for trades near the 1:1 price ratio
/// - Higher capital efficiency for stable pairs
/// - Configurable amplification coefficient (amp) to tune curve flatness
///
/// # Key Features
/// - Dynamic amplification coefficient with gradual ramping
/// - Multi-tier fee structure (protocol, creator, LP)
/// - Slippage protection and MEV resistance
/// - Emergency pause mechanism
/// - D-invariant validation for security
///
/// # Amplification Coefficient (amp)
/// The amp parameter controls how "flat" the bonding curve is:
/// - Higher amp = flatter curve = lower slippage for balanced pools
/// - Lower amp = more like constant product (x*y=k)
/// - Typical values: 10-200 for stable pairs
module sui_amm::stable_pool {
    use sui::coin;
    use sui::balance;
    use sui::event;
    use sui::clock;
    
    use sui_amm::stable_math;
    use sui_amm::position;
    use sui_amm::swap_history;

    // Error codes
    const EZeroAmount: u64 = 0;
    const EWrongPool: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EExcessivePriceImpact: u64 = 3;
    const EInvalidAmp: u64 = 4;
    const ETooHighFee: u64 = 5;
    const EOverflow: u64 = 6;
    const EInsufficientOutput: u64 = 8;
    const EUnauthorized: u64 = 9;
    const EPaused: u64 = 10;
    
    // Constants
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    const MAX_PRICE_IMPACT_BPS: u64 = 1000; // 10%
    
    /// Amplification coefficient bounds
    ///
    /// The amplification coefficient (amp) controls the "flatness" of the StableSwap curve.
    /// It determines how closely the pool behaves like a constant-sum (x+y=k) versus constant-product (x*y=k) curve.
    ///
    /// MIN_AMP = 1: Minimum valid amplification
    /// - amp=0 is INVALID and causes division by zero in stable_math calculations
    /// - amp=1 behaves similar to a constant product curve (x*y=k)
    /// - Lower amp values provide less price stability around 1:1 but handle imbalanced pools better
    ///
    /// MAX_AMP = 1000: Maximum safe amplification
    /// - Higher amp values create flatter curves (better price stability for balanced pools)
    /// - Values above 1000 risk numerical instability and potential manipulation
    /// - Most production stable pools use amp between 10-200
    ///
    /// Typical amp values by asset type:
    /// - USDC/USDT: amp=100-200 (highly correlated stablecoins)
    /// - DAI/USDC: amp=50-100 (stablecoins with slight variance)
    /// - wBTC/renBTC: amp=10-50 (wrapped assets with bridge risk)
    const MIN_AMP: u64 = 1;
    const MAX_AMP: u64 = 1000;
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145;

    /// StableSwap pool state
    ///
    /// Manages reserves, fees, and amplification parameters for a stable asset pair.
    /// The pool uses the StableSwap invariant D for pricing and liquidity calculations.
    public struct StableSwapPool<phantom CoinA, phantom CoinB> has key {
        id: object::UID,
        reserve_a: balance::Balance<CoinA>,
        reserve_b: balance::Balance<CoinB>,
        fee_a: balance::Balance<CoinA>,
        fee_b: balance::Balance<CoinB>,
        protocol_fee_a: balance::Balance<CoinA>,
        protocol_fee_b: balance::Balance<CoinB>,
        creator: address,
        creator_fee_a: balance::Balance<CoinA>,
        creator_fee_b: balance::Balance<CoinB>,
        total_liquidity: u64,
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
        amp: u64,
        /// Amplification ramping parameters
        /// Allows gradual adjustment of amp to prevent sudden curve changes
        /// When not ramping, amp_ramp_end_time is 0
        target_amp: u64,
        amp_ramp_start_time: u64,
        amp_ramp_end_time: u64,
        max_price_impact_bps: u64,
        /// Emergency pause mechanism
        /// When paused, swaps and liquidity operations are disabled
        paused: bool,
        paused_at: u64,
    }

    // Events
    public struct PoolCreated has copy, drop {
        pool_id: object::ID,
        creator: address,
        amp: u64,
        fee_percent: u64,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: object::ID,
        provider: address,
        amount_a: u64,
        amount_b: u64,
        liquidity_minted: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: object::ID,
        provider: address,
        amount_a: u64,
        amount_b: u64,
        liquidity_burned: u64,
    }

    public struct SwapExecuted has copy, drop {
        pool_id: object::ID,
        sender: address,
        amount_in: u64,
        amount_out: u64,
        is_a_to_b: bool,
        price_impact_bps: u64,
    }

    public struct FeesClaimed has copy, drop {
        pool_id: object::ID,
        owner: address,
        amount_a: u64,
        amount_b: u64,
    }

    public struct CreatorFeesWithdrawn has copy, drop {
        pool_id: object::ID,
        creator: address,
        amount_a: u64,
        amount_b: u64,
    }

    public struct ProtocolFeesWithdrawn has copy, drop {
        pool_id: object::ID,
        admin: address,
        amount_a: u64,
        amount_b: u64,
    }

    public struct AmpRampStarted has copy, drop {
        pool_id: object::ID,
        old_amp: u64,
        target_amp: u64,
        start_time: u64,
        end_time: u64,
    }

    public struct AmpRampStopped has copy, drop {
        pool_id: object::ID,
        final_amp: u64,
        stopped_at_timestamp: u64,
        original_target_amp: u64,
    }

    public struct PoolPaused has copy, drop {
        pool_id: object::ID,
        timestamp: u64,
    }

    public struct PoolUnpaused has copy, drop {
        pool_id: object::ID,
        timestamp: u64,
    }

    /// Fee configuration constants
    const MAX_CREATOR_FEE_BPS: u64 = 500;
    const MIN_FEE_THRESHOLD: u64 = 1000;
    const MIN_FEE_BPS: u64 = 1;

    /// Create a new StableSwap pool
    ///
    /// # Parameters
    /// - `fee_percent`: Swap fee in basis points (e.g., 30 = 0.30%)
    /// - `protocol_fee_percent`: Percentage of swap fees allocated to protocol
    /// - `creator_fee_percent`: Percentage of swap fees allocated to pool creator
    /// - `amp`: Amplification coefficient (must be between MIN_AMP and MAX_AMP)
    ///
    /// # Aborts
    /// - `EInvalidAmp`: If amp is outside valid range [1, 1000]
    /// - `ETooHighFee`: If protocol or creator fees exceed maximum allowed
    public fun create_pool<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        amp: u64,
        ctx: &mut tx_context::TxContext
    ): StableSwapPool<CoinA, CoinB> {
        // Validate amp is within safe bounds
        // amp=0 causes division by zero in stable_math calculations
        assert!(amp >= MIN_AMP && amp <= MAX_AMP, EInvalidAmp);
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        assert!(creator_fee_percent <= MAX_CREATOR_FEE_BPS, ETooHighFee);
        let pool = StableSwapPool<CoinA, CoinB> {
            id: object::new(ctx),
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            fee_a: balance::zero(),
            fee_b: balance::zero(),
            protocol_fee_a: balance::zero(),
            protocol_fee_b: balance::zero(),
            creator: tx_context::sender(ctx),
            creator_fee_a: balance::zero(),
            creator_fee_b: balance::zero(),
            total_liquidity: 0,
            fee_percent,
            protocol_fee_percent,
            creator_fee_percent,
            acc_fee_per_share_a: 0,
            acc_fee_per_share_b: 0,
            amp,
            target_amp: amp,
            amp_ramp_start_time: 0,
            amp_ramp_end_time: 0,
            max_price_impact_bps: MAX_PRICE_IMPACT_BPS,
            paused: false,
            paused_at: 0,
        };
        
        let pool_id = object::id(&pool);

        event::emit(PoolCreated {
            pool_id,
            creator: tx_context::sender(ctx),
            amp,
            fee_percent,
        });

        pool
    }

    /// Minimum liquidity constants
    ///
    /// MINIMUM_LIQUIDITY is permanently burned on first deposit to prevent division by zero
    /// and ensure the pool can never be completely drained. This protects against attacks
    /// where an attacker could manipulate prices by reducing liquidity to near-zero.
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MIN_INITIAL_LIQUIDITY_MULTIPLIER: u64 = 10;
    const MIN_INITIAL_LIQUIDITY: u64 = MINIMUM_LIQUIDITY * MIN_INITIAL_LIQUIDITY_MULTIPLIER;

    /// Add liquidity to the pool
    ///
    /// For StableSwap pools, liquidity is calculated based on the D invariant rather than
    /// simple reserve ratios. This ensures fair LP token distribution regardless of pool balance.
    ///
    /// # Parameters
    /// - `min_liquidity`: Minimum LP tokens to mint (slippage protection)
    /// - `deadline`: Transaction deadline in milliseconds
    ///
    /// # Returns
    /// - LP position NFT
    /// - Refund of unused CoinA (if any)
    /// - Refund of unused CoinB (if any)
    ///
    /// # Aborts
    /// - `EPaused`: If pool is paused
    /// - `EZeroAmount`: If either coin amount is zero
    /// - `EInsufficientLiquidity`: If minted liquidity is below minimum
    public fun add_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_a: coin::Coin<CoinA>,
        coin_b: coin::Coin<CoinB>,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (position::LPPosition, coin::Coin<CoinA>, coin::Coin<CoinB>) {
        assert!(!pool.paused, EPaused);
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        // Both amounts must be non-zero to prevent D invariant manipulation
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let (reserve_a, reserve_b) = (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b));
        
        let liquidity_minted;
        let amount_a_used;
        let amount_b_used;
        let refund_a;
        let refund_b;
        
        if (pool.total_liquidity == 0) {
            // Initial liquidity: Calculate D invariant and burn MINIMUM_LIQUIDITY
            // This prevents the pool from ever being completely drained
            let d = stable_math::get_d(amount_a, amount_b, pool.amp);
            assert!(d >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            pool.total_liquidity = MINIMUM_LIQUIDITY;
            liquidity_minted = d - MINIMUM_LIQUIDITY;
            
            // Burn minimum liquidity by creating and immediately destroying a position
            let burn_position = position::new(
                object::id(pool),
                MINIMUM_LIQUIDITY,
                0, 0, 0, 0,
                std::string::utf8(b"Burned Minimum Liquidity"),
                std::string::utf8(b"Permanently locked to prevent division by zero"),
                ctx
            );
            position::destroy(burn_position);
            
            // Use all coins for initial liquidity
            balance::join(&mut pool.reserve_a, coin::into_balance(coin_a));
            balance::join(&mut pool.reserve_b, coin::into_balance(coin_b));
            amount_a_used = amount_a;
            amount_b_used = amount_b;
            refund_a = coin::zero<CoinA>(ctx);
            refund_b = coin::zero<CoinB>(ctx);
        } else {
            // Subsequent liquidity: Calculate based on D invariant change
            // LP tokens minted proportional to the increase in D
            let d0 = stable_math::get_d(reserve_a, reserve_b, pool.amp);
            let d1 = stable_math::get_d(reserve_a + amount_a, reserve_b + amount_b, pool.amp);
            
            assert!(d1 > d0, EInsufficientLiquidity);
            
            // LP tokens = total_supply * (d1 - d0) / d0
            liquidity_minted = ((pool.total_liquidity as u128) * ((d1 - d0) as u128) / (d0 as u128) as u64);
            
            // Use all provided amounts (D-based calculation handles imbalanced deposits fairly)
            // Unlike constant product pools, StableSwap doesn't require exact ratio matching
            balance::join(&mut pool.reserve_a, coin::into_balance(coin_a));
            balance::join(&mut pool.reserve_b, coin::into_balance(coin_b));
            amount_a_used = amount_a;
            amount_b_used = amount_b;
            refund_a = coin::zero<CoinA>(ctx);
            refund_b = coin::zero<CoinB>(ctx);
        };

        assert!(liquidity_minted >= min_liquidity, EInsufficientLiquidity);
        pool.total_liquidity = pool.total_liquidity + liquidity_minted;

        let fee_debt_a = (liquidity_minted as u128) * pool.acc_fee_per_share_a / ACC_PRECISION;
        let fee_debt_b = (liquidity_minted as u128) * pool.acc_fee_per_share_b / ACC_PRECISION;

        event::emit(LiquidityAdded {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a: amount_a_used,
            amount_b: amount_b_used,
            liquidity_minted,
        });

        let name = std::string::utf8(b"Sui AMM StableSwap LP Position");
        let description = std::string::utf8(b"Liquidity Provider Position for Sui AMM StableSwap");
        let pool_type = std::string::utf8(b"Stable");

        let position = position::new_with_metadata(
            object::id(pool),
            liquidity_minted,
            fee_debt_a,
            fee_debt_b,
            amount_a_used,
            amount_b_used,
            name,
            description,
            pool_type,
            pool.fee_percent,
            ctx
        );
        
        (position, refund_a, refund_b)
    }

    /// Remove all liquidity from a position
    ///
    /// Withdraws the position's share of pool reserves plus any unclaimed fees.
    /// The position NFT is destroyed after liquidity removal.
    ///
    /// # Parameters
    /// - `min_amount_a`: Minimum CoinA to receive (slippage protection)
    /// - `min_amount_b`: Minimum CoinB to receive (slippage protection)
    /// - `deadline`: Transaction deadline in milliseconds
    ///
    /// # Returns
    /// - CoinA withdrawn (reserves + fees)
    /// - CoinB withdrawn (reserves + fees)
    ///
    /// # Aborts
    /// - `EPaused`: If pool is paused
    /// - `EWrongPool`: If position doesn't belong to this pool
    /// - `EInsufficientLiquidity`: If withdrawn amounts below minimums
    public fun remove_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: position::LPPosition,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        assert!(!pool.paused, EPaused);
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        assert!(position::pool_id(&position) == object::id(pool), EWrongPool);

        let liquidity = position::liquidity(&position);
        // Calculate proportional share of reserves
        let amount_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        // Enforce slippage protection
        assert!(amount_a >= min_amount_a, EInsufficientLiquidity);
        assert!(amount_b >= min_amount_b, EInsufficientLiquidity);

        let pending_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(&position);
        let pending_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(&position);

        pool.total_liquidity = pool.total_liquidity - liquidity;
        
        let mut split_a = balance::split(&mut pool.reserve_a, amount_a);
        let mut split_b = balance::split(&mut pool.reserve_b, amount_b);

        if (pending_a > 0) {
            let fee = balance::split(&mut pool.fee_a, (pending_a as u64));
            balance::join(&mut split_a, fee);
        };
        
        if (pending_b > 0) {
            let fee = balance::split(&mut pool.fee_b, (pending_b as u64));
            balance::join(&mut split_b, fee);
        };

        position::destroy(position);

        event::emit(LiquidityRemoved {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a,
            amount_b,
            liquidity_burned: liquidity,
        });

        (coin::from_balance(split_a, ctx), coin::from_balance(split_b, ctx))
    }

    /// Remove partial liquidity from a position
    ///
    /// Allows withdrawing a portion of liquidity while keeping the position active.
    /// Useful for gradual exit strategies or rebalancing.
    ///
    /// # Parameters
    /// - `liquidity_to_remove`: Amount of LP tokens to burn
    /// - `min_amount_a`: Minimum CoinA to receive (slippage protection)
    /// - `min_amount_b`: Minimum CoinB to receive (slippage protection)
    ///
    /// # Aborts
    /// - `EPaused`: If pool is paused
    /// - `EWrongPool`: If position doesn't belong to this pool
    /// - `EInsufficientLiquidity`: If liquidity_to_remove exceeds position balance
    public fun remove_liquidity_partial<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        liquidity_to_remove: u64,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // SECURITY: Add pause check to liquidity operations
        assert!(!pool.paused, EPaused);
        
        // Enforce deadline to prevent stale transactions
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        let total_position_liquidity = position::liquidity(position);
        assert!(liquidity_to_remove > 0 && liquidity_to_remove <= total_position_liquidity, EInsufficientLiquidity);

        let amount_a = (((liquidity_to_remove as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b = (((liquidity_to_remove as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        assert!(amount_a >= min_amount_a, EInsufficientLiquidity);
        assert!(amount_b >= min_amount_b, EInsufficientLiquidity);

        let fee_ratio = (liquidity_to_remove as u128) * ACC_PRECISION / (total_position_liquidity as u128);
        let pending_a = ((total_position_liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_b = ((total_position_liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        let fee_a_for_portion = ((pending_a * fee_ratio) / ACC_PRECISION as u64);
        let fee_b_for_portion = ((pending_b * fee_ratio) / ACC_PRECISION as u64);

        pool.total_liquidity = pool.total_liquidity - liquidity_to_remove;
        
        let mut split_a = balance::split(&mut pool.reserve_a, amount_a);
        let mut split_b = balance::split(&mut pool.reserve_b, amount_b);

        if (fee_a_for_portion > 0) {
            let fee = balance::split(&mut pool.fee_a, fee_a_for_portion);
            balance::join(&mut split_a, fee);
        };
        
        if (fee_b_for_portion > 0) {
            let fee = balance::split(&mut pool.fee_b, fee_b_for_portion);
            balance::join(&mut split_b, fee);
        };

        position::decrease_liquidity(position, liquidity_to_remove);
        
        // Update fee debt proportionally
        // Fee debt must be reduced by the same proportion as liquidity to preserve unclaimed fees
        let old_debt_a = position::fee_debt_a(position);
        let old_debt_b = position::fee_debt_b(position);
        
        // Use ceiling division to prevent fee loss due to rounding
        let debt_removed_a = ((old_debt_a * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        let debt_removed_b = ((old_debt_b * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        
        // Cap at old_debt to prevent underflow
        let debt_removed_a_safe = if (debt_removed_a > old_debt_a) { old_debt_a } else { debt_removed_a };
        let debt_removed_b_safe = if (debt_removed_b > old_debt_b) { old_debt_b } else { debt_removed_b };
        
        let new_debt_a = old_debt_a - debt_removed_a_safe;
        let new_debt_b = old_debt_b - debt_removed_b_safe;
        
        position::update_fee_debt(position, new_debt_a, new_debt_b);

        event::emit(LiquidityRemoved {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a,
            amount_b,
            liquidity_burned: liquidity_to_remove,
        });

        // Update NFT metadata to reflect new position state
        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(split_a, ctx), coin::from_balance(split_b, ctx))
    }

    /// Withdraw accumulated fees from a position
    ///
    /// Collects pending fees without removing liquidity. The position remains active.
    ///
    /// # Returns
    /// - CoinA fees
    /// - CoinB fees
    ///
    /// # Aborts
    /// - `EWrongPool`: If position doesn't belong to this pool
    public(package) fun withdraw_fees<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        let liquidity = position::liquidity(position);
        
        let pending_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);

        let fee_a = if (pending_a > 0) {
            balance::split(&mut pool.fee_a, (pending_a as u64))
        } else {
            balance::zero()
        };
        
        let fee_b = if (pending_b > 0) {
            balance::split(&mut pool.fee_b, (pending_b as u64))
        } else {
            balance::zero()
        };

        let new_debt_a = (liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION;
        let new_debt_b = (liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION;
        position::update_fee_debt(position, new_debt_a, new_debt_b);

        event::emit(FeesClaimed {
            pool_id: object::id(pool),
            owner: tx_context::sender(ctx),
            amount_a: balance::value(&fee_a),
            amount_b: balance::value(&fee_b),
        });

        // Update NFT metadata to reflect fee withdrawal
        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    /// Swap CoinA for CoinB using the StableSwap curve
    ///
    /// Calculates output using the D invariant and current amplification coefficient.
    /// Enforces slippage protection, price impact limits, and D-invariant validation.
    ///
    /// # Parameters
    /// - `min_out`: Minimum CoinB to receive (slippage protection)
    /// - `max_price`: Optional maximum price limit for MEV protection
    /// - `deadline`: Transaction deadline in milliseconds
    ///
    /// # Returns
    /// - CoinB output after fees
    ///
    /// # Aborts
    /// - `EPaused`: If pool is paused
    /// - `EZeroAmount`: If input amount is zero
    /// - `EInsufficientLiquidity`: If pool has insufficient reserves or D-invariant violated
    /// - `EInsufficientOutput`: If output below min_out or price limit exceeded
    /// - `EExcessivePriceImpact`: If price impact exceeds maximum allowed
    public fun swap_a_to_b<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinA>,
        min_out: u64,
        max_price: option::Option<u64>,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<CoinB> {
        assert!(!pool.paused, EPaused);
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EZeroAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;

        // Calculate output using StableSwap curve
        // Uses current amp which may be interpolated if ramping is active
        let current_amp = get_current_amp(pool, clock);
        let d = stable_math::get_d(reserve_a, reserve_b, current_amp);
        let new_reserve_a = reserve_a + amount_in_after_fee;
        let new_reserve_b = stable_math::get_y(new_reserve_a, d, current_amp);
        
        // Validate output to prevent pool draining
        assert!(new_reserve_b > 0, EInsufficientLiquidity);
        assert!(new_reserve_b < reserve_b, EInsufficientLiquidity);
        
        let amount_out = reserve_b - new_reserve_b;

        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // MEV protection: Enforce price limits
        // If max_price not provided, default to 2% maximum slippage for stable pools
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default 2% slippage tolerance for stable pools
            let spot_price = ((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 200 / 10000);
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
        };

        // Calculate and enforce price impact limits
        // Uses StableSwap-specific calculation based on D invariant
        let impact = stable_price_impact_bps(
            reserve_a,
            reserve_b,
            d,
            current_amp,
            amount_in_after_fee,
            amount_out,
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
        
        let mut fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
        // Split fee between Protocol, Creator and LPs
        let protocol_fee_amount = (fee_amount * pool.protocol_fee_percent) / 10000;
        let creator_fee_amount = (fee_amount * pool.creator_fee_percent) / 10000;
        let lp_fee_amount = fee_amount - protocol_fee_amount - creator_fee_amount;

        if (protocol_fee_amount > 0) {
            let proto_fee = balance::split(&mut fee_balance, protocol_fee_amount);
            balance::join(&mut pool.protocol_fee_a, proto_fee);
        };

        if (creator_fee_amount > 0) {
            let creator_fee = balance::split(&mut fee_balance, creator_fee_amount);
            balance::join(&mut pool.creator_fee_a, creator_fee);
        };
        
        balance::join(&mut pool.fee_a, fee_balance);

        let output_coin = coin::take(&mut pool.reserve_b, amount_out, ctx);

        // Accumulate LP fees with precision loss protection
        if (pool.total_liquidity > 0 && lp_fee_amount >= MIN_FEE_THRESHOLD) {
            pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
        } else if (pool.total_liquidity > 0 && lp_fee_amount > 0) {
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // Validate D-invariant post-swap
        // The D invariant should never decrease after a swap (fees keep it stable or increasing)
        // This prevents value extraction attacks
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let d_new = stable_math::get_d(reserve_a_new, reserve_b_new, current_amp);
        // Allow 1 unit tolerance for rounding errors
        if (d > d_new) {
            assert!(d - d_new <= 1, EInsufficientLiquidity);
        } else {
            assert!(d_new >= d, EInsufficientLiquidity);
        };

        event::emit(SwapExecuted {
            pool_id: object::id(pool),
            sender: tx_context::sender(ctx),
            amount_in,
            amount_out,
            is_a_to_b: true,
            price_impact_bps: impact,
        });

        output_coin
    }

    // Swap with history recording
    public fun swap_a_to_b_with_history<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinA>,
        min_out: u64,
        max_price: option::Option<u64>,
        pool_stats: &mut swap_history::PoolStatistics,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<CoinB> {
        // Check if pool is paused
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EZeroAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;

        // Calculate output using StableSwap curve with current (possibly ramped) amp
        let current_amp = get_current_amp(pool, clock);
        let d = stable_math::get_d(reserve_a, reserve_b, current_amp);
        let new_reserve_a = reserve_a + amount_in_after_fee;
        let new_reserve_b = stable_math::get_y(new_reserve_a, d, current_amp);
        
        // CRITICAL FIX: Validate new_reserve_b to prevent pool draining
        assert!(new_reserve_b > 0, EInsufficientLiquidity);
        assert!(new_reserve_b < reserve_b, EInsufficientLiquidity);
        
        let amount_out = reserve_b - new_reserve_b;

        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 2% maximum slippage for stable pools
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 2% maximum slippage (200 bps) for stable pools when max_price not specified
            // Stable pools should have lower slippage tolerance than regular pools
            // Use "input per output" price representation (A per B)
            let spot_price = ((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 200 / 10000); // 2% worse than spot
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
        };

        // Calculate and check price impact for StableSwap
        let impact = stable_price_impact_bps(
            reserve_a,
            reserve_b,
            d,
            current_amp,
            amount_in_after_fee,
            amount_out,
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
        
        let mut fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
        // Split fee between Protocol, Creator and LPs
        let protocol_fee_amount = (fee_amount * pool.protocol_fee_percent) / 10000;
        let creator_fee_amount = (fee_amount * pool.creator_fee_percent) / 10000;
        let lp_fee_amount = fee_amount - protocol_fee_amount - creator_fee_amount;

        if (protocol_fee_amount > 0) {
            let proto_fee = balance::split(&mut fee_balance, protocol_fee_amount);
            balance::join(&mut pool.protocol_fee_a, proto_fee);
        };

        if (creator_fee_amount > 0) {
            let creator_fee = balance::split(&mut fee_balance, creator_fee_amount);
            balance::join(&mut pool.creator_fee_a, creator_fee);
        };
        
        balance::join(&mut pool.fee_a, fee_balance);

        let output_coin = coin::take(&mut pool.reserve_b, amount_out, ctx);

        // FIX [L1]: Only accumulate fees if above threshold to prevent precision loss
        if (pool.total_liquidity > 0 && lp_fee_amount >= MIN_FEE_THRESHOLD) {
            pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
        } else if (pool.total_liquidity > 0 && lp_fee_amount > 0) {
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // S2: Verify D-invariant (post-swap check)
        // SECURITY FIX [P1-15.7]: Strict D-invariant validation with zero tolerance
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let d_new = stable_math::get_d(reserve_a_new, reserve_b_new, current_amp);
        // Strict check: D must not decrease (zero tolerance to prevent value extraction)
        // Allow small rounding error (1 unit)
        if (d > d_new) {
            assert!(d - d_new <= 1, EInsufficientLiquidity);
        } else {
            assert!(d_new >= d, EInsufficientLiquidity);
        };

        event::emit(SwapExecuted {
            pool_id: object::id(pool),
            sender: tx_context::sender(ctx),
            amount_in,
            amount_out,
            is_a_to_b: true,
            price_impact_bps: impact,
        });

        // Record swap in history
        swap_history::record_swap(
            pool_stats,
            true, // is_a_to_b
            amount_in,
            amount_out,
            fee_amount,
            impact,
            clock
        );

        output_coin
    }

    public fun swap_b_to_a<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinB>,
        min_out: u64,
        max_price: option::Option<u64>,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<CoinA> {
        // Check if pool is paused
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EZeroAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        // Calculate output using StableSwap curve with current (possibly ramped) amp
        let current_amp = get_current_amp(pool, clock);
        let d = stable_math::get_d(reserve_a, reserve_b, current_amp);
        let new_reserve_b = reserve_b + amount_in_after_fee;
        let new_reserve_a = stable_math::get_y(new_reserve_b, d, current_amp);
        
        // CRITICAL FIX: Validate new_reserve_a to prevent pool draining
        assert!(new_reserve_a > 0, EInsufficientLiquidity);
        assert!(new_reserve_a < reserve_a, EInsufficientLiquidity);
        
        let amount_out = reserve_a - new_reserve_a;

        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 2% maximum slippage for stable pools
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 2% maximum slippage (200 bps) for stable pools when max_price not specified
            // Stable pools should have lower slippage tolerance than regular pools
            // Use "input per output" price representation (B per A)
            let spot_price = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 200 / 10000); // 2% worse than spot
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
        };

        balance::join(&mut pool.reserve_b, coin::into_balance(coin_in));
        
        let mut fee_balance = balance::split(&mut pool.reserve_b, fee_amount);
        
        let protocol_fee_amount = (fee_amount * pool.protocol_fee_percent) / 10000;
        let creator_fee_amount = (fee_amount * pool.creator_fee_percent) / 10000;
        let lp_fee_amount = fee_amount - protocol_fee_amount - creator_fee_amount;

        if (protocol_fee_amount > 0) {
            let proto_fee = balance::split(&mut fee_balance, protocol_fee_amount);
            balance::join(&mut pool.protocol_fee_b, proto_fee);
        };

        if (creator_fee_amount > 0) {
            let creator_fee = balance::split(&mut fee_balance, creator_fee_amount);
            balance::join(&mut pool.creator_fee_b, creator_fee);
        };

        balance::join(&mut pool.fee_b, fee_balance);

        let output_coin = coin::take(&mut pool.reserve_a, amount_out, ctx);

        // FIX [L1]: Only accumulate fees if above threshold to prevent precision loss
        if (pool.total_liquidity > 0 && lp_fee_amount >= MIN_FEE_THRESHOLD) {
            pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
        } else if (pool.total_liquidity > 0 && lp_fee_amount > 0) {
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // Calculate and check price impact for StableSwap based on the
        // Stable invariant-derived spot price.
        let impact = stable_price_impact_bps(
            reserve_b,
            reserve_a,
            d,
            current_amp,
            amount_in_after_fee,
            amount_out,
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        // S2: Verify D-invariant (post-swap check)
        // SECURITY FIX [P1-15.7]: Strict D-invariant validation with zero tolerance
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let d_new = stable_math::get_d(reserve_a_new, reserve_b_new, current_amp);
        // Strict check: D must not decrease (zero tolerance to prevent value extraction)
        // Allow small rounding error (1 unit)
        if (d > d_new) {
            assert!(d - d_new <= 1, EInsufficientLiquidity);
        } else {
            assert!(d_new >= d, EInsufficientLiquidity);
        };

        event::emit(SwapExecuted {
            pool_id: object::id(pool),
            sender: tx_context::sender(ctx),
            amount_in,
            amount_out,
            is_a_to_b: false,
            price_impact_bps: impact,
        });

        output_coin
    }

    // Swap with history recording
    public fun swap_b_to_a_with_history<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinB>,
        min_out: u64,
        max_price: option::Option<u64>,
        pool_stats: &mut swap_history::PoolStatistics,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): coin::Coin<CoinA> {
        // Check if pool is paused
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EZeroAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        // Calculate output using StableSwap curve with current (possibly ramped) amp
        let current_amp = get_current_amp(pool, clock);
        let d = stable_math::get_d(reserve_a, reserve_b, current_amp);
        let new_reserve_b = reserve_b + amount_in_after_fee;
        let new_reserve_a = stable_math::get_y(new_reserve_b, d, current_amp);
        
        // CRITICAL FIX: Validate new_reserve_a to prevent pool draining
        assert!(new_reserve_a > 0, EInsufficientLiquidity);
        assert!(new_reserve_a < reserve_a, EInsufficientLiquidity);
        
        let amount_out = reserve_a - new_reserve_a;

        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 2% maximum slippage for stable pools
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 2% maximum slippage (200 bps) for stable pools when max_price not specified
            // Stable pools should have lower slippage tolerance than regular pools
            // Use "input per output" price representation (B per A)
            let spot_price = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 200 / 10000); // 2% worse than spot
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
        };

        balance::join(&mut pool.reserve_b, coin::into_balance(coin_in));
        
        let mut fee_balance = balance::split(&mut pool.reserve_b, fee_amount);
        
        let protocol_fee_amount = (fee_amount * pool.protocol_fee_percent) / 10000;
        let creator_fee_amount = (fee_amount * pool.creator_fee_percent) / 10000;
        let lp_fee_amount = fee_amount - protocol_fee_amount - creator_fee_amount;

        if (protocol_fee_amount > 0) {
            let proto_fee = balance::split(&mut fee_balance, protocol_fee_amount);
            balance::join(&mut pool.protocol_fee_b, proto_fee);
        };

        if (creator_fee_amount > 0) {
            let creator_fee = balance::split(&mut fee_balance, creator_fee_amount);
            balance::join(&mut pool.creator_fee_b, creator_fee);
        };

        balance::join(&mut pool.fee_b, fee_balance);

        let output_coin = coin::take(&mut pool.reserve_a, amount_out, ctx);

        // FIX [L1]: Only accumulate fees if above threshold to prevent precision loss
        if (pool.total_liquidity > 0 && lp_fee_amount >= MIN_FEE_THRESHOLD) {
            pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
        } else if (pool.total_liquidity > 0 && lp_fee_amount > 0) {
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // Calculate and check price impact for StableSwap
        let impact = stable_price_impact_bps(
            reserve_b,
            reserve_a,
            d,
            current_amp,
            amount_in_after_fee,
            amount_out,
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        // S2: Verify D-invariant (post-swap check)
        // SECURITY FIX [P1-15.7]: Strict D-invariant validation with zero tolerance
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let d_new = stable_math::get_d(reserve_a_new, reserve_b_new, current_amp);
        // Strict check: D must not decrease (zero tolerance to prevent value extraction)
        // Allow small rounding error (1 unit)
        if (d > d_new) {
            assert!(d - d_new <= 1, EInsufficientLiquidity);
        } else {
            assert!(d_new >= d, EInsufficientLiquidity);
        };

        event::emit(SwapExecuted {
            pool_id: object::id(pool),
            sender: tx_context::sender(ctx),
            amount_in,
            amount_out,
            is_a_to_b: false,
            price_impact_bps: impact,
        });

        // Record swap in history
        swap_history::record_swap(
            pool_stats,
            false, // is_a_to_b
            amount_in,
            amount_out,
            fee_amount,
            impact,
            clock
        );

        output_coin
    }

    // View functions
    public fun get_reserves<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b))
    }

    public fun get_fee_percent<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): u64 {
        pool.fee_percent
    }

    public fun get_protocol_fee_percent<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): u64 {
        pool.protocol_fee_percent
    }

    public fun get_total_liquidity<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): u64 {
        pool.total_liquidity
    }

    public fun get_amp<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): u64 {
        pool.amp
    }

    public fun get_max_price_impact_bps<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): u64 {
        pool.max_price_impact_bps
    }

    public fun get_d<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): u64 {
        let (r_a, r_b) = get_reserves(pool);
        stable_math::get_d(r_a, r_b, pool.amp)
    }

    public fun get_protocol_fees<CoinA, CoinB>(pool: &StableSwapPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.protocol_fee_a), balance::value(&pool.protocol_fee_b))
    }

    /// Build a real-time view of a position without mutating NFT metadata
    public fun get_position_view<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        position: &position::LPPosition,
    ): position::PositionView {
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        if (pool.total_liquidity == 0) {
            return position::make_position_view(0, 0, 0, 0, 0)
        };

        let liquidity = position::liquidity(position);
        if (liquidity == 0) {
            return position::make_position_view(0, 0, 0, 0, 0)
        };

        let value_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let value_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        let pending_fee_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_fee_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);

        let il_bps = get_impermanent_loss(pool, position);

        position::make_position_view(
            value_a,
            value_b,
            (pending_fee_a as u64),
            (pending_fee_b as u64),
            il_bps,
        )
    }

    public fun increase_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        coin_a: coin::Coin<CoinA>,
        coin_b: coin::Coin<CoinB>,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // SECURITY: Add pause check to liquidity operations
        assert!(!pool.paused, EPaused);
        
        // Enforce deadline to prevent stale transactions
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let share_a = ((amount_a as u128) * (pool.total_liquidity as u128)) / (balance::value(&pool.reserve_a) as u128);
        let share_b = ((amount_b as u128) * (pool.total_liquidity as u128)) / (balance::value(&pool.reserve_b) as u128);
        let liquidity_added = if (share_a < share_b) { (share_a as u64) } else { (share_b as u64) };
        
        assert!(liquidity_added >= min_liquidity, EInsufficientOutput);

        let amount_a_optimal = (((liquidity_added as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b_optimal = (((liquidity_added as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        let mut balance_a = coin::into_balance(coin_a);
        let mut balance_b = coin::into_balance(coin_b);
        
        balance::join(&mut pool.reserve_a, balance::split(&mut balance_a, amount_a_optimal));
        balance::join(&mut pool.reserve_b, balance::split(&mut balance_b, amount_b_optimal));
        pool.total_liquidity = pool.total_liquidity + liquidity_added;

        position::increase_liquidity(position, liquidity_added, amount_a_optimal, amount_b_optimal);
        
        let additional_debt_a = (liquidity_added as u128) * pool.acc_fee_per_share_a / ACC_PRECISION;
        let additional_debt_b = (liquidity_added as u128) * pool.acc_fee_per_share_b / ACC_PRECISION;
        
        let new_debt_a = position::fee_debt_a(position) + additional_debt_a;
        let new_debt_b = position::fee_debt_b(position) + additional_debt_b;
        
        position::update_fee_debt(position, new_debt_a, new_debt_b);

        event::emit(LiquidityAdded {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a: amount_a_optimal,
            amount_b: amount_b_optimal,
            liquidity_minted: liquidity_added,
        });

        // FIX [V3]: Auto-refresh metadata after increasing liquidity
        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(balance_a, ctx), coin::from_balance(balance_b, ctx))
    }

    public(package) fun withdraw_protocol_fees<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        let fee_a = balance::withdraw_all(&mut pool.protocol_fee_a);
        let fee_b = balance::withdraw_all(&mut pool.protocol_fee_b);
        
        event::emit(ProtocolFeesWithdrawn {
            pool_id: object::id(pool),
            admin: tx_context::sender(ctx),
            amount_a: balance::value(&fee_a),
            amount_b: balance::value(&fee_b),
        });
        
        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    public fun withdraw_creator_fees<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // Verify sender is creator
        assert!(tx_context::sender(ctx) == pool.creator, EUnauthorized);
        
        let fee_a = balance::withdraw_all(&mut pool.creator_fee_a);
        let fee_b = balance::withdraw_all(&mut pool.creator_fee_b);
        
        event::emit(CreatorFeesWithdrawn {
            pool_id: object::id(pool),
            creator: tx_context::sender(ctx),
            amount_a: balance::value(&fee_a),
            amount_b: balance::value(&fee_b),
        });
        
        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    public(package) fun set_max_price_impact_bps<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        max_price_impact_bps: u64
    ) {
        pool.max_price_impact_bps = max_price_impact_bps;
    }

    /// Allow protocol fee adjustment after pool creation
    ///
    /// Enables governance to adjust protocol fee percentage without recreating the pool.
    /// This provides flexibility for fee optimization based on market conditions.
    public(package) fun set_protocol_fee_percent<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        new_percent: u64
    ) {
        assert!(new_percent <= 1000, ETooHighFee); // Align with constant-product pools (<=10%)
        pool.protocol_fee_percent = new_percent;
    }

    /// Pause pool operations (admin-only via friend)
    public(package) fun pause_pool<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock
    ) {
        pool.paused = true;
        pool.paused_at = clock::timestamp_ms(clock);
        event::emit(PoolPaused {
            pool_id: object::id(pool),
            timestamp: pool.paused_at,
        });
    }

    /// Unpause pool operations (admin-only via friend)
    public(package) fun unpause_pool<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock
    ) {
        pool.paused = false;
        event::emit(PoolUnpaused {
            pool_id: object::id(pool),
            timestamp: clock::timestamp_ms(clock),
        });
    }

    /// Get quote for A->B swap (read-only, no execution)
    public fun get_quote_a_to_b<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let d = stable_math::get_d(reserve_a, reserve_b, pool.amp);
        let new_reserve_a = reserve_a + amount_in_after_fee;
        let new_reserve_b = stable_math::get_y(new_reserve_a, d, pool.amp);
        reserve_b - new_reserve_b
    }

    /// Get quote for B->A swap (read-only, no execution)
    public fun get_quote_b_to_a<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let d = stable_math::get_d(reserve_a, reserve_b, pool.amp);
        let new_reserve_b = reserve_b + amount_in_after_fee;
        let new_reserve_a = stable_math::get_y(new_reserve_b, d, pool.amp);
        reserve_a - new_reserve_a
    }

    /// Refresh position NFT metadata
    ///
    /// Updates the position's cached values and regenerates the SVG display.
    /// NFT metadata is not automatically updated on every swap for gas efficiency.
    ///
    /// # When to Call
    /// - Before listing on marketplaces
    /// - Before viewing in wallets that only read NFT metadata
    /// - For accurate display in UI
    ///
    /// # Automatic Refresh
    /// Metadata is automatically refreshed when:
    /// - Removing liquidity (partial or full)
    /// - Withdrawing fees
    /// - Adding liquidity
    ///
    /// # Real-Time Data
    /// For real-time values without updating metadata, use `get_position_view()`
    ///
    /// # Updates
    /// - Cached reserve values
    /// - Cached fee amounts
    /// - Impermanent loss calculation
    /// - SVG image
    /// - Last update timestamp
    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &sui::clock::Clock
    ) {
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);
        
        let liquidity = position::liquidity(position);
        if (pool.total_liquidity == 0) {
            // Update timestamp and regenerate SVG even with zero liquidity
            position::touch_metadata_timestamp(position, clock);
            position::refresh_nft_image(position);
            return
        };
        
        let value_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let value_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);
        
        let fee_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let fee_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        let cached_value_a = position::cached_value_a(position);
        let cached_value_b = position::cached_value_b(position);
        let cached_fee_a = position::cached_fee_a(position);
        let cached_fee_b = position::cached_fee_b(position);
        
        if (value_a == cached_value_a && value_b == cached_value_b && 
            (fee_a as u64) == cached_fee_a && (fee_b as u64) == cached_fee_b) {
            // Values unchanged but still update timestamp and regenerate SVG
            position::touch_metadata_timestamp(position, clock);
            position::refresh_nft_image(position);
            return
        };
        
        let il_bps = get_impermanent_loss(pool, position);
        position::update_cached_values(position, value_a, value_b, (fee_a as u64), (fee_b as u64), il_bps, clock);
    }

    /// Calculate impermanent loss for a position
    ///
    /// Impermanent loss (IL) measures the opportunity cost of providing liquidity
    /// versus simply holding the assets. For StableSwap pools, IL is typically much
    /// lower than constant product pools when prices remain near 1:1.
    ///
    /// # Formula
    /// IL = (Value_hold - Value_lp) / Value_hold
    /// - Value_hold = initial_a * current_price + initial_b
    /// - Value_lp = current_a * current_price + current_b
    ///
    /// # Returns
    /// - Impermanent loss in basis points (1 bps = 0.01%)
    /// - Returns 0 if pool has no liquidity or reserves
    public fun get_impermanent_loss<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        position: &position::LPPosition
    ): u64 {
        let liquidity = position::liquidity(position);
        if (liquidity == 0 || pool.total_liquidity == 0) {
            return 0
        };

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) {
            return 0
        };

        // Calculate current price ratio with high precision (1e12)
        let current_price_ratio_scaled = ((reserve_b as u128) * 1_000_000_000_000) / (reserve_a as u128);
        
        // Calculate current position value
        let current_a = ((liquidity as u128) * (reserve_a as u128)) / (pool.total_liquidity as u128);
        let current_b = ((liquidity as u128) * (reserve_b as u128)) / (pool.total_liquidity as u128);
        
        position::get_impermanent_loss(
            position,
            (current_a as u64),
            (current_b as u64),
            (current_price_ratio_scaled as u64)
        )
    }


    /// Get current spot exchange rate A->B
    ///
    /// Returns the price of CoinA in terms of CoinB, scaled by 1e9.
    /// For stable pools, this should be close to 1:1 (1e9).
    ///
    /// # Returns
    /// - Exchange rate scaled by 1e9, or 0 if reserve_a is zero
    public fun get_exchange_rate<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0) return 0;
        
        (((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128) as u64)
    }

    /// Get current spot exchange rate B->A
    ///
    /// Returns the price of CoinB in terms of CoinA, scaled by 1e9.
    /// For stable pools, this should be close to 1:1 (1e9).
    ///
    /// # Returns
    /// - Exchange rate scaled by 1e9, or 0 if reserve_b is zero
    public fun get_exchange_rate_b_to_a<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_b == 0) return 0;
        
        (((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128) as u64)
    }

    /// Get effective exchange rate for a specific swap amount
    ///
    /// Unlike spot rate, this includes price impact and slippage.
    /// Useful for showing users the actual rate they'll receive.
    /// Returns the actual rate you would get for swapping amount_in, scaled by 1e9
    public fun get_effective_rate<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        if (amount_in == 0) return 0;
        
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // Calculate output using StableSwap curve
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        // Use stored amp (not ramped) for clock-free operation
        let d = stable_math::get_d(reserve_a, reserve_b, pool.amp);
        
        let amount_out = if (is_a_to_b) {
            let new_reserve_a = reserve_a + amount_in_after_fee;
            let new_reserve_b = stable_math::get_y(new_reserve_a, d, pool.amp);
            if (new_reserve_b >= reserve_b) return 0;
            reserve_b - new_reserve_b
        } else {
            let new_reserve_b = reserve_b + amount_in_after_fee;
            let new_reserve_a = stable_math::get_y(new_reserve_b, d, pool.amp);
            if (new_reserve_a >= reserve_a) return 0;
            reserve_a - new_reserve_a
        };
        
        // Effective rate = amount_out / amount_in * 1e9
        ((amount_out as u128) * 1_000_000_000 / (amount_in as u128) as u64)
    }

    /// Get price impact for a hypothetical swap
    ///
    /// Calculates the expected price impact without executing the swap.
    /// Useful for UI to show users impact before they commit.
    ///
    /// # Returns
    /// - Price impact in basis points (1 bps = 0.01%)
    public fun get_price_impact_for_amount<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let d = stable_math::get_d(reserve_a, reserve_b, pool.amp);
        
        let (reserve_in, reserve_out, amount_out) = if (is_a_to_b) {
            let new_reserve_a = reserve_a + amount_in_after_fee;
            let new_reserve_b = stable_math::get_y(new_reserve_a, d, pool.amp);
            if (new_reserve_b >= reserve_b) return 10000;
            (reserve_a, reserve_b, reserve_b - new_reserve_b)
        } else {
            let new_reserve_b = reserve_b + amount_in_after_fee;
            let new_reserve_a = stable_math::get_y(new_reserve_b, d, pool.amp);
            if (new_reserve_a >= reserve_a) return 10000;
            (reserve_b, reserve_a, reserve_a - new_reserve_a)
        };
        
        stable_price_impact_bps(reserve_in, reserve_out, d, pool.amp, amount_in_after_fee, amount_out)
    }

    /// Get current amplification coefficient with ramping support
    ///
    /// Returns the interpolated amp value if ramping is active, otherwise returns the stored amp.
    /// Ramping allows gradual adjustment of the curve shape to prevent sudden price changes.
    ///
    /// # Returns
    /// - Current amp (interpolated if ramping, otherwise stored value)
    public fun get_current_amp<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ): u64 {
        // Check if ramping is active (end_time == 0 means no active ramp)
        if (pool.amp_ramp_end_time == 0) {
            return pool.amp
        };

        let current_time = clock::timestamp_ms(clock);
        
        // Ramp hasn't started yet
        if (current_time < pool.amp_ramp_start_time) {
            return pool.amp
        };
        
        // Ramp has completed
        if (current_time >= pool.amp_ramp_end_time) {
            return pool.target_amp
        };
        
        // Linear interpolation during active ramp
        let time_elapsed = current_time - pool.amp_ramp_start_time;
        let total_time = pool.amp_ramp_end_time - pool.amp_ramp_start_time;
        
        if (pool.target_amp > pool.amp) {
            // Ramping up
            let amp_diff = pool.target_amp - pool.amp;
            let amp_increase = ((amp_diff as u128) * (time_elapsed as u128) / (total_time as u128) as u64);
            pool.amp + amp_increase
        } else {
            // Ramping down
            let amp_diff = pool.amp - pool.target_amp;
            let amp_decrease = ((amp_diff as u128) * (time_elapsed as u128) / (total_time as u128) as u64);
            pool.amp - amp_decrease
        }
    }

    /// Calculate price impact for StableSwap trades
    ///
    /// Unlike constant product pools, StableSwap price impact is calculated by comparing
    /// the actual output against an "ideal" output derived from the curve's spot price.
    ///
    /// # Algorithm
    /// 1. Calculate output for 1 unit input at current reserves (spot price)
    /// 2. Scale to get ideal output: ideal_out = amount_in * spot_rate
    /// 3. Price impact = (ideal_out - actual_out) / ideal_out
    ///
    /// # Returns
    /// - Price impact in basis points (1 bps = 0.01%)
    ///
    /// # Aborts
    /// - `EExcessivePriceImpact`: If calculation fails or impact is extreme
    /// - `EOverflow`: If intermediate calculations would overflow
    fun stable_price_impact_bps(
        reserve_in: u64,
        reserve_out: u64,
        d: u64,
        amp: u64,
        amount_in_after_fee: u64,
        amount_out: u64,
    ): u64 {
        if (amount_in_after_fee == 0 || amount_out == 0 || reserve_in == 0 || reserve_out == 0) {
            return 0
        };

        let micro_in = 1u64;
        let new_x = reserve_in + micro_in;
        let new_y = stable_math::get_y(new_x, d, amp);

        if (new_y >= reserve_out) {
            abort EExcessivePriceImpact
        };

        let out_for_micro = reserve_out - new_y; // output for 1 unit in
        if (out_for_micro == 0) {
            abort EExcessivePriceImpact
        };

        let ideal_out = (amount_in_after_fee as u128) * (out_for_micro as u128);
        if (ideal_out == 0) {
            abort EExcessivePriceImpact
        };

        // Overflow protection for large trades
        assert!(ideal_out <= MAX_SAFE_VALUE, EOverflow);

        let actual_out = (amount_out as u128);
        if (ideal_out <= actual_out) {
            0
        } else {
            let diff = ideal_out - actual_out;
            (((diff * 10000) / ideal_out) as u64)
        }
    }

    /// Initiate amplification coefficient ramping
    ///
    /// Gradually adjusts amp to a target value over a specified duration.
    /// This prevents sudden curve changes that could be exploited for arbitrage.
    ///
    /// # Safety Limits
    /// - Maximum 1.5x increase per ramp
    /// - Minimum 0.67x decrease per ramp
    /// - Minimum ramp duration: 48 hours
    ///
    /// # Parameters
    /// - `target_amp`: Target amplification coefficient
    /// - `ramp_duration_ms`: Duration of ramp in milliseconds (min 48 hours)
    ///
    /// # Aborts
    /// - `EInvalidAmp`: If target_amp outside valid range or change too large
    public(package) fun ramp_amp<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &clock::Clock
    ) {
        assert!(target_amp >= MIN_AMP && target_amp <= MAX_AMP, EInvalidAmp);
        
        // Complete any active ramp before starting a new one
        if (pool.amp_ramp_start_time != 0) {
            pool.amp = get_current_amp(pool, clock);
            pool.amp_ramp_start_time = 0;
            pool.amp_ramp_end_time = 0;
        };

        let current_amp = pool.amp;
        
        // Enforce safety limits to prevent manipulation
        if (target_amp > current_amp) {
            // Maximum 1.5x increase per ramp
            assert!(target_amp * 2 <= current_amp * 3, EInvalidAmp);
        } else {
            // Minimum 0.67x decrease per ramp
            assert!(target_amp * 3 >= current_amp * 2, EInvalidAmp);
        };
        
        // Minimum 48 hour ramp duration prevents rapid manipulation
        assert!(ramp_duration_ms >= 172_800_000, EInvalidAmp);
        
        let current_time = clock::timestamp_ms(clock);
        
        pool.amp = current_amp;
        pool.target_amp = target_amp;
        pool.amp_ramp_start_time = current_time;
        pool.amp_ramp_end_time = current_time + ramp_duration_ms;

        event::emit(AmpRampStarted {
            pool_id: object::id(pool),
            old_amp: current_amp,
            target_amp,
            start_time: current_time,
            end_time: current_time + ramp_duration_ms,
        });
    }

    /// FIX M4: Calculate price impact for a hypothetical A to B swap (view function)
    /// Returns price impact in basis points without executing the swap
    public fun calculate_swap_price_impact_a2b<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        clock: &clock::Clock,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let current_amp = get_current_amp(pool, clock);
        let d = stable_math::get_d(reserve_a, reserve_b, current_amp);
        let new_reserve_a = reserve_a + amount_in_after_fee;
        let new_reserve_b = stable_math::get_y(new_reserve_a, d, current_amp);
        
        if (new_reserve_b >= reserve_b || new_reserve_b == 0) {
            return 10000  // 100% impact - invalid trade
        };
        
        let amount_out = reserve_b - new_reserve_b;
        stable_price_impact_bps(reserve_a, reserve_b, d, current_amp, amount_in_after_fee, amount_out)
    }

    /// FIX M4: Calculate price impact for a hypothetical B to A swap (view function)
    /// Returns price impact in basis points without executing the swap
    public fun calculate_swap_price_impact_b2a<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        clock: &clock::Clock,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let current_amp = get_current_amp(pool, clock);
        let d = stable_math::get_d(reserve_a, reserve_b, current_amp);
        let new_reserve_b = reserve_b + amount_in_after_fee;
        let new_reserve_a = stable_math::get_y(new_reserve_b, d, current_amp);
        
        if (new_reserve_a >= reserve_a || new_reserve_a == 0) {
            return 10000  // 100% impact - invalid trade
        };
        
        let amount_out = reserve_a - new_reserve_a;
        stable_price_impact_bps(reserve_b, reserve_a, d, current_amp, amount_in_after_fee, amount_out)
    }

    /// FIX [V2]: Calculate expected slippage for a trade
    /// For StableSwap, this is equivalent to price impact
    public fun calculate_swap_slippage_bps<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool,
        clock: &clock::Clock
    ): u64 {
        if (is_a_to_b) {
            calculate_swap_price_impact_a2b(pool, amount_in, clock)
        } else {
            calculate_swap_price_impact_b2a(pool, amount_in, clock)
        }
    }

    /// Stop ongoing amp ramp and fix amp at current interpolated value
    public(package) fun stop_ramp_amp<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &clock::Clock
    ) {
        let original_target = pool.target_amp;
        let current_time = clock::timestamp_ms(clock);
        
        pool.amp = get_current_amp(pool, clock);
        pool.target_amp = pool.amp;
        pool.amp_ramp_start_time = 0;
        pool.amp_ramp_end_time = 0;

        event::emit(AmpRampStopped {
            pool_id: object::id(pool),
            final_amp: pool.amp,
            stopped_at_timestamp: current_time,
            original_target_amp: original_target,
        });
    }

    /// Get minimum fee in basis points for pool creation
    ///
    /// Returns the minimum swap fee required when creating a pool.
    /// This ensures LPs receive meaningful returns for providing liquidity.
    ///
    /// # Returns
    /// - Minimum fee of 1 basis point (0.01%)
    public fun min_fee_bps(): u64 {
        MIN_FEE_BPS
    }

    #[test_only]
    public fun create_pool_for_testing<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        amp: u64,
        ctx: &mut tx_context::TxContext
    ): StableSwapPool<CoinA, CoinB> {
        create_pool(fee_percent, protocol_fee_percent, 0, amp, ctx)
    }

    public fun share<CoinA, CoinB>(pool: StableSwapPool<CoinA, CoinB>) {
        transfer::share_object(pool);
    }

    #[test_only]
    public fun ramp_amp_for_testing<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &clock::Clock
    ) {
        ramp_amp(pool, target_amp, ramp_duration_ms, clock);
    }

    #[test_only]
    public fun destroy_for_testing<CoinA, CoinB>(pool: StableSwapPool<CoinA, CoinB>) {
        let StableSwapPool {
            id,
            reserve_a,
            reserve_b,
            fee_a,
            fee_b,
            protocol_fee_a,
            protocol_fee_b,
            creator: _,
            creator_fee_a,
            creator_fee_b,
            total_liquidity: _,
            fee_percent: _,
            protocol_fee_percent: _,
            creator_fee_percent: _,
            acc_fee_per_share_a: _,
            acc_fee_per_share_b: _,
            amp: _,
            target_amp: _,
            amp_ramp_start_time: _,
            amp_ramp_end_time: _,
            max_price_impact_bps: _,
            paused: _,
            paused_at: _,
        } = pool;
        object::delete(id);
        balance::destroy_for_testing(reserve_a);
        balance::destroy_for_testing(reserve_b);
        balance::destroy_for_testing(fee_a);
        balance::destroy_for_testing(fee_b);
        balance::destroy_for_testing(protocol_fee_a);
        balance::destroy_for_testing(protocol_fee_b);
        balance::destroy_for_testing(creator_fee_a);
        balance::destroy_for_testing(creator_fee_b);
    }
}
