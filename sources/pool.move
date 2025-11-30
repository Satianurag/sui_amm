module sui_amm::pool {
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Clock};
    use std::option::{Self, Option};
    
    use sui_amm::math;
    use sui_amm::position::{Self, LPPosition};
    
    friend sui_amm::fee_distributor;
    friend sui_amm::admin;
    friend sui_amm::governance;

    // Error codes - ALL DEFINED AT TOP
    const EZeroAmount: u64 = 0;
    const EWrongPool: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EInsufficientOutputAmount: u64 = 3;
    const EExcessivePriceImpact: u64 = 4;
    const ERatioToleranceExceeded: u64 = 5;
    const EKInvariantViolation: u64 = 6;
    const EReserveTooLow: u64 = 7;
    const ETooHighFee: u64 = 8;  // NEW: For protocol fee validation
    const EInvalidFeeSplit: u64 = 9;
    const EOverflow: u64 = 10;  // NEW: For overflow protection

    // Constants
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    const MAX_PRICE_IMPACT_BPS: u64 = 1000; // 10%
    const RATIO_TOLERANCE_BPS: u64 = 50; // 0.5%
    const MIN_RESERVE: u64 = 1000;
    const MAX_U64: u128 = 18_446_744_073_709_551_615; // For overflow checking
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145; // u128::MAX / 10000 - for price impact overflow check
    struct LiquidityPool<phantom CoinA, phantom CoinB> has key {
        id: UID,
        reserve_a: Balance<CoinA>,
        reserve_b: Balance<CoinB>,
        fee_a: Balance<CoinA>,
        fee_b: Balance<CoinB>,
        protocol_fee_a: Balance<CoinA>,
        protocol_fee_b: Balance<CoinB>,
        creator_fee_a: Balance<CoinA>,
        creator_fee_b: Balance<CoinB>,
        total_liquidity: u64,
        locked_liquidity: u64,
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        creator: address,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
    }

    struct PoolCreated has copy, drop {
        pool_id: ID,
        creator: address,
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
        creator_fee_percent: u64,
        ctx: &mut TxContext
    ): LiquidityPool<CoinA, CoinB> {
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        assert!(creator_fee_percent <= 10000, EInvalidFeeSplit);
        let total_fee_bps = protocol_fee_percent + creator_fee_percent;
        assert!(total_fee_bps <= 10000, EInvalidFeeSplit);

        let pool = LiquidityPool<CoinA, CoinB> {
            id: object::new(ctx),
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            fee_a: balance::zero(),
            fee_b: balance::zero(),
            protocol_fee_a: balance::zero(),
            protocol_fee_b: balance::zero(),
            creator_fee_a: balance::zero(),
            creator_fee_b: balance::zero(),
            total_liquidity: 0,
            locked_liquidity: 0,
            fee_percent,
            protocol_fee_percent,
            creator_fee_percent,
            creator: tx_context::sender(ctx),
            ratio_tolerance_bps: RATIO_TOLERANCE_BPS,
            max_price_impact_bps: MAX_PRICE_IMPACT_BPS,
            acc_fee_per_share_a: 0,
            acc_fee_per_share_b: 0,
        };
        
        let pool_id = object::id(&pool);

        event::emit(PoolCreated {
            pool_id,
            creator: tx_context::sender(ctx),
            fee_percent,
        });

        pool
    }

    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MIN_INITIAL_LIQUIDITY_MULTIPLIER: u64 = 10; // Limit creator burn to <=10%
    const MIN_INITIAL_LIQUIDITY: u64 = MINIMUM_LIQUIDITY * MIN_INITIAL_LIQUIDITY_MULTIPLIER;

    public fun add_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        min_liquidity: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (LPPosition, Coin<CoinA>, Coin<CoinB>) {
        // FIX V2: Deadline enforcement
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        assert!(amount_a_desired > 0 && amount_b_desired > 0, EZeroAmount);

        let (amount_a, amount_b, liquidity) = if (pool.total_liquidity == 0) {
            let liquidity = math::sqrt(amount_a_desired * amount_b_desired);
            assert!(liquidity >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            assert!(liquidity >= MINIMUM_LIQUIDITY, EInsufficientLiquidity);
            
            // Permanently lock the first MINIMUM_LIQUIDITY tokens
            pool.total_liquidity = MINIMUM_LIQUIDITY; 
            pool.locked_liquidity = MINIMUM_LIQUIDITY;
            
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
            
            (amount_a_desired, amount_b_desired, liquidity - MINIMUM_LIQUIDITY)
        } else {
            let reserve_a = balance::value(&pool.reserve_a);
            let reserve_b = balance::value(&pool.reserve_b);
            
            let amount_b_optimal = math::quote(amount_a_desired, reserve_a, reserve_b);
            
            if (amount_b_optimal <= amount_b_desired) {
                assert!(amount_b_optimal > 0, EInsufficientLiquidity);
                
                // Check tolerance
                let tolerance_limit = (amount_b_desired * (10000 - pool.ratio_tolerance_bps)) / 10000;
                assert!(amount_b_optimal >= tolerance_limit, ERatioToleranceExceeded);

                let share_a = ((amount_a_desired as u128) * (pool.total_liquidity as u128) / (reserve_a as u128));
                let share_b = ((amount_b_optimal as u128) * (pool.total_liquidity as u128) / (reserve_b as u128));
                
                // FIX S4: Overflow protection - Check before casting to u64
                assert!(share_a <= MAX_U64, EInsufficientLiquidity);
                assert!(share_b <= MAX_U64, EInsufficientLiquidity);
                
                let liquidity = math::min((share_a as u64), (share_b as u64));
                (amount_a_desired, amount_b_optimal, liquidity)
            } else {
                let amount_a_optimal = math::quote(amount_b_desired, reserve_b, reserve_a);
                assert!(amount_a_optimal <= amount_a_desired, ERatioToleranceExceeded); // Should be true by math
                assert!(amount_a_optimal > 0, EInsufficientLiquidity);

                // Check tolerance
                let tolerance_limit = (amount_a_desired * (10000 - pool.ratio_tolerance_bps)) / 10000;
                assert!(amount_a_optimal >= tolerance_limit, ERatioToleranceExceeded);

                let share_a = ((amount_a_optimal as u128) * (pool.total_liquidity as u128) / (reserve_a as u128));
                let share_b = ((amount_b_desired as u128) * (pool.total_liquidity as u128) / (reserve_b as u128));
                
                // FIX S4: Overflow protection - Check before casting to u64
                assert!(share_a <= MAX_U64, EInsufficientLiquidity);
                assert!(share_b <= MAX_U64, EInsufficientLiquidity);
                
                let liquidity = math::min((share_a as u64), (share_b as u64));
                (amount_a_optimal, amount_b_desired, liquidity)
            }
        };

        assert!(liquidity >= min_liquidity, EInsufficientLiquidity);

        let balance_a = coin::into_balance(coin_a);
        let balance_b = coin::into_balance(coin_b);

        // Split the optimal amount from the total balance
        // Since balance_a/b are local variables, they are mutable by default in legacy Move.
        // We split the amount to add to reserves, and keep the rest in balance_a/b to return.
        
        let to_add_a = balance::split(&mut balance_a, amount_a);
        let to_add_b = balance::split(&mut balance_b, amount_b);

        balance::join(&mut pool.reserve_a, to_add_a);
        balance::join(&mut pool.reserve_b, to_add_b);
        pool.total_liquidity = pool.total_liquidity + liquidity;

        let fee_debt_a = (liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION;
        let fee_debt_b = (liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION;

        event::emit(LiquidityAdded {
            pool_id: object::id(pool),
            provider: tx_context::sender(ctx),
            amount_a,
            amount_b,
            liquidity_minted: liquidity,
        });

        let name = std::string::utf8(b"Sui AMM LP Position");
        let description = std::string::utf8(b"Liquidity Provider Position for Sui AMM");
        let pool_type = std::string::utf8(b"Regular");

        let position = position::new_with_metadata(
            object::id(pool),
            liquidity,
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

        (position, coin::from_balance(balance_a, ctx), coin::from_balance(balance_b, ctx))
    }

    /// Calculate impermanent loss for a position in basis points
    /// IL = (value_hold - value_lp) / value_hold * 10000
    /// Formula: IL = 2*sqrt(price_ratio)/(1 + price_ratio) - 1
    /// Where price_ratio = (current_price / initial_price)
    public fun get_impermanent_loss<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &LPPosition
    ): u64 {
        let liquidity = position::liquidity(position);
        if (liquidity == 0 || pool.total_liquidity == 0) {
            return 0
        };

        // Initial amounts when position was created
        let initial_amount_a = (position::min_a(position) as u128);
        let initial_amount_b = (position::min_b(position) as u128);
        
        // Current reserve ratio (spot price)
        let r_a = (balance::value(&pool.reserve_a) as u128);
        let r_b = (balance::value(&pool.reserve_b) as u128);

        if (r_a == 0 || r_b == 0 || initial_amount_a == 0 || initial_amount_b == 0) {
            return 0
        };

        // FIX V5: Calculate price ratio using proper formula
        // price_ratio = (current_price / initial_price)
        // current_price = r_b / r_a, initial_price = initial_b / initial_a
        // price_ratio = (r_b * initial_a) / (r_a * initial_b)
        // Scaled by 1e18 for precision
        let price_ratio_scaled = (r_b * initial_amount_a * 1_000_000_000_000_000_000) / (r_a * initial_amount_b);
        
        // Calculate sqrt(price_ratio) using Newton's method
        let sqrt_pr = sqrt_u128(price_ratio_scaled);
        
        // Calculate: 2 * sqrt(price_ratio)
        let numerator = 2 * sqrt_pr;
        
        // Calculate: 1 + price_ratio
        let denominator = 1_000_000_000_000_000_000 + price_ratio_scaled;
        
        // Calculate: 2*sqrt(price_ratio) / (1 + price_ratio)
        let ratio = (numerator * 1_000_000_000_000_000_000) / denominator;
        
        // Calculate IL: 1 - ratio (if ratio < 1, means there's IL)
        if (ratio >= 1_000_000_000_000_000_000) {
            0  // No IL (actually a gain)
        } else {
            let il_scaled = 1_000_000_000_000_000_000 - ratio;
            // Convert to basis points (0.01%)
            ((il_scaled * 10000) / 1_000_000_000_000_000_000 as u64)
        }
    }

    /// Helper: Calculate square root of u128 using Newton's method
    fun sqrt_u128(y: u128): u128 {
        if (y < 4) {
            if (y == 0) {
                0
            } else {
                1
            }
        } else {
            let z = y;
            let x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            z
        }
    }

    #[test_only]
    public fun test_cp_price_impact_bps(
        amount_in: u64,
        amount_out: u64,
        reserve_in: u64,
        reserve_out: u64,
    ): u64 {
        cp_price_impact_bps(amount_in, amount_out, reserve_in, reserve_out)
    }

    public fun remove_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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
        assert!(amount_a >= min_amount_a, EInsufficientOutputAmount);
        assert!(amount_b >= min_amount_b, EInsufficientOutputAmount);

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
    /// 
    /// Allows LPs to remove any portion of their liquidity without destroying the position
    public fun remove_liquidity_partial<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

        // Calculate proportional token amounts to withdraw
        let amount_a = (((liquidity_to_remove as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b = (((liquidity_to_remove as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);

        assert!(amount_a >= min_amount_a, EInsufficientLiquidity);
        assert!(amount_b >= min_amount_b, EInsufficientLiquidity);

        // Calculate accumulated fees for the portion being removed
        let fee_ratio = (liquidity_to_remove as u128) * ACC_PRECISION / (total_position_liquidity as u128);
        let pending_a = ((total_position_liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_b = ((total_position_liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        let fee_a_for_portion = ((pending_a * fee_ratio) / ACC_PRECISION as u64);
        let fee_b_for_portion = ((pending_b * fee_ratio) / ACC_PRECISION as u64);

        pool.total_liquidity = pool.total_liquidity - liquidity_to_remove;
        
        let split_a = balance::split(&mut pool.reserve_a, amount_a);
        let split_b = balance::split(&mut pool.reserve_b, amount_b);

        // Add proportional fees to the withdrawn amounts
        if (fee_a_for_portion > 0) {
            let fee = balance::split(&mut pool.fee_a, fee_a_for_portion);
            balance::join(&mut split_a, fee);
        };
        
        if (fee_b_for_portion > 0) {
            let fee = balance::split(&mut pool.fee_b, fee_b_for_portion);
            balance::join(&mut split_b, fee);
        };

        // Update position: reduce liquidity but DON'T destroy
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
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

    public fun increase_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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
        
        // FIX S4: Overflow protection - Check before casting to u64
        assert!(share_a <= MAX_U64, EInsufficientLiquidity);
        assert!(share_b <= MAX_U64, EInsufficientLiquidity);
        
        let liquidity_added = math::min((share_a as u64), (share_b as u64));

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

    /// Constant-product price impact helper (basis points).
    /// This mirrors the old slippage_protection::calculate_price_impact
    /// but is scoped to the regular pool model.
    /// FIX L4: Added overflow protection
    fun cp_price_impact_bps(
        amount_in: u64,
        amount_out: u64,
        reserve_in: u64,
        reserve_out: u64,
    ): u64 {
        let ideal_out = (amount_in as u128) * (reserve_out as u128) / (reserve_in as u128);
        if (ideal_out == 0) { return 0 };

        // FIX L4: Check for overflow before multiplication
        assert!(ideal_out <= MAX_SAFE_VALUE, EOverflow);

        let actual_out = (amount_out as u128);
        if (ideal_out > actual_out) {
            let diff = ideal_out - actual_out;
            (((diff * 10000) / ideal_out) as u64)
        } else {
            0
        }
    }

    public fun swap_a_to_b<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

        // FIX S3: Flash Loan Protection - Capture ORIGINAL reserves BEFORE any modifications
        let reserve_a_original = balance::value(&pool.reserve_a);
        let reserve_b_original = balance::value(&pool.reserve_b);
        assert!(reserve_a_original > 0 && reserve_b_original > 0, EInsufficientLiquidity);

        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;

        // Calculate output using ORIGINAL reserves
        let amount_out = math::calculate_constant_product_output(
            amount_in_after_fee, 
            reserve_a_original,
            reserve_b_original,
            0
        );

        assert!(amount_out >= min_out, EInsufficientOutputAmount);

        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        };

        // FIX S3: Calculate price impact using ORIGINAL reserves (before manipulation)
        let impact = cp_price_impact_bps(
            amount_in,
            amount_out,
            reserve_a_original,
            reserve_b_original,
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        // NOW update reserves after all calculations are done
        balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
        
        let fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
        // Split fee 3-ways: Protocol, Creator, and LPs
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

        if (pool.total_liquidity > 0) {
            pool.acc_fee_per_share_a = pool.acc_fee_per_share_a + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
        };

        // CRITICAL: Verify K-invariant is maintained or increased
        let new_reserve_a = balance::value(&pool.reserve_a);
        let new_reserve_b = balance::value(&pool.reserve_b);
        let new_k = (new_reserve_a as u128) * (new_reserve_b as u128);
        let old_k = (reserve_a_original as u128) * (reserve_b_original as u128);
        assert!(new_k >= old_k, EKInvariantViolation);

        // Verify reserves don't fall below minimum
        assert!(new_reserve_a >= MIN_RESERVE && new_reserve_b >= MIN_RESERVE, EReserveTooLow);

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
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

        // FIX S3: Flash Loan Protection - Capture ORIGINAL reserves BEFORE any modifications
        let reserve_a_original = balance::value(&pool.reserve_a);
        let reserve_b_original = balance::value(&pool.reserve_b);
        assert!(reserve_a_original > 0 && reserve_b_original > 0, EInsufficientLiquidity);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        // Calculate output using ORIGINAL reserves
        let amount_out = math::calculate_constant_product_output(
            amount_in_after_fee, 
            reserve_b_original, 
            reserve_a_original, 
            0
        );

        assert!(amount_out >= min_out, EInsufficientOutputAmount);

        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        };

        // FIX S3: Calculate price impact using ORIGINAL reserves (before manipulation)
        let impact = cp_price_impact_bps(
            amount_in,
            amount_out,
            reserve_b_original,
            reserve_a_original,
        );
        assert!(impact <= pool.max_price_impact_bps, EExcessivePriceImpact);

        // NOW update reserves after all calculations are done
        balance::join(&mut pool.reserve_b, coin::into_balance(coin_in));
        
        let fee_balance = balance::split(&mut pool.reserve_b, fee_amount);
        
        // Split fee 3-ways: Protocol, Creator, and LPs
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

        if (pool.total_liquidity > 0) {
            pool.acc_fee_per_share_b = pool.acc_fee_per_share_b + ((lp_fee_amount as u128) * ACC_PRECISION / (pool.total_liquidity as u128));
        };

        // CRITICAL: Verify K-invariant is maintained or increased
        let new_reserve_a = balance::value(&pool.reserve_a);
        let new_reserve_b = balance::value(&pool.reserve_b);
        let new_k = (new_reserve_a as u128) * (new_reserve_b as u128);
        let old_k = (reserve_a_original as u128) * (reserve_b_original as u128);
        assert!(new_k >= old_k, EKInvariantViolation);

        // Verify reserves don't fall below minimum
        assert!(new_reserve_a >= MIN_RESERVE && new_reserve_b >= MIN_RESERVE, EReserveTooLow);

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
    public fun get_reserves<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b))
    }

    public fun get_amount_out<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64
    ): u64 {
        let (reserve_in, reserve_out) = get_reserves(pool);
        if (reserve_in == 0 || reserve_out == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;

        let numerator = (amount_in_after_fee as u128) * (reserve_out as u128);
        let denominator = (reserve_in as u128) + (amount_in_after_fee as u128);
        
        ((numerator / denominator) as u64)
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

    public fun get_locked_liquidity<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.locked_liquidity
    }

    /// Comprehensive pool information struct
    struct PoolInfo has copy, drop {
        reserve_a: u64,
        reserve_b: u64,
        total_liquidity: u64,
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        creator: address,
        k_value: u128,
    }

    /// Get comprehensive pool info for UIs
    public fun get_pool_info<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): PoolInfo {
        let (r_a, r_b) = get_reserves(pool);
        PoolInfo {
            reserve_a: r_a,
            reserve_b: r_b,
            total_liquidity: pool.total_liquidity,
            fee_percent: pool.fee_percent,
            protocol_fee_percent: pool.protocol_fee_percent,
            creator_fee_percent: pool.creator_fee_percent,
            creator: pool.creator,
            k_value: (r_a as u128) * (r_b as u128),
        }
    }

    /// Withdraw creator fees (only callable by pool creator)
    public fun withdraw_creator_fees<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        assert!(tx_context::sender(ctx) == pool.creator, EWrongPool);
        
        let fee_a = balance::withdraw_all(&mut pool.creator_fee_a);
        let fee_b = balance::withdraw_all(&mut pool.creator_fee_b);
        
        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    public fun get_ratio_tolerance_bps<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.ratio_tolerance_bps
    }

    public fun get_max_price_impact_bps<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.max_price_impact_bps
    }

    public fun get_k<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u128 {
        let (r_a, r_b) = get_reserves(pool);
        (r_a as u128) * (r_b as u128)
    }

    /// Get quote for A->B swap (read-only, no execution)
    public fun get_quote_a_to_b<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        math::calculate_constant_product_output(
            amount_in_after_fee,
            reserve_a,
            reserve_b,
            0
        )
    }

    /// Get quote for B->A swap (read-only, no execution)
    public fun get_quote_b_to_a<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        math::calculate_constant_product_output(
            amount_in_after_fee,
            reserve_b,
            reserve_a,
            0
        )
    }

    /// Get current exchange rate A->B (scaled by 1e9)
    public fun get_exchange_rate<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        
        if (reserve_a == 0) return 0;
        
        // Rate = reserve_b / reserve_a * 1e9
        (((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128) as u64)
    }

    public fun get_protocol_fees<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.protocol_fee_a), balance::value(&pool.protocol_fee_b))
    }

    public fun get_position_value<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &LPPosition
    ): (u64, u64) {
        let liquidity = position::liquidity(position);
        if (pool.total_liquidity == 0) {
            return (0, 0)
        };
        
        let amount_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let amount_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);
        
        (amount_a, amount_b)
    }

    public fun get_accumulated_fees<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &LPPosition
    ): (u64, u64) {
        let liquidity = position::liquidity(position);
        
        let pending_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        ((pending_a as u64), (pending_b as u64))
    }

    public(friend) fun withdraw_protocol_fees<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
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

    public(friend) fun set_risk_params<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>, 
        ratio_tolerance_bps: u64, 
        max_price_impact_bps: u64
    ) {
        pool.ratio_tolerance_bps = ratio_tolerance_bps;
        pool.max_price_impact_bps = max_price_impact_bps;
    }

    public(friend) fun set_protocol_fee_percent<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>, 
        new_percent: u64
    ) {
        assert!(new_percent + pool.creator_fee_percent <= 10000, EInvalidFeeSplit);
        pool.protocol_fee_percent = new_percent;
    }

    /// FIX M4: Calculate price impact for a hypothetical A to B swap (view function)
    /// Returns price impact in basis points without executing the swap
    public fun calculate_swap_price_impact_a2b<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let amount_out = math::calculate_constant_product_output(
            amount_in_after_fee,
            reserve_a,
            reserve_b,
            0
        );
        
        cp_price_impact_bps(amount_in, amount_out, reserve_a, reserve_b)
    }

    /// FIX M4: Calculate price impact for a hypothetical B to A swap (view function)
    /// Returns price impact in basis points without executing the swap
    public fun calculate_swap_price_impact_b2a<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let amount_out = math::calculate_constant_product_output(
            amount_in_after_fee,
            reserve_b,
            reserve_a,
            0
        );
        
        cp_price_impact_bps(amount_in, amount_out, reserve_b, reserve_a)
    }

    /// FIX M2: Refresh position metadata with latest pool state
    /// This updates cached values like current value, pending fees, and IL
    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition
    ) {
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);
        
        let (value_a, value_b) = get_position_value(pool, position);
        let (fee_a, fee_b) = get_accumulated_fees(pool, position);
        let il_bps = get_impermanent_loss(pool, position);
        
        position::update_cached_values(position, value_a, value_b, fee_a, fee_b, il_bps);
    }


    public fun share<CoinA, CoinB>(pool: LiquidityPool<CoinA, CoinB>) {
        transfer::share_object(pool);
    }
}
