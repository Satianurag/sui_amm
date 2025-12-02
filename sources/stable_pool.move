/// Module: stable_pool
/// Description: Implements the StableSwap invariant (Curve-like) for trading stable pairs (e.g., USDC-USDT).
/// Supports dynamic amplification coefficient (A), admin fees, creator fees, and slippage protection.
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
    const ETooHighFee: u64 = 5;  // NEW: For protocol fee validation
    const EOverflow: u64 = 6;  // NEW: For overflow protection
    const EInsufficientOutput: u64 = 8; // NEW: For slippage protection
    const EUnauthorized: u64 = 9; // NEW: Access control
    const EPaused: u64 = 10; // NEW: Pool is paused
    
    // Constants
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    const MAX_PRICE_IMPACT_BPS: u64 = 1000; // 10%
    // AMPLIFICATION COEFFICIENT VALIDATION:
    // The amplification coefficient (amp) controls the "flatness" of the StableSwap curve.
    // 
    // MIN_AMP = 1: Minimum valid amplification
    // - amp=0 is INVALID and will cause division by zero in stable_math calculations
    // - amp=1 behaves similar to a constant product curve (x*y=k)
    // - Lower amp values provide less price stability but more capital efficiency
    // 
    // MAX_AMP = 1000: Maximum safe amplification (reduced from 10000)
    // - Higher amp values create flatter curves (better for stable pairs)
    // - Values above 1000 risk numerical instability and manipulation
    // - Most production stable pools use amp between 10-200
    // 
    // Typical amp values:
    // - USDC/USDT: amp=100-200 (very stable)
    // - DAI/USDC: amp=50-100 (stable)
    // - wBTC/renBTC: amp=10-50 (less stable)
    const MIN_AMP: u64 = 1;
    // SECURITY FIX [P2-18.3]: Reduced MAX_AMP from 10000 to 1000
    // This prevents extreme amplification values that could lead to numerical instability
    // and manipulation attacks. Most stable pools operate well below amp=1000.
    const MAX_AMP: u64 = 1000;  // Reduced from 10000 for safety
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145; // u128::MAX / 10000 - for price impact overflow check

    public struct StableSwapPool<phantom CoinA, phantom CoinB> has key {
        id: object::UID,
        reserve_a: balance::Balance<CoinA>,
        reserve_b: balance::Balance<CoinB>,
        fee_a: balance::Balance<CoinA>,
        fee_b: balance::Balance<CoinB>,
        protocol_fee_a: balance::Balance<CoinA>,
        protocol_fee_b: balance::Balance<CoinB>,
        // FIX: Creator fees support
        creator: address,
        creator_fee_a: balance::Balance<CoinA>,
        creator_fee_b: balance::Balance<CoinB>,
        total_liquidity: u64,
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
        amp: u64, // Current amplification coefficient
        // FIX [L1]: Amp ramping support for dynamic optimization
        target_amp: u64,           // Target amp when ramping
        amp_ramp_start_time: u64,  // Start time of ramp (0 if not ramping)
        amp_ramp_end_time: u64,    // End time of ram (0 if not ramping)
        max_price_impact_bps: u64,
        // Emergency pause mechanism
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

    // FIX [S5]: Max creator fee to protect LPs
    const MAX_CREATOR_FEE_BPS: u64 = 500; // 5% max
    const MIN_FEE_THRESHOLD: u64 = 1000; // Minimum fee to avoid precision loss
    const MIN_FEE_BPS: u64 = 1; // Minimum fee of 1 basis point (0.01%) for pool creation (Requirement 10.1)

    public fun create_pool<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        amp: u64,
        ctx: &mut tx_context::TxContext
    ): StableSwapPool<CoinA, CoinB> {
        // CRITICAL: Validate amp is within safe bounds
        // amp=0 is INVALID and will cause division by zero errors in stable_math
        // amp must be >= MIN_AMP (1) and <= MAX_AMP (1000)
        assert!(amp >= MIN_AMP && amp <= MAX_AMP, EInvalidAmp);
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        // FIX [S5]: Validate creator fee to protect LPs
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
            target_amp: amp,        // Initially no ramp
            amp_ramp_start_time: 0, // 0 means not ramping
            amp_ramp_end_time: 0,   // 0 means not ramping
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

    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MIN_INITIAL_LIQUIDITY_MULTIPLIER: u64 = 10; // Burn cap: creator loses <=10% of seed liquidity
    const MIN_INITIAL_LIQUIDITY: u64 = MINIMUM_LIQUIDITY * MIN_INITIAL_LIQUIDITY_MULTIPLIER;

    public fun add_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_a: coin::Coin<CoinA>,
        coin_b: coin::Coin<CoinB>,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (position::LPPosition, coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // Check if pool is paused
        assert!(!pool.paused, EPaused);
        
        // FIX V2: Deadline enforcement
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        // FIX [L3]: For stable pools, require both amounts > 0 to prevent D manipulation
        // Single-sided deposits can manipulate the invariant in stable pools
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let (reserve_a, reserve_b) = (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b));
        
        let liquidity_minted;
        let amount_a_used;
        let amount_b_used;
        let refund_a;
        let refund_b;
        
        if (pool.total_liquidity == 0) {
            // Initial liquidity
            let d = stable_math::get_d(amount_a, amount_b, pool.amp);
            assert!(d >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            pool.total_liquidity = MINIMUM_LIQUIDITY;
            liquidity_minted = d - MINIMUM_LIQUIDITY;
            
            // Create a position for the burned liquidity and transfer to dead address
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
            // Subsequent liquidity - calculate based on D invariant
            let d0 = stable_math::get_d(reserve_a, reserve_b, pool.amp);
            let d1 = stable_math::get_d(reserve_a + amount_a, reserve_b + amount_b, pool.amp);
            
            assert!(d1 > d0, EInsufficientLiquidity);
            
            // mint = total_supply * (d1 - d0) / d0
            liquidity_minted = ((pool.total_liquidity as u128) * ((d1 - d0) as u128) / (d0 as u128) as u64);
            
            // FIX [L3]: For stable pools, use all provided amounts (D-based calculation already optimal)
            // Unlike constant product, stable pools don't require exact ratio matching
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

    public fun remove_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: position::LPPosition,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // SECURITY FIX [P1-15.4]: Add pause check to liquidity operations
        assert!(!pool.paused, EPaused);
        
        // FIX V2: Deadline enforcement
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        assert!(position::pool_id(&position) == object::id(pool), EWrongPool);

        let liquidity = position::liquidity(&position);
        let amount_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        // CRITICAL FIX [V2]: Slippage protection for remove_liquidity
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

    /// Remove partial liquidity (CRITICAL NEW Feature for PRD compliance)
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
        // SECURITY FIX [P1-15.4]: Add pause check to liquidity operations
        assert!(!pool.paused, EPaused);
        
        // FIX V2: Deadline enforcement
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
        
        // CRITICAL FIX [V1]: Proportional fee debt reduction
        // Old logic (BROKEN): new_debt = remaining_liquidity * acc_fee_per_share
        // This wiped out all unclaimed rewards for the remaining liquidity!
        // New logic (FIXED): new_debt = old_debt - removed_debt
        
        let old_debt_a = position::fee_debt_a(position);
        let old_debt_b = position::fee_debt_b(position);
        
        // FIX [V2]: Use ceiling division for debt removal to prevent fee loss
        // debt_removed = ceil(old_debt * liquidity_to_remove / total_liquidity)
        let debt_removed_a = ((old_debt_a * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        let debt_removed_b = ((old_debt_b * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        
        // Cap at old_debt to prevent underflow (ceiling can exceed in edge cases)
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

        // FIX [V6]: Refresh metadata to ensure NFT display is up-to-date
        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(split_a, ctx), coin::from_balance(split_b, ctx))
    }

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

        // FIX [V6]: Refresh metadata to ensure NFT display is up-to-date
        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    public fun swap_a_to_b<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinA>,
        min_out: u64,
        max_price: option::Option<u64>,
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

        // Calculate and check price impact for StableSwap based on the
        // Stable invariant. Ideal output is approximated from a tiny
        // trade on the curve (spot price), not from a constant-product
        // or naive reserve ratio.
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
        // D should never decrease after a swap (fees should keep it stable or increasing)
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
        // SECURITY FIX [P1-15.4]: Add pause check to liquidity operations
        assert!(!pool.paused, EPaused);
        
        // FIX V2: Deadline enforcement
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

    /// FIX [M2]: Allow protocol fee adjustment after pool creation
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

    /// FIX [S2][V3]: Public function to refresh position metadata from stable pool state
    /// Allows users to update their NFT display with current values without claiming fees.
    /// 
    /// IMPORTANT STALENESS NOTE:
    /// NFT metadata (cached_value_a, cached_value_b, cached_fee_a, cached_fee_b, cached_il_bps)
    /// is NOT automatically updated on every swap to save gas. This is an intentional design
    /// decision for gas efficiency.
    /// 
    /// For real-time data, use get_position_view() which computes values on-demand.
    /// Call this function to update the NFT's Display metadata before:
    /// - Listing on marketplaces
    /// - Viewing in wallets that only read NFT metadata
    /// - Taking screenshots for records
    /// 
    /// The metadata IS automatically refreshed on:
    /// - remove_liquidity_partial()
    /// - withdraw_fees()
    /// - increase_liquidity()
    /// Requirements: 2.3, 2.4 - Refresh metadata and regenerate SVG
    /// This function:
    /// - Updates last_metadata_update_ms timestamp
    /// - Regenerates SVG image (always, even if values unchanged)
    /// - Updates cached values if they've changed
    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &sui::clock::Clock
    ) {
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);
        
        let liquidity = position::liquidity(position);
        if (pool.total_liquidity == 0) {
            // Even with zero liquidity, update timestamp and regenerate SVG
            position::touch_metadata_timestamp(position, clock);
            position::refresh_nft_image(position);
            return
        };
        
        let value_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let value_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);
        
        let fee_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let fee_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        // FIX [Metadata Staleness]: Always update timestamp on explicit refresh
        let cached_value_a = position::cached_value_a(position);
        let cached_value_b = position::cached_value_b(position);
        let cached_fee_a = position::cached_fee_a(position);
        let cached_fee_b = position::cached_fee_b(position);
        
        if (value_a == cached_value_a && value_b == cached_value_b && 
            (fee_a as u64) == cached_fee_a && (fee_b as u64) == cached_fee_b) {
            // Values unchanged but still update timestamp to mark metadata as fresh
            // Task 9: Always regenerate SVG image on refresh, even if values unchanged
            position::touch_metadata_timestamp(position, clock);
            position::refresh_nft_image(position);
            return
        };
        
        let il_bps = get_impermanent_loss(pool, position);
        // update_cached_values already calls refresh_nft_image internally
        position::update_cached_values(position, value_a, value_b, (fee_a as u64), (fee_b as u64), il_bps, clock);
    }

    /// Calculate impermanent loss for stable pool position
    /// Uses approximation: IL = (Value_hold - Value_lp) / Value_hold
    /// 
    /// Note: For StableSwap, IL is generally much lower than constant product pools
    /// as long as the price stays near 1. However, if the price depegs significantly,
    /// IL can still occur.
    /// 
    /// Formula:
    /// IL = (Value_hold - Value_lp) / Value_hold
    /// Value_hold = initial_a * P + initial_b
    /// Value_lp = current_a * P + current_b
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

        // SECURITY FIX [P1-15.5]: Increase IL calculation precision from 1e9 to 1e12
        // Calculate current price ratio
        let current_price_ratio_scaled = ((reserve_b as u128) * 1_000_000_000_000) / (reserve_a as u128);
        
        // Calculate current position value
        let current_a = ((liquidity as u128) * (reserve_a as u128)) / (pool.total_liquidity as u128);
        let current_b = ((liquidity as u128) * (reserve_b as u128)) / (pool.total_liquidity as u128);
        
        // Use position module's corrected IL calculation
        position::get_impermanent_loss(
            position,
            (current_a as u64),
            (current_b as u64),
            (current_price_ratio_scaled as u64)
        )
    }


    /// Get current exchange rate A->B (scaled by 1e9) - For stable pools, should be close to 1:1
    public fun get_exchange_rate<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0) return 0;
        
        // Rate = reserve_b / reserve_a * 1e9
        (((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128) as u64)
    }

    /// Get B to A exchange rate with zero-reserve handling
    /// Returns the price of B in terms of A, scaled by 1e9
    /// Returns 0 if reserve_b is zero to prevent division by zero
    /// For stable pools, this should be close to 1:1 (1e9)
    public fun get_exchange_rate_b_to_a<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        // Handle zero reserve case
        if (reserve_b == 0) return 0;
        
        // Rate = reserve_a / reserve_b * 1e9
        (((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128) as u64)
    }

    /// Get effective rate for a specific swap amount (includes slippage)
    /// Returns the actual rate you would get for swapping amount_in, scaled by 1e9
    /// This differs from spot rate because it accounts for price impact
    /// Uses stored amp value (clock-free) for efficiency
    public fun get_effective_rate<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        // Handle zero amount case
        if (amount_in == 0) return 0;
        
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        // Handle zero reserve cases
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // Calculate output amount after fees using StableSwap curve
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
        
        // Return effective rate: amount_out / amount_in * 1e9
        ((amount_out as u128) * 1_000_000_000 / (amount_in as u128) as u64)
    }

    /// Get price impact for a specific amount before execution
    /// Returns price impact in basis points (1 bps = 0.01%)
    /// Useful for showing users the expected price impact before they execute a swap
    /// Uses stored amp value (clock-free) for efficiency
    public fun get_price_impact_for_amount<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        // Handle edge cases
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        // Use stored amp (not ramped) for clock-free operation
        let d = stable_math::get_d(reserve_a, reserve_b, pool.amp);
        
        let (reserve_in, reserve_out, amount_out) = if (is_a_to_b) {
            let new_reserve_a = reserve_a + amount_in_after_fee;
            let new_reserve_b = stable_math::get_y(new_reserve_a, d, pool.amp);
            if (new_reserve_b >= reserve_b) return 10000; // 100% impact
            (reserve_a, reserve_b, reserve_b - new_reserve_b)
        } else {
            let new_reserve_b = reserve_b + amount_in_after_fee;
            let new_reserve_a = stable_math::get_y(new_reserve_b, d, pool.amp);
            if (new_reserve_a >= reserve_a) return 10000; // 100% impact
            (reserve_b, reserve_a, reserve_a - new_reserve_a)
        };
        
        stable_price_impact_bps(reserve_in, reserve_out, d, pool.amp, amount_in_after_fee, amount_out)
    }

    /// FIX [L1]: Get current amplification coefficient (with ramping support)
    /// Returns interpolated value if ramping is active
    public fun get_current_amp<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        clock: &sui::clock::Clock
    ): u64 {
        // FIX [Amp Ramping Sentinel]: Use end_time == 0 instead of start_time == 0
        // This allows ramping to start at timestamp 0 (e.g., in test environments)
        // If not ramping, amp_ramp_end_time will be 0
        if (pool.amp_ramp_end_time == 0) {
            return pool.amp
        };

        let current_time = clock::timestamp_ms(clock);
        
        // If ramp hasn't started yet, return current amp
        if (current_time < pool.amp_ramp_start_time) {
            return pool.amp
        };
        
        // If ramp has ended, return target amp
        if (current_time >= pool.amp_ramp_end_time) {
            return pool.target_amp
        };
        
        // Linear interpolation during ramp
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

    /// StableSwap-specific price impact helper (basis points).
    /// Instead of comparing against a constant-product "ideal" or a
    /// naive reserve ratio, we approximate the ideal output from the
    /// Stable invariant itself by pricing a tiny trade on the curve.
    ///
    /// Steps (for input token X, output token Y):
    /// 1. Compute out_for_1 = Y_out when swapping 1 unit of X at
    ///    current reserves using the same D and amp.
    /// 2. Ideal_out = amount_in_after_fee * out_for_1.
    /// 3. Impact = max(0, Ideal_out - Actual_out) / Ideal_out.
    /// FIX L4: Added overflow protection
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

        // FIX L4: Check for overflow before multiplication
        assert!(ideal_out <= MAX_SAFE_VALUE, EOverflow);

        let actual_out = (amount_out as u128);
        if (ideal_out <= actual_out) {
            0
        } else {
            let diff = ideal_out - actual_out;
            (((diff * 10000) / ideal_out) as u64)
        }
    }

    /// FIX [L1]: Initiate amp ramping (admin only via friend)
    /// Gradually changes amp to target over specified duration for smooth transitions
    public(package) fun ramp_amp<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &clock::Clock
    ) {
        assert!(target_amp >= MIN_AMP && target_amp <= MAX_AMP, EInvalidAmp);
        
        // FIX L3: Safety limits on amp changes
        // Ensure no active ramp or complete it first
        if (pool.amp_ramp_start_time != 0) {
            pool.amp = get_current_amp(pool, clock);
            pool.amp_ramp_start_time = 0;
            pool.amp_ramp_end_time = 0;
        };

        let current_amp = pool.amp;
        
        // SECURITY FIX [P1-15.6]: Tighten amp ramp limits to prevent manipulation
        // Max 1.5x increase or 0.67x decrease per ramp (reduced from 2x/0.5x)
        if (target_amp > current_amp) {
            // Max 1.5x increase: target_amp <= current_amp * 3 / 2
            assert!(target_amp * 2 <= current_amp * 3, EInvalidAmp);
        } else {
            // Min 0.67x decrease: target_amp >= current_amp * 2 / 3
            assert!(target_amp * 3 >= current_amp * 2, EInvalidAmp);
        };
        
        // SECURITY FIX [P1-15.6]: Extend minimum ramp duration to 48 hours (from 24 hours)
        // 48 hours = 172,800,000 milliseconds
        assert!(ramp_duration_ms >= 172_800_000, EInvalidAmp);
        
        let current_time = clock::timestamp_ms(clock);
        
        // Update current amp to interpolated value if already ramping
        pool.amp = current_amp;
        
        // Set new ramp parameters
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

    /// Get the minimum fee in basis points required for pool creation (Requirement 10.3, 10.4)
    /// Returns 1 basis point (0.01%) as the minimum fee to ensure meaningful LP returns
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
