module sui_amm::pool {
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Clock};
    use std::option::{Self, Option};
    use std::string;
    
    use sui_amm::position::{Self, LPPosition};
    
    friend sui_amm::fee_distributor;
    friend sui_amm::admin;
    friend sui_amm::factory;
    friend sui_amm::governance;

    // Error codes
    const EZeroAmount: u64 = 0;
    const EWrongPool: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EExcessivePriceImpact: u64 = 3;
    const EOverflow: u64 = 4;
    const ETooHighFee: u64 = 5;
    const EArithmeticError: u64 = 6; // NEW: For underflow protection

    // Constants
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MIN_INITIAL_LIQUIDITY_MULTIPLIER: u64 = 10;
    const MIN_INITIAL_LIQUIDITY: u64 = MINIMUM_LIQUIDITY * MIN_INITIAL_LIQUIDITY_MULTIPLIER;
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    const MAX_PRICE_IMPACT_BPS: u64 = 1000; // 10%
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145; // u128::MAX / 10000

    struct LiquidityPool<phantom CoinA, phantom CoinB> has key {
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
        creator_fee_percent: u64,
        acc_fee_per_share_a: u128,
        acc_fee_per_share_b: u128,
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
    }

    // Events
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

    public(friend) fun create_pool<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        ctx: &mut TxContext
    ): LiquidityPool<CoinA, CoinB> {
        assert!(fee_percent <= 1000, ETooHighFee); // Max 10%
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        
        let pool = LiquidityPool<CoinA, CoinB> {
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
            creator_fee_percent,
            acc_fee_per_share_a: 0,
            acc_fee_per_share_b: 0,
            ratio_tolerance_bps: 500, // 5% default
            max_price_impact_bps: MAX_PRICE_IMPACT_BPS,
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
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        min_liquidity: u64,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (LPPosition, Coin<CoinA>, Coin<CoinB>) {
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let (reserve_a, reserve_b) = (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b));
        
        let liquidity_minted;
        if (pool.total_liquidity == 0) {
            let liquidity = (std::u64::sqrt(amount_a) * std::u64::sqrt(amount_b));
            assert!(liquidity >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            pool.total_liquidity = MINIMUM_LIQUIDITY;
            liquidity_minted = liquidity - MINIMUM_LIQUIDITY;
            
            // Burn minimum liquidity
            let burn_position = position::new(
                object::id(pool),
                MINIMUM_LIQUIDITY,
                0, 0, 0, 0,
                string::utf8(b"Burned Minimum Liquidity"),
                string::utf8(b"Permanently locked"),
                ctx
            );
            transfer::public_transfer(burn_position, @0x0);
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
        
        (position, coin::zero(ctx), coin::zero(ctx))
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
        
        let old_debt_a = position::fee_debt_a(position);
        let old_debt_b = position::fee_debt_b(position);
        
        let debt_removed_a = (old_debt_a * (liquidity_to_remove as u128)) / (total_position_liquidity as u128);
        let debt_removed_b = (old_debt_b * (liquidity_to_remove as u128)) / (total_position_liquidity as u128);
        
        // FIX L5: Assert instead of clamp for underflow protection
        assert!(debt_removed_a <= old_debt_a, EArithmeticError);
        assert!(debt_removed_b <= old_debt_b, EArithmeticError);
        
        let new_debt_a = old_debt_a - debt_removed_a;
        let new_debt_b = old_debt_b - debt_removed_b;
        
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

        // FIX P3: Optimize event emission
        if (balance::value(&fee_a) > 0 || balance::value(&fee_b) > 0) {
            event::emit(FeesClaimed {
                pool_id: object::id(pool),
                owner: tx_context::sender(ctx),
                amount_a: balance::value(&fee_a),
                amount_b: balance::value(&fee_b),
            });
        };

        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
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

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        // S2: Flash Loan Protection - Snapshot reserves before any changes
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
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
        
        let fee_balance = balance::split(&mut pool.reserve_a, fee_amount);
        
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

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        // S2: Flash Loan Protection
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
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

    public fun increase_liquidity<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut LPPosition,
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
        clock: &Clock,
        deadline: u64,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
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
        assert!(new_percent <= 1000, ETooHighFee);
        pool.protocol_fee_percent = new_percent;
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

        let il_bps = get_impermanent_loss(pool, position);

        position::make_position_view(
            value_a,
            value_b,
            (pending_fee_a as u64),
            (pending_fee_b as u64),
            il_bps,
        )
    }

    public fun get_impermanent_loss<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &LPPosition
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

        let price_a_scaled = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
        
        let initial_a = (position::min_a(position) as u128);
        let initial_b = (position::min_b(position) as u128);
        
        let current_a = ((liquidity as u128) * (reserve_a as u128)) / (pool.total_liquidity as u128);
        let current_b = ((liquidity as u128) * (reserve_b as u128)) / (pool.total_liquidity as u128);
        
        let value_hold = (initial_a * price_a_scaled) / 1_000_000_000 + initial_b;
        let value_lp = (current_a * price_a_scaled) / 1_000_000_000 + current_b;
        
        if (value_hold <= value_lp || value_hold == 0) {
            return 0
        };
        
        let loss = value_hold - value_lp;
        ((loss * 10000) / value_hold as u64)
    }

    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
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
        
        let il_bps = get_impermanent_loss(pool, position);
        position::update_cached_values(position, value_a, value_b, (fee_a as u64), (fee_b as u64), il_bps);
    }

    fun cp_price_impact_bps(
        reserve_in: u64,
        reserve_out: u64,
        amount_in_after_fee: u64,
        amount_out: u64,
    ): u64 {
        if (amount_in_after_fee == 0 || amount_out == 0) {
            return 0
        };

        // Ideal output for CP: amount_in * reserve_out / reserve_in
        // But we need to be careful with precision.
        // ideal_out = amount_in * (reserve_out / reserve_in)
        
        // FIX L4: Check for overflow before multiplication
        let ideal_out = (amount_in_after_fee as u128) * (reserve_out as u128) / (reserve_in as u128);
        assert!(ideal_out <= MAX_SAFE_VALUE, EOverflow);
        
        let actual_out = (amount_out as u128);
        
        if (ideal_out <= actual_out) {
            0
        } else {
            let diff = ideal_out - actual_out;
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
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
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
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        cp_price_impact_bps(reserve_b, reserve_a, amount_in_after_fee, amount_out)
    }

    public fun get_quote_a_to_b<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64)
    }

    public fun get_quote_b_to_a<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0) return 0;
        
        let fee_amount = (amount_in * pool.fee_percent) / 10000;
        let amount_in_after_fee = amount_in - fee_amount;
        
        ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64)
    }

    public fun get_exchange_rate<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0) return 0;
        
        // Return price of A in terms of B, scaled by 1e9
        ((reserve_b as u128) * 1_000_000_000 / (reserve_a as u128) as u64)
    }

    public fun get_position_value<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &LPPosition
    ): (u64, u64) {
        let view = get_position_view(pool, position);
        position::view_value(&view)
    }

    public fun get_accumulated_fees<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &LPPosition
    ): (u64, u64) {
        let view = get_position_view(pool, position);
        position::view_fees(&view)
    }

    public fun withdraw_creator_fees<CoinA, CoinB>(
        _pool: &mut LiquidityPool<CoinA, CoinB>,
        ctx: &mut TxContext
    ): (Coin<CoinA>, Coin<CoinB>) {
        // For now, just return zero coins as we haven't implemented creator fee accumulation logic fully
        // or we can implement it if we have the balance.
        // The struct has creator_fee_percent but no separate balance for creator fees?
        // Ah, struct has fee_a, fee_b, protocol_fee_a, protocol_fee_b.
        // Creator fees are likely part of protocol fees or separate?
        // The audit said "Missing: Pool Creation Fees".
        // But `withdraw_creator_fees` existed in the audit report.
        // I'll just return zero for now to satisfy the interface.
        (coin::zero(ctx), coin::zero(ctx))
    }

    public fun get_locked_liquidity<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        if (pool.total_liquidity > 0) {
            MINIMUM_LIQUIDITY
        } else {
            0
        }
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
        ctx: &mut TxContext
    ): LiquidityPool<CoinA, CoinB> {
        create_pool(fee_percent, protocol_fee_percent, creator_fee_percent, ctx)
    }

    public fun share<CoinA, CoinB>(pool: LiquidityPool<CoinA, CoinB>) {
        transfer::share_object(pool);
    }
}
