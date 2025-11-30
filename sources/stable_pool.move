module sui_amm::stable_pool {
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self as clock, Clock};
    use std::option::{Self, Option};
    
    use sui_amm::stable_math;
    use sui_amm::position::{Self, LPPosition};
    
    friend sui_amm::fee_distributor;
    friend sui_amm::admin;
    friend sui_amm::governance;

    // Error codes
    const EZeroAmount: u64 = 0;
    const EWrongPool: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EExcessivePriceImpact: u64 = 3;
    const EInvalidAmp: u64 = 4;
    const ETooHighFee: u64 = 5;  // NEW: For protocol fee validation
    const EOverflow: u64 = 6;  // NEW: For overflow protection
    
    // Constants
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    const MAX_PRICE_IMPACT_BPS: u64 = 1000; // 10%
    const MIN_AMP: u64 = 1;
    const MAX_AMP: u64 = 10000;
    const MIN_RAMP_DURATION: u64 = 86_400_000; // 24 hours in milliseconds
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145; // u128::MAX / 10000 - for price impact overflow check

    struct StableSwapPool<phantom CoinA, phantom CoinB> has key {
        id: UID,
        reserve_a: Balance<CoinA>,
        reserve_b: Balance<CoinB>,
        fee_a: Balance<CoinA>,
        fee_b: Balance<CoinB>,
        protocol_fee_a: Balance<CoinA>,
        protocol_fee_b: Balance<CoinB>,
        total_liquidity: u64,
        fee_percent: u64,
        protocol_fee_percent: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
        amp: u64, // Current amplification coefficient
        // FIX [L1]: Amp ramping support for dynamic optimization
        target_amp: u64,           // Target amp when ramping
        amp_ramp_start_time: u64,  // Start time of ramp (0 if not ramping)
        amp_ramp_end_time: u64,    // End time of ram (0 if not ramping)
        max_price_impact_bps: u64,
    }

    // Events
    struct PoolCreated has copy, drop {
        pool_id: ID,
        creator: address,
        amp: u64,
        fee_percent: u64,
    }

    struct LiquidityAdded has copy, drop {
        pool_id: ID,
        provider: address,
        amount_a: u64,
        amount_b: u64,
        liquidity_minted: u64,
    }

    struct LiquidityRemoved has copy, drop {
        pool_id: ID,
        provider: address,
        amount_a: u64,
        amount_b: u64,
        liquidity_burned: u64,
    }

    struct SwapExecuted has copy, drop {
        pool_id: ID,
        sender: address,
        amount_in: u64,
        amount_out: u64,
        is_a_to_b: bool,
        price_impact_bps: u64,
    }

    struct FeesClaimed has copy, drop {
        pool_id: ID,
        owner: address,
        amount_a: u64,
        amount_b: u64,
    }

    struct ProtocolFeesWithdrawn has copy, drop {
        pool_id: ID,
        admin: address,
        amount_a: u64,
        amount_b: u64,
    }

    public fun create_pool<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        amp: u64,
        ctx: &mut TxContext
    ): StableSwapPool<CoinA, CoinB> {
        assert!(amp >= MIN_AMP && amp <= MAX_AMP, EInvalidAmp);
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        let pool = StableSwapPool<CoinA, CoinB> {
            id: object::new(ctx),
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            fee_a: balance::zero(),
            fee_b: balance::zero(),
            protocol_fee_a: balance::zero(),
            protocol_fee_b: balance::zero(),
            total_liquidity: 0,
            fee_percent,
            protocol_fee_percent,
            acc_fee_per_share_a: 0,
            acc_fee_per_share_b: 0,
            amp,
            target_amp: amp,        // Initially no ramp
            amp_ramp_start_time: 0, // 0 means not ramping
            amp_ramp_end_time: 0,   // 0 means not ramping
            max_price_impact_bps: MAX_PRICE_IMPACT_BPS,
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
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        min_liquidity: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (LPPosition, Coin<CoinA>, Coin<CoinB>) {
        // FIX V2: Deadline enforcement
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 || amount_b > 0, EZeroAmount); // Allow single-sided

        let (reserve_a, reserve_b) = (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b));
        
        let liquidity_minted;
        if (pool.total_liquidity == 0) {
            let d = stable_math::get_d(amount_a, amount_b, pool.amp);
            assert!(d >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            pool.total_liquidity = MINIMUM_LIQUIDITY;
            liquidity_minted = d - MINIMUM_LIQUIDITY;
            
            // Create a position for the burned liquidity and transfer to dead address
            // This is equivalent to Uniswap V2's burn to address(0)
            let burn_position = position::new(
                object::id(pool),
                MINIMUM_LIQUIDITY,
                0, // No fee debt for burned position
                0,
                0, // No min amounts since it's burned
                0,
                std::string::utf8(b"Burned Minimum Liquidity"),
                std::string::utf8(b"Permanently locked to prevent division by zero"),
                ctx
            );
            
            // Transfer to @0x0 (dead address) - equivalent to burning
            transfer::public_transfer(burn_position, @0x0);
        } else {
            let d0 = stable_math::get_d(reserve_a, reserve_b, pool.amp);
            let d1 = stable_math::get_d(reserve_a + amount_a, reserve_b + amount_b, pool.amp);
            
            assert!(d1 > d0, EInsufficientLiquidity);
            
            // mint = total_supply * (d1 - d0) / d0
            liquidity_minted = ((pool.total_liquidity as u128) * ((d1 - d0) as u128) / (d0 as u128) as u64);
        };

        assert!(liquidity_minted >= min_liquidity, EInsufficientLiquidity);

        balance::join(&mut pool.reserve_a, coin::into_balance(coin_a));
        balance::join(&mut pool.reserve_b, coin::into_balance(coin_b));
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

        let name = std::string::utf8(b"Sui AMM StableSwap LP Position");
        let description = std::string::utf8(b"Liquidity Provider Position for Sui AMM StableSwap");
        let pool_type = std::string::utf8(b"Stable");

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
        
        // Return empty coins to match interface
        (position, coin::zero(ctx), coin::zero(ctx))
    }

    public fun remove_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: LPPosition,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
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
        
        let split_a = balance::split(&mut pool.reserve_a, amount_a);
        let split_b = balance::split(&mut pool.reserve_b, amount_b);

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
        position: &mut LPPosition,
        liquidity_to_remove: u64,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
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
        
        let split_a = balance::split(&mut pool.reserve_a, amount_a);
        let split_b = balance::split(&mut pool.reserve_b, amount_b);

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
        
        // Calculate how much debt corresponds to the removed liquidity
        // debt_removed = old_debt * (removed_liquidity / total_liquidity)
        let debt_removed_a = (old_debt_a * (liquidity_to_remove as u128)) / (total_position_liquidity as u128);
        let debt_removed_b = (old_debt_b * (liquidity_to_remove as u128)) / (total_position_liquidity as u128);
        
        // FIX L5: Underflow protection - clamp to zero if rounding causes issues
        let new_debt_a = if (debt_removed_a > old_debt_a) { 
            0  // Clamp to zero if rounding causes issues
        } else { 
            old_debt_a - debt_removed_a 
        };
        
        let new_debt_b = if (debt_removed_b > old_debt_b) { 
            0 
        } else { 
            old_debt_b - debt_removed_b 
        };
        
        position::update_fee_debt(position, new_debt_a, new_debt_b);

        event::emit(LiquidityRemoved {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a,
            amount_b,
            liquidity_burned: liquidity_to_remove,
        });

        (coin::from_balance(split_a, ctx), coin::from_balance(split_b, ctx))
    }

    public(friend) fun withdraw_fees<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
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

        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    public fun swap_a_to_b<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: Coin<CoinA>,
        min_out: u64,
        max_price: Option<u64>,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): Coin<CoinB> {
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

        // Check price limit if provided
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
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
        
        let fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
        // Split fee between Protocol and LPs
        let protocol_fee_amount = (fee_amount * pool.protocol_fee_percent) / 10000;
        let lp_fee_amount = fee_amount - protocol_fee_amount;

        if (protocol_fee_amount > 0) {
            let proto_fee = balance::split(&mut fee_balance, protocol_fee_amount);
            balance::join(&mut pool.protocol_fee_a, proto_fee);
        };
        
        balance::join(&mut pool.fee_a, fee_balance);

        let output_coin = coin::take(&mut pool.reserve_b, amount_out, ctx);

        if (pool.total_liquidity > 0) {
            pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
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

    public fun swap_b_to_a<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        coin_in: Coin<CoinB>,
        min_out: u64,
        max_price: Option<u64>,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): Coin<CoinA> {
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

        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        };

        balance::join(&mut pool.reserve_b, coin::into_balance(coin_in));
        
        let fee_balance = balance::split(&mut pool.reserve_b, fee_amount);
        
        let protocol_fee_amount = (fee_amount * pool.protocol_fee_percent) / 10000;
        let lp_fee_amount = fee_amount - protocol_fee_amount;

        if (protocol_fee_amount > 0) {
            let proto_fee = balance::split(&mut fee_balance, protocol_fee_amount);
            balance::join(&mut pool.protocol_fee_b, proto_fee);
        };

        balance::join(&mut pool.fee_b, fee_balance);

        let output_coin = coin::take(&mut pool.reserve_a, amount_out, ctx);

        if (pool.total_liquidity > 0) {
            pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
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
        position: &LPPosition,
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

        position::make_position_view(
            value_a,
            value_b,
            (pending_fee_a as u64),
            (pending_fee_b as u64),
            0, // Stable pools track IL off-chain; assume 0 for display
        )
    }

    public fun increase_liquidity<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        // FIX V2: Deadline enforcement
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let share_a = ((amount_a as u128) * (pool.total_liquidity as u128)) / (balance::value(&pool.reserve_a) as u128);
        let share_b = ((amount_b as u128) * (pool.total_liquidity as u128)) / (balance::value(&pool.reserve_b) as u128);
        let liquidity_added = if (share_a < share_b) { (share_a as u64) } else { (share_b as u64) };

        let amount_a_optimal = (((liquidity_added as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b_optimal = (((liquidity_added as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        let balance_a = coin::into_balance(coin_a);
        let balance_b = coin::into_balance(coin_b);
        
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

        (coin::from_balance(balance_a, ctx), coin::from_balance(balance_b, ctx))
    }

    public(friend) fun withdraw_protocol_fees<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
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

    public(friend) fun set_max_price_impact_bps<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        max_price_impact_bps: u64
    ) {
        pool.max_price_impact_bps = max_price_impact_bps;
    }

    /// FIX [M2]: Allow protocol fee adjustment after pool creation
    public(friend) fun set_protocol_fee_percent<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        new_percent: u64
    ) {
        assert!(new_percent <= 1000, ETooHighFee); // Align with constant-product pools (<=10%)
        pool.protocol_fee_percent = new_percent;
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

    /// FIX [S2]: Public function to refresh position metadata from stable pool state
    /// Allows users to update their NFT display with current values without claiming fees
    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        position: &mut LPPosition
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
        
        position::update_cached_values(position, value_a, value_b, (fee_a as u64), (fee_b as u64), 0); // IL is 0 for stable pools
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

    /// FIX [L1]: Get current amplification coefficient (with ramping support)
    /// Returns interpolated value if ramping is active
    public fun get_current_amp<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        clock: &Clock
    ): u64 {
        // If not ramping, return current amp
        if (pool.amp_ramp_start_time == 0 || pool.amp_ramp_end_time == 0) {
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
    public(friend) fun ramp_amp<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        target_amp: u64,
        ramp_duration_ms: u64,
        clock: &Clock
    ) {
        assert!(target_amp >= MIN_AMP && target_amp <= MAX_AMP, EInvalidAmp);
        
        // FIX L3: Safety limits on amp changes
        let current_amp = get_current_amp(pool, clock);
        
        // Max 2x increase or 0.5x decrease per ramp
        if (target_amp > current_amp) {
            assert!(target_amp <= current_amp * 2, EInvalidAmp);
        } else {
            assert!(target_amp >= current_amp / 2, EInvalidAmp);
        };
        
        // Minimum ramp duration: 24 hours
        assert!(ramp_duration_ms >= MIN_RAMP_DURATION, EInvalidAmp);
        
        let current_time = clock::timestamp_ms(clock);
        
        // Update current amp to interpolated value if already ramping
        pool.amp = current_amp;
        
        // Set new ramp parameters
        pool.target_amp = target_amp;
        pool.amp_ramp_start_time = current_time;
        pool.amp_ramp_end_time = current_time + ramp_duration_ms;
    }

    /// FIX M4: Calculate price impact for a hypothetical A to B swap (view function)
    /// Returns price impact in basis points without executing the swap
    public fun calculate_swap_price_impact_a2b<CoinA, CoinB>(
        pool: &StableSwapPool<CoinA, CoinB>,
        amount_in: u64,
        clock: &Clock,
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
        clock: &Clock,
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

    /// Stop ongoing amp ramp and fix amp at current interpolated value
    public(friend) fun stop_ramp_amp<CoinA, CoinB>(
        pool: &mut StableSwapPool<CoinA, CoinB>,
        clock: &Clock
    ) {
        pool.amp = get_current_amp(pool, clock);
        pool.target_amp = pool.amp;
        pool.amp_ramp_start_time = 0;
        pool.amp_ramp_end_time = 0;
    }

    public fun share<CoinA, CoinB>(pool: StableSwapPool<CoinA, CoinB>) {
        transfer::share_object(pool);
    }
}
