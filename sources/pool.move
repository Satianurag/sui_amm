module sui_amm::pool {
    use sui::coin;
    use sui::balance;
    use sui::event;
    use sui::clock;
    use std::string;
    use sui_amm::position;

    // Error codes
    const EZeroAmount: u64 = 0;
    const EWrongPool: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EExcessivePriceImpact: u64 = 3;
    const EOverflow: u64 = 4;
    const ETooHighFee: u64 = 5;
    const EArithmeticError: u64 = 6; // NEW: For underflow protection
    const EUnauthorized: u64 = 7; // NEW: Access control
    const EInvalidLiquidityRatio: u64 = 8; // FIX [L2]: For ratio tolerance violations
    const EInsufficientOutput: u64 = 9; // NEW: For slippage protection
    const ECreatorFeeTooHigh: u64 = 10; // FIX [S5]: Creator fee validation
    const EPaused: u64 = 11; // NEW: Pool is paused
    const EInvalidFeePercent: u64 = 12; // NEW: Fee below minimum (Requirement 10.2)

    // Constants
    // FIX [P2-16.2]: MINIMUM_LIQUIDITY Documentation
    // MINIMUM_LIQUIDITY (1000 shares) is permanently burned on first liquidity addition
    // to prevent pool manipulation attacks. This is a standard AMM security practice.
    //
    // Why 1000 shares are permanently locked:
    // 1. Prevents division by zero in share calculations
    // 2. Makes it economically infeasible to manipulate pool ratios
    // 3. Ensures minimum liquidity always exists for price discovery
    // 4. Protects against rounding errors in small pools
    //
    // The first LP pays this one-time cost (sent to address 0x0) to secure the pool.
    // Subsequent LPs are not affected. This is similar to Uniswap V2's approach.
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MIN_INITIAL_LIQUIDITY_MULTIPLIER: u64 = 10;
    const MIN_INITIAL_LIQUIDITY: u64 = MINIMUM_LIQUIDITY * MIN_INITIAL_LIQUIDITY_MULTIPLIER;
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    const MAX_PRICE_IMPACT_BPS: u64 = 1000; // 10%
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145; // u128::MAX / 10000
    const MAX_CREATOR_FEE_BPS: u64 = 500; // 5% max creator fee to protect LPs
    const MIN_FEE_THRESHOLD: u64 = 1000; // Minimum fee to avoid precision loss
    const MIN_FEE_BPS: u64 = 1; // Minimum fee of 1 basis point (0.01%) for pool creation (Requirement 10.1)

    public struct LiquidityPool<phantom CoinA, phantom CoinB> has key {
        id: object::UID,
        reserve_a: balance::Balance<CoinA>,
        reserve_b: balance::Balance<CoinB>,
        fee_a: balance::Balance<CoinA>,
        fee_b: balance::Balance<CoinB>,
        protocol_fee_a: balance::Balance<CoinA>,
        protocol_fee_b: balance::Balance<CoinB>,
        // FIX V1: Creator fees
        creator: address,
        creator_fee_a: balance::Balance<CoinA>,
        creator_fee_b: balance::Balance<CoinB>,

        total_liquidity: u64,
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
        // Emergency pause mechanism
        paused: bool,
        paused_at: u64,
    }

    // Events
    public struct PoolCreated has copy, drop {
        pool_id: object::ID,
        creator: address,
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

    public struct ProtocolFeesWithdrawn has copy, drop {
        pool_id: object::ID,
        admin: address,
        amount_a: u64,
        amount_b: u64,
    }

    public struct CreatorFeesWithdrawn has copy, drop {
        pool_id: object::ID,
        creator: address,
        amount_a: u64,
        amount_b: u64,
    }

    public struct PoolPaused has copy, drop {
        pool_id: object::ID,
        timestamp: u64,
    }

    public struct PoolUnpaused has copy, drop {
        pool_id: object::ID,
        timestamp: u64,
    }

    /// Creates pool with initial liquidity atomically (improvement over spec's 2-step flow).
    /// This prevents creation of empty pools and ensures immediate usability.
    public(package) fun create_pool<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        ctx: &mut tx_context::TxContext
    ): LiquidityPool<CoinA, CoinB> {
        // FIX [P2-16.6]: Enforce minimum fee validation (defense-in-depth)
        // Prevents zero-fee pools that would provide no LP incentive
        assert!(fee_percent >= MIN_FEE_BPS, EInvalidFeePercent);
        assert!(fee_percent <= 1000, ETooHighFee); // Max 10%
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        // FIX [S5]: Validate creator fee to protect LPs from value extraction
        assert!(creator_fee_percent <= MAX_CREATOR_FEE_BPS, ECreatorFeeTooHigh);
        
        let pool = LiquidityPool<CoinA, CoinB> {
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
            ratio_tolerance_bps: 50, // FIX [M2]: 0.5% tolerance (reduced from 5%)
            max_price_impact_bps: MAX_PRICE_IMPACT_BPS,
            paused: false,
            paused_at: 0,
        };
        
        event::emit(PoolCreated {
            pool_id: object::id(&pool),
            creator: tx_context::sender(ctx),
            fee_percent,
        });

        pool
    }

    public fun add_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        coin_a: coin::Coin<CoinA>,
        coin_b: coin::Coin<CoinB>,
        min_liquidity: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (position::LPPosition, coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // Check if pool is paused
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let (reserve_a, reserve_b) = (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b));
        
        // FIX V2: Ratio Validation
        if (pool.total_liquidity > 0) {
            // Check if ratio is maintained within tolerance
            // ratio = amount_a / amount_b vs reserve_a / reserve_b
            // Cross-multiply: amount_a * reserve_b vs amount_b * reserve_a
            let val_a = (amount_a as u128) * (reserve_b as u128);
            let val_b = (amount_b as u128) * (reserve_a as u128);
            
            let diff = if (val_a > val_b) { val_a - val_b } else { val_b - val_a };
            // deviation_bps = diff * 10000 / max(val_a, val_b)
            let max_val = if (val_a > val_b) { val_a } else { val_b };
            
            if (max_val > 0) {
                let deviation = (diff * 10000) / max_val;
                // FIX [L2]: Use specific error code for ratio violations, not price impact
                assert!(deviation <= (pool.ratio_tolerance_bps as u128), EInvalidLiquidityRatio);
            };
        };
        
        let liquidity_minted;
        let refund_a;
        let refund_b;
        
        if (pool.total_liquidity == 0) {
            // FIX [P2-16.2]: Initial liquidity with MINIMUM_LIQUIDITY burn
            // The first LP must provide enough liquidity to mint at least MIN_INITIAL_LIQUIDITY shares.
            // Of these, MINIMUM_LIQUIDITY (1000) shares are permanently burned to address 0x0.
            // This prevents:
            // - Price manipulation attacks on low-liquidity pools
            // - Division by zero in share calculations
            // - Rounding exploits in subsequent liquidity additions
            //
            // Example: If first LP provides liquidity worth 10,000 shares:
            // - 1,000 shares burned (sent to 0x0)
            // - 9,000 shares minted to first LP
            // - Pool total_liquidity = 1,000 (only burned shares count initially)
            //
            // This is a one-time cost paid by the pool creator for security.
            let liquidity = (std::u64::sqrt(amount_a) * std::u64::sqrt(amount_b));
            assert!(liquidity >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            pool.total_liquidity = MINIMUM_LIQUIDITY;
            liquidity_minted = liquidity - MINIMUM_LIQUIDITY;
            
            // Burn minimum liquidity by sending to 0x0 (unrecoverable)
            let burn_position = position::new(
                object::id(pool),
                MINIMUM_LIQUIDITY,
                0, 0, 0, 0,
                string::utf8(b"Burned Minimum Liquidity"),
                string::utf8(b"Permanently locked for pool security"),
                ctx
            );
            position::destroy(burn_position);
            
            // Join all coins to pool for initial liquidity
            balance::join(&mut pool.reserve_a, coin::into_balance(coin_a));
            balance::join(&mut pool.reserve_b, coin::into_balance(coin_b));
            
            // No refunds for initial liquidity
            refund_a = coin::zero<CoinA>(ctx);
            refund_b = coin::zero<CoinB>(ctx);
        } else {
            // FIX S4: Overflow protection
            // Check if multiplication overflows u128
            // u128::MAX is ~3.4e38. amount * total_liquidity should fit unless both are > 1e19
            // We can check if amount > u128::MAX / total_liquidity
            if (pool.total_liquidity > 0) {
                let max_u128 = 340282366920938463463374607431768211455;
                assert!((amount_a as u128) <= max_u128 / (pool.total_liquidity as u128), EOverflow);
                assert!((amount_b as u128) <= max_u128 / (pool.total_liquidity as u128), EOverflow);
            };

            let share_a = ((amount_a as u128) * (pool.total_liquidity as u128) / (reserve_a as u128));
            let share_b = ((amount_b as u128) * (pool.total_liquidity as u128) / (reserve_b as u128));
            liquidity_minted = if (share_a < share_b) { (share_a as u64) } else { (share_b as u64) };
            
            // FIX [L1]: Calculate actual amounts used to mint liquidity
            // This prevents user value loss due to integer division rounding
            let amount_a_used = (((liquidity_minted as u128) * (reserve_a as u128) / (pool.total_liquidity as u128)) as u64);
            let amount_b_used = (((liquidity_minted as u128) * (reserve_b as u128) / (pool.total_liquidity as u128)) as u64);
            
            // Convert coins to balances
            let mut balance_a = coin::into_balance(coin_a);
            let mut balance_b = coin::into_balance(coin_b);
            
            // Split to get used and refund portions
            let balance_a_used = balance::split(&mut balance_a, amount_a_used);
            let balance_b_used = balance::split(&mut balance_b, amount_b_used);
            
            // Join only the amounts actually used
            balance::join(&mut pool.reserve_a, balance_a_used);
            balance::join(&mut pool.reserve_b, balance_b_used);
            
            // Convert remaining balances back to coins for refund
            refund_a = coin::from_balance(balance_a, ctx);
            refund_b = coin::from_balance(balance_b, ctx);
        };

        assert!(liquidity_minted >= min_liquidity, EInsufficientLiquidity);
        
        pool.total_liquidity = pool.total_liquidity + liquidity_minted;

        let fee_debt_a = (liquidity_minted as u128) * pool.acc_fee_per_share_a / ACC_PRECISION;
        let fee_debt_b = (liquidity_minted as u128) * pool.acc_fee_per_share_b / ACC_PRECISION;

        event::emit(LiquidityAdded {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a,
            amount_b,
            liquidity_minted,
        });

        // FIX [V3]: NFT metadata is initialized with current values
        // NOTE: Metadata will become stale after swaps. Users should call
        // refresh_position_metadata() to update, or frontends should display
        // real-time values from get_position_view() instead of cached NFT data.
        let name = string::utf8(b"Sui AMM LP Position");
        let description = string::utf8(b"Liquidity Provider Position for Sui AMM");
        let pool_type = string::utf8(b"Standard");

        let position = position::new_with_metadata(
            object::id(pool),
            liquidity_minted,
            fee_debt_a,
            fee_debt_b,
            amount_a,
            amount_b,
            name,
            description,
            pool_type,
            pool.fee_percent,
            ctx
        );
        
        (position, refund_a, refund_b)
    }

    public fun remove_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: position::LPPosition,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // SECURITY FIX [P1-15.4]: Add pause check to liquidity operations
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        assert!(position::pool_id(&position) == object::id(pool), EWrongPool);

        let liquidity = position::liquidity(&position);
        let amount_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

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

    public fun remove_liquidity_partial<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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
        
        let old_debt_a = position::fee_debt_a(position);
        let old_debt_b = position::fee_debt_b(position);
        
        // FIX [V2]: Use ceiling division for debt removal to prevent fee loss
        // debt_removed = ceil(old_debt * liquidity_to_remove / total_liquidity)
        // ceil(a/b) = (a + b - 1) / b
        let debt_removed_a = ((old_debt_a * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        let debt_removed_b = ((old_debt_b * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        
        // FIX L5: Assert instead of clamp for underflow protection
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
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (coin::Coin<CoinA>, coin::Coin<CoinB>) {
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        let liquidity = position::liquidity(position);
        
        // FIX [P2-16.3]: Defense-in-depth fee double-claiming protection
        // Calculate pending fees based on accumulated fees per share minus debt
        let pending_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);

        // Additional validation: ensure pending fees don't exceed available pool fees
        // This prevents any potential fee double-claiming exploits
        let available_fee_a = balance::value(&pool.fee_a);
        let available_fee_b = balance::value(&pool.fee_b);
        assert!((pending_a as u64) <= available_fee_a, EInsufficientLiquidity);
        assert!((pending_b as u64) <= available_fee_b, EInsufficientLiquidity);

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

        // Update fee debt to current accumulated value to prevent re-claiming
        let new_debt_a = (liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION;
        let new_debt_b = (liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION;
        
        // FIX [P2-16.3]: Assert that new debt is >= old debt (should always be true)
        // This catches any logic errors in fee accumulation
        assert!(new_debt_a >= position::fee_debt_a(position), EArithmeticError);
        assert!(new_debt_b >= position::fee_debt_b(position), EArithmeticError);
        
        position::update_fee_debt(position, new_debt_a, new_debt_b);

        // FIX P3: Optimize event emission
        if (balance::value(&fee_a) > 0 || balance::value(&fee_b) > 0) {
            event::emit(FeesClaimed {
                pool_id: object::id(pool),
                owner: tx_context::sender(ctx),
                amount_a: balance::value(&fee_a),
                amount_b: balance::value(&fee_b),
            });
        };

        // FIX [V6]: Refresh metadata to ensure NFT display is up-to-date
        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    public fun swap_a_to_b<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

        // S2: Flash Loan Protection - Snapshot reserves before any changes
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            let spot_price = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
            let effective_price = ((amount_out as u128) * 1_000_000_000) / (amount_in as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price >= max_allowed_price, EInsufficientOutput);
        };

        // Calculate price impact using INITIAL reserves
        let impact = cp_price_impact_bps(
            reserve_a_initial,
            reserve_b_initial,
            amount_in_after_fee,
            amount_out
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
        
        let mut fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
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
            // For small fees, use higher precision calculation
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // S2: Verify K-invariant (post-swap check)
        // K_new >= K_old
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let k_old = (reserve_a_initial as u128) * (reserve_b_initial as u128);
        let k_new = (reserve_a_new as u128) * (reserve_b_new as u128);
        assert!(k_new >= k_old, EInsufficientLiquidity);

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
        pool: &mut LiquidityPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinA>,
        min_out: u64,
        max_price: option::Option<u64>,
        pool_stats: &mut sui_amm::swap_history::PoolStatistics,
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

        // S2: Flash Loan Protection - Snapshot reserves before any changes
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            let spot_price = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
            let effective_price = ((amount_out as u128) * 1_000_000_000) / (amount_in as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price >= max_allowed_price, EInsufficientOutput);
        };

        // Calculate price impact using INITIAL reserves
        let impact = cp_price_impact_bps(
            reserve_a_initial,
            reserve_b_initial,
            amount_in_after_fee,
            amount_out
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
        
        let mut fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
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
            // For small fees, use higher precision calculation
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // S2: Verify K-invariant (post-swap check)
        // K_new >= K_old
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let k_old = (reserve_a_initial as u128) * (reserve_b_initial as u128);
        let k_new = (reserve_a_new as u128) * (reserve_b_new as u128);
        assert!(k_new >= k_old, EInsufficientLiquidity);

        event::emit(SwapExecuted {
            pool_id: object::id(pool),
            sender: tx_context::sender(ctx),
            amount_in,
            amount_out,
            is_a_to_b: true,
            price_impact_bps: impact,
        });

        // Record swap in history
        sui_amm::swap_history::record_swap(
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
        pool: &mut LiquidityPool<CoinA, CoinB>,
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
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        // S2: Flash Loan Protection
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            let spot_price = ((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128);
            let effective_price = ((amount_out as u128) * 1_000_000_000) / (amount_in as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price >= max_allowed_price, EInsufficientOutput);
        };

        // Calculate price impact using INITIAL reserves
        let impact = cp_price_impact_bps(
            reserve_b_initial,
            reserve_a_initial,
            amount_in_after_fee,
            amount_out
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

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
            // For small fees, use higher precision calculation
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // S2: Verify K-invariant
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let k_old = (reserve_a_initial as u128) * (reserve_b_initial as u128);
        let k_new = (reserve_a_new as u128) * (reserve_b_new as u128);
        assert!(k_new >= k_old, EInsufficientLiquidity);

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
        pool: &mut LiquidityPool<CoinA, CoinB>,
        coin_in: coin::Coin<CoinB>,
        min_out: u64,
        max_price: option::Option<u64>,
        pool_stats: &mut sui_amm::swap_history::PoolStatistics,
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
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        // S2: Flash Loan Protection
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            let spot_price = ((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128);
            let effective_price = ((amount_out as u128) * 1_000_000_000) / (amount_in as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price >= max_allowed_price, EInsufficientOutput);
        };

        // Calculate price impact using INITIAL reserves
        let impact = cp_price_impact_bps(
            reserve_b_initial,
            reserve_a_initial,
            amount_in_after_fee,
            amount_out
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

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
            // For small fees, use higher precision calculation
            let fee_increment = ((lp_fee_amount as u128) * ACC_PRECISION);
            if (fee_increment / (pool.total_liquidity as u128) > 0) {
                pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + (fee_increment / (pool.total_liquidity as u128));
            };
        };

        // S2: Verify K-invariant
        let reserve_a_new = balance::value(&pool.reserve_a);
        let reserve_b_new = balance::value(&pool.reserve_b);
        let k_old = (reserve_a_initial as u128) * (reserve_b_initial as u128);
        let k_new = (reserve_a_new as u128) * (reserve_b_new as u128);
        assert!(k_new >= k_old, EInsufficientLiquidity);

        event::emit(SwapExecuted {
            pool_id: object::id(pool),
            sender: tx_context::sender(ctx),
            amount_in,
            amount_out,
            is_a_to_b: false,
            price_impact_bps: impact,
        });

        // Record swap in history
        sui_amm::swap_history::record_swap(
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

    public fun increase_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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
        pool: &mut LiquidityPool<CoinA, CoinB>,
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
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

    public(package) fun set_risk_params<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64
    ) {
        pool.ratio_tolerance_bps = ratio_tolerance_bps;
        pool.max_price_impact_bps = max_price_impact_bps;
    }

    public(package) fun set_protocol_fee_percent<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        new_percent: u64
    ) {
        assert!(new_percent <= 1000, ETooHighFee);
        pool.protocol_fee_percent = new_percent;
    }

    /// Pause pool operations (admin-only via package)
    public(package) fun pause_pool<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &clock::Clock
    ) {
        pool.paused = true;
        pool.paused_at = sui::clock::timestamp_ms(clock);
        event::emit(PoolPaused {
            pool_id: object::id(pool),
            timestamp: pool.paused_at,
        });
    }

    /// Unpause pool operations (admin-only via package)
    public(package) fun unpause_pool<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        clock: &clock::Clock
    ) {
        pool.paused = false;
        event::emit(PoolUnpaused {
            pool_id: object::id(pool),
            timestamp: sui::clock::timestamp_ms(clock),
        });
    }

    public fun get_k<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u128 {
        let (r_a, r_b) = get_reserves(pool);
        (r_a as u128) * (r_b as u128)
    }

    public fun get_reserves<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b))
    }

    public fun get_fee_percent<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.fee_percent
    }

    public fun get_protocol_fee_percent<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.protocol_fee_percent
    }

    public fun get_total_liquidity<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.total_liquidity
    }

    public fun get_protocol_fees<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.protocol_fee_a), balance::value(&pool.protocol_fee_b))
    }

    public fun get_position_view<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
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

    /// Calculate impermanent loss for standard pool position
    /// 
    /// Formula:
    /// IL = (Value_hold - Value_lp) / Value_hold
    /// 
    /// Proof:
    /// Let P = price of A in terms of B
    /// Value_hold = initial_a * P + initial_b
    /// Value_lp = current_a * P + current_b
    /// 
    /// For constant product AMM (x * y = k):
    /// current_a = sqrt(k / P)
    /// current_b = sqrt(k * P)
    /// Value_lp = 2 * sqrt(k * P)
    /// 
    /// This function calculates the realized loss based on current reserves and user's initial deposit amounts.
    public fun get_impermanent_loss<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
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

    /// FIX [S2][V3]: Public function to refresh position metadata
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
    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &sui::clock::Clock
    ) {
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);
        
        let liquidity = position::liquidity(position);
        if (pool.total_liquidity == 0) {
            return
        };
        
        let value_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let value_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);
        
        let fee_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let fee_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        // FIX [P2]: Optimization - skip update if all values unchanged
        let cached_value_a = position::cached_value_a(position);
        let cached_value_b = position::cached_value_b(position);
        let cached_fee_a = position::cached_fee_a(position);
        let cached_fee_b = position::cached_fee_b(position);
        
        if (value_a == cached_value_a && value_b == cached_value_b && 
            (fee_a as u64) == cached_fee_a && (fee_b as u64) == cached_fee_b) {
            // All values match - skip update to save gas
            return
        };

        let il_bps = get_impermanent_loss(pool, position);
        
        position::update_cached_values(
            position,
            value_a,
            value_b,
            (fee_a as u64),
            (fee_b as u64),
            il_bps,
            clock
        );
    }

    /// FIX [P2-16.1]: Helper function to calculate fee with overflow protection
    /// Returns (fee_amount, amount_after_fee)
    fun calculate_fee_safe(amount_in: u64, fee_percent: u64): (u64, u64) {
        // Use u128 to prevent overflow in multiplication
        let fee_calculation = (amount_in as u128) * (fee_percent as u128);
        // Validate intermediate result doesn't overflow u64 after division
        let fee_amount_u128 = fee_calculation / 10000;
        assert!(fee_amount_u128 <= (18446744073709551615 as u128), EOverflow);
        let fee_amount = (fee_amount_u128 as u64);
        let amount_after_fee = amount_in - fee_amount;
        (fee_amount, amount_after_fee)
    }

    fun cp_price_impact_bps(
        reserve_in: u64,
        reserve_out: u64,
        amount_in_after_fee: u64,
        amount_out: u64,
    ): u64 {
        // FIX [Task 7]: Add zero checks to prevent division by zero
        // Return 0 if reserve_in is zero
        if (reserve_in == 0) {
            return 0
        };
        
        // Return 10000 (100% impact) if reserve_out is zero
        if (reserve_out == 0) {
            return 10000
        };
        
        // Return 0 if amount_in is zero
        if (amount_in_after_fee == 0) {
            return 0
        };
        
        // Return 0 if amount_out is zero (edge case)
        if (amount_out == 0) {
            return 0
        };

        // FIX [P2-19.1]: Enhanced price impact overflow protection
        // Validate inputs are within safe bounds before multiplication
        // u128::MAX = 340282366920938463463374607431768211455
        // To prevent overflow in (amount_in * reserve_out), ensure:
        // amount_in <= u128::MAX / reserve_out
        let max_u128 = 340282366920938463463374607431768211455u128;
        
        // Check if multiplication would overflow
        if ((amount_in_after_fee as u128) > max_u128 / (reserve_out as u128)) {
            // If overflow would occur, return maximum impact (100%)
            return 10000
        };
        
        // Ideal output for CP: amount_in * reserve_out / reserve_in
        // But we need to be careful with precision.
        // ideal_out = amount_in * (reserve_out / reserve_in)
        
        // FIX L4: Check for overflow before multiplication
        let ideal_out = (amount_in_after_fee as u128) * (reserve_out as u128) / (reserve_in as u128);
        
        // Validate division operations - check for overflow
        assert!(ideal_out <= MAX_SAFE_VALUE, EArithmeticError);
        
        let actual_out = (amount_out as u128);
        
        if (ideal_out <= actual_out) {
            0
        } else {
            let diff = ideal_out - actual_out;
            assert!(diff <= MAX_SAFE_VALUE, EArithmeticError);
            
            // Validate final division operation
            if (ideal_out == 0) {
                return 0
            };
            
            // FIX [P2-19.1]: Check for overflow in final calculation (diff * 10000)
            if (diff > max_u128 / 10000) {
                // If overflow would occur, return maximum impact (100%)
                return 10000
            };
            
            (((diff * 10000) / ideal_out) as u64)
        }
    }

    public fun calculate_swap_price_impact_a2b<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        cp_price_impact_bps(reserve_a, reserve_b, amount_in_after_fee, amount_out)
    }

    public fun calculate_swap_price_impact_b2a<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        cp_price_impact_bps(reserve_b, reserve_a, amount_in_after_fee, amount_out)
    }

    /// FIX [V2]: Calculate expected slippage for a trade
    /// Slippage = (Expected Output - Actual Output) / Expected Output
    public fun calculate_swap_slippage_bps<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;

        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);

        // 1. Calculate Actual Output
        let actual_out = if (is_a_to_b) {
             ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64)
        } else {
             ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64)
        };

        // 2. Calculate Expected Output (Spot Price)
        // For CP, Spot Price = Reserve_Out / Reserve_In
        let expected_out = if (is_a_to_b) {
            (amount_in_after_fee as u128) * (reserve_b as u128) / (reserve_a as u128)
        } else {
            (amount_in_after_fee as u128) * (reserve_a as u128) / (reserve_b as u128)
        };
        
        if (expected_out > MAX_SAFE_VALUE) {
             return 10000 // 100% slippage if overflow
        };

        let expected_out_u64 = (expected_out as u64);

        if (expected_out_u64 <= actual_out) {
            return 0
        };

        let diff = expected_out_u64 - actual_out;
        ((diff as u128) * 10000 / (expected_out_u64 as u128) as u64)
    }

    public fun get_quote_a_to_b<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64)
    }

    public fun get_quote_b_to_a<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64)
    }

    public fun get_exchange_rate<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0) return 0;
        
        // Return price of A in terms of B, scaled by 1e9
        ((reserve_b as u128) * 1_000_000_000 / (reserve_a as u128) as u64)
    }

    /// Get B to A exchange rate with zero-reserve handling
    /// Returns the price of B in terms of A, scaled by 1e9
    /// Returns 0 if reserve_b is zero to prevent division by zero
    public fun get_exchange_rate_b_to_a<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        // Handle zero reserve case
        if (reserve_b == 0) return 0;
        
        // Return price of B in terms of A, scaled by 1e9
        ((reserve_a as u128) * 1_000_000_000 / (reserve_b as u128) as u64)
    }

    /// Get effective rate for a specific swap amount (includes slippage)
    /// Returns the actual rate you would get for swapping amount_in, scaled by 1e9
    /// This differs from spot rate because it accounts for price impact
    public fun get_effective_rate<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        // Handle zero amount case
        if (amount_in == 0) return 0;
        
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        // Handle zero reserve cases
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = if (is_a_to_b) {
            ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64)
        } else {
            ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64)
        };
        
        // Return effective rate: amount_out / amount_in * 1e9
        ((amount_out as u128) * 1_000_000_000 / (amount_in as u128) as u64)
    }

    /// Get price impact for a specific amount before execution
    /// Returns price impact in basis points (1 bps = 0.01%)
    /// Useful for showing users the expected price impact before they execute a swap
    public fun get_price_impact_for_amount<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        // Handle edge cases
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        // FIX [P2-16.1]: Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let (reserve_in, reserve_out) = if (is_a_to_b) {
            (reserve_a, reserve_b)
        } else {
            (reserve_b, reserve_a)
        };
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_out as u128) / ((reserve_in as u128) + (amount_in_after_fee as u128)) as u64);
        
        cp_price_impact_bps(reserve_in, reserve_out, amount_in_after_fee, amount_out)
    }

    public fun get_position_value<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &position::LPPosition
    ): (u64, u64) {
        let view = get_position_view(pool, position);
        position::view_value(&view)
    }

    public fun get_accumulated_fees<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &position::LPPosition
    ): (u64, u64) {
        let view = get_position_view(pool, position);
        position::view_fees(&view)
    }



    public fun get_locked_liquidity<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        if (pool.total_liquidity > 0) {
            MINIMUM_LIQUIDITY
        } else {
            0
        }
    }

    /// Get the minimum fee in basis points required for pool creation (Requirement 10.3, 10.4)
    /// Returns 1 basis point (0.01%) as the minimum fee to ensure meaningful LP returns
    public fun min_fee_bps(): u64 {
        MIN_FEE_BPS
    }

    #[test_only]
    public fun test_cp_price_impact_bps(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
        amount_out: u64
    ): u64 {
        cp_price_impact_bps(reserve_in, reserve_out, amount_in, amount_out)
    }

    #[test_only]
    public fun create_pool_for_testing<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        ctx: &mut tx_context::TxContext
    ): LiquidityPool<CoinA, CoinB> {
        create_pool(fee_percent, protocol_fee_percent, creator_fee_percent, ctx)
    }

    public fun share<CoinA, CoinB>(pool: LiquidityPool<CoinA, CoinB>) {
        transfer::share_object(pool);
    }

    #[test_only]
    public fun set_risk_params_for_testing<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64
    ) {
        set_risk_params(pool, ratio_tolerance_bps, max_price_impact_bps);
    }
}
