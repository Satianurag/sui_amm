/// Liquidity Pool implementation for the Sui AMM
/// 
/// This module implements a constant product automated market maker (AMM) with advanced features
/// including auto-compounding, dynamic NFT positions, and comprehensive display data.
/// 
/// # Overview
/// 
/// The pool module manages liquidity pools that enable:
/// - Token swaps using the constant product formula (x * y = k)
/// - Liquidity provision with LP Position NFTs
/// - Fee accumulation and distribution
/// - Auto-compounding of trading fees
/// - Real-time position valuation
/// - Impermanent loss tracking
/// 
/// # Key Features
/// 
/// ## Auto-Compounding
/// Automatically reinvest accumulated fees back into positions to maximize returns:
/// ```move
/// let liquidity_increase = pool::auto_compound_fees(
///     &mut pool,
///     &mut position,
///     min_liquidity_increase,
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// ## NFT Display Data
/// Get comprehensive position information in a single query:
/// ```move
/// let display_data = pool::get_nft_display_data(
///     &pool,
///     &position,
///     &clock,
///     staleness_threshold_ms
/// );
/// ```
/// 
/// ## Metadata Refresh
/// Update cached NFT metadata with current values:
/// ```move
/// pool::refresh_position_metadata(&pool, &mut position, &clock);
/// ```
/// 
/// # Usage Examples
/// 
/// ## Creating a Pool
/// ```move
/// let pool = pool::create_pool<CoinA, CoinB>(
///     30,    // 0.3% fee
///     1000,  // 10% protocol fee
///     100,   // 1% creator fee
///     ctx
/// );
/// transfer::public_share_object(pool);
/// ```
/// 
/// ## Adding Liquidity
/// ```move
/// let (position, refund_a, refund_b) = pool::add_liquidity(
///     &mut pool,
///     coin_a,
///     coin_b,
///     min_liquidity,
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// ## Swapping Tokens
/// ```move
/// let coin_b = pool::swap_a_to_b(
///     &mut pool,
///     coin_a,
///     min_out,
///     option::some(max_price),
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// ## Checking Position Value
/// ```move
/// let view = pool::get_position_view(&pool, &position);
/// let (value_a, value_b) = position::view_value(&view);
/// let (fees_a, fees_b) = position::view_fees(&view);
/// ```
/// 
/// ## Withdrawing Fees
/// ```move
/// let (fee_a, fee_b) = pool::withdraw_fees(
///     &mut pool,
///     &mut position,
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// ## Removing Liquidity
/// ```move
/// // Remove all liquidity
/// let (coin_a, coin_b) = pool::remove_liquidity(
///     &mut pool,
///     position,
///     min_amount_a,
///     min_amount_b,
///     &clock,
///     deadline,
///     ctx
/// );
/// 
/// // Or remove partial liquidity
/// let (coin_a, coin_b) = pool::remove_liquidity_partial(
///     &mut pool,
///     &mut position,
///     liquidity_to_remove,
///     min_amount_a,
///     min_amount_b,
///     &clock,
///     deadline,
///     ctx
/// );
/// ```
/// 
/// # Important Constants
/// 
/// - `MIN_COMPOUND_THRESHOLD` (1000): Minimum fees required for auto-compound
/// - `MINIMUM_LIQUIDITY` (1000): Permanently burned on first liquidity addition
/// - `MAX_STALENESS_THRESHOLD` (86400000): 24 hours in milliseconds
/// - `ACC_PRECISION` (1e12): Precision for fee accumulation calculations
/// 
/// # Security Features
/// 
/// - **Pause Mechanism**: Emergency pause for pool operations
/// - **Slippage Protection**: Minimum output and deadline checks
/// - **Price Impact Limits**: Maximum price impact per swap
/// - **Ratio Tolerance**: Liquidity addition ratio validation
/// - **Fee Validation**: Minimum and maximum fee constraints
/// - **Overflow Protection**: Safe arithmetic for large values
/// 
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
    const EArithmeticError: u64 = 6;
    const EUnauthorized: u64 = 7;
    const EInvalidLiquidityRatio: u64 = 8;
    const EInsufficientOutput: u64 = 9;
    const ECreatorFeeTooHigh: u64 = 10;
    const EPaused: u64 = 11;
    const EInvalidFeePercent: u64 = 12;
    
    /// Error: Insufficient fees to perform auto-compound operation
    /// Thrown when attempting to auto-compound with fees below MIN_COMPOUND_THRESHOLD
    /// Requirements: 1.4 - Auto-compound minimum threshold validation
    const EInsufficientFeesToCompound: u64 = 100;

    // Constants
    
    /// MINIMUM_LIQUIDITY: Permanently burned liquidity shares for pool security
    ///
    /// On first liquidity addition, 1000 shares are permanently burned (sent to address 0x0)
    /// to prevent pool manipulation attacks. This is a standard AMM security practice.
    ///
    /// # Security Benefits
    ///
    /// 1. **Prevents division by zero**: Ensures total_liquidity is never zero after initialization
    /// 2. **Prevents price manipulation**: Makes it economically infeasible to manipulate pool ratios
    /// 3. **Ensures price discovery**: Minimum liquidity always exists for accurate pricing
    /// 4. **Protects against rounding**: Prevents rounding exploits in small pools
    ///
    /// # Cost
    ///
    /// The first LP pays this one-time cost to secure the pool. Subsequent LPs are not affected.
    /// This approach is similar to Uniswap V2's design.
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MIN_INITIAL_LIQUIDITY_MULTIPLIER: u64 = 10;
    const MIN_INITIAL_LIQUIDITY: u64 = MINIMUM_LIQUIDITY * MIN_INITIAL_LIQUIDITY_MULTIPLIER;
    
    /// Precision multiplier for fee accumulation calculations
    /// Using 1e12 precision prevents rounding errors in fee distribution
    const ACC_PRECISION: u128 = 1_000_000_000_000;
    
    /// Maximum allowed price impact per swap (10%)
    /// Protects users from excessive slippage on large trades
    const MAX_PRICE_IMPACT_BPS: u64 = 1000;
    
    /// Maximum safe value for arithmetic operations to prevent overflow
    /// Calculated as u128::MAX / 10000 to allow safe basis point calculations
    const MAX_SAFE_VALUE: u128 = 34028236692093846346337460743176821145;
    
    /// Maximum creator fee (5%) to protect LPs from excessive value extraction
    /// SECURITY: Prevents pool creators from setting exploitative fee rates
    const MAX_CREATOR_FEE_BPS: u64 = 500;
    
    /// Minimum fee amount to accumulate before updating fee per share
    /// Prevents precision loss from accumulating dust amounts
    const MIN_FEE_THRESHOLD: u64 = 1000;
    
    /// Minimum fee rate for pool creation (0.01%)
    /// Ensures LPs receive meaningful returns for providing liquidity
    const MIN_FEE_BPS: u64 = 1;
    
    /// Minimum total fees required for auto-compound operation
    /// Prevents auto-compounding with dust amounts that would result in precision loss
    /// Requirements: 1.4 - Auto-compound with insufficient fees should be rejected
    const MIN_COMPOUND_THRESHOLD: u64 = 1000;

    public struct LiquidityPool<phantom CoinA, phantom CoinB> has key {
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
        ratio_tolerance_bps: u64,
        max_price_impact_bps: u64,
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

    public struct AutoCompoundExecuted has copy, drop {
        pool_id: object::ID,
        position_id: object::ID,
        amount_a: u64,
        amount_b: u64,
        liquidity_increase: u64,
    }

    /// Creates a new liquidity pool with specified fee parameters
    ///
    /// This function creates an empty pool that can be shared and used for trading.
    /// The pool must be initialized with liquidity via add_liquidity before swaps can occur.
    ///
    /// # Parameters
    /// - `fee_percent`: Trading fee in basis points (1-1000, i.e., 0.01%-10%)
    /// - `protocol_fee_percent`: Protocol's share of trading fees in basis points (0-1000)
    /// - `creator_fee_percent`: Creator's share of trading fees in basis points (0-500, max 5%)
    ///
    /// # Fee Distribution
    /// When a swap occurs, the fee is split three ways:
    /// - LP Fee: Goes to liquidity providers (remainder after protocol and creator fees)
    /// - Protocol Fee: Goes to protocol treasury
    /// - Creator Fee: Goes to pool creator
    ///
    /// # Security Validations
    /// - Minimum fee: Enforces MIN_FEE_BPS (0.01%) to ensure meaningful LP returns
    /// - Maximum fee: Caps at 10% to prevent excessive fees
    /// - Creator fee cap: Limited to 5% to protect LPs from value extraction
    ///
    /// # Aborts
    /// - EInvalidFeePercent: If fee_percent < MIN_FEE_BPS
    /// - ETooHighFee: If fee_percent > 1000 or protocol_fee_percent > 1000
    /// - ECreatorFeeTooHigh: If creator_fee_percent > MAX_CREATOR_FEE_BPS (500)
    public(package) fun create_pool<CoinA, CoinB>(
        fee_percent: u64,
        protocol_fee_percent: u64,
        creator_fee_percent: u64,
        ctx: &mut tx_context::TxContext
    ): LiquidityPool<CoinA, CoinB> {
        // SECURITY: Enforce minimum fee to prevent zero-fee pools with no LP incentive
        assert!(fee_percent >= MIN_FEE_BPS, EInvalidFeePercent);
        assert!(fee_percent <= 1000, ETooHighFee);
        assert!(protocol_fee_percent <= 1000, ETooHighFee);
        
        // SECURITY: Validate creator fee to protect LPs from excessive value extraction
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
            ratio_tolerance_bps: 50,
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
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EZeroAmount);

        let (reserve_a, reserve_b) = (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b));
        
        // Validate liquidity ratio for existing pools
        // Ensures added liquidity maintains pool's price ratio within tolerance
        if (pool.total_liquidity > 0) {
            // Compare ratios using cross-multiplication to avoid division
            // Expected: amount_a / amount_b ≈ reserve_a / reserve_b
            // Cross-multiply: amount_a * reserve_b ≈ amount_b * reserve_a
            let val_a = (amount_a as u128) * (reserve_b as u128);
            let val_b = (amount_b as u128) * (reserve_a as u128);
            
            let diff = if (val_a > val_b) { val_a - val_b } else { val_b - val_a };
            let max_val = if (val_a > val_b) { val_a } else { val_b };
            
            if (max_val > 0) {
                // Calculate deviation in basis points
                let deviation = (diff * 10000) / max_val;
                assert!(deviation <= (pool.ratio_tolerance_bps as u128), EInvalidLiquidityRatio);
            };
        };
        
        let liquidity_minted;
        let refund_a;
        let refund_b;
        
        if (pool.total_liquidity == 0) {
            // Initial liquidity addition with MINIMUM_LIQUIDITY burn
            // Calculate liquidity shares using geometric mean: sqrt(amount_a * amount_b)
            let liquidity = (std::u64::sqrt(amount_a) * std::u64::sqrt(amount_b));
            assert!(liquidity >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);
            
            // SECURITY: Burn MINIMUM_LIQUIDITY shares to prevent manipulation
            // The first LP must provide enough liquidity to mint at least MIN_INITIAL_LIQUIDITY shares
            // Of these, MINIMUM_LIQUIDITY (1000) shares are permanently burned
            //
            // Example: If first LP provides liquidity worth 10,000 shares:
            // - 1,000 shares burned (sent to 0x0, unrecoverable)
            // - 9,000 shares minted to first LP
            // - Pool total_liquidity = 1,000 (only burned shares count initially)
            //
            // This one-time cost secures the pool against:
            // - Price manipulation attacks on low-liquidity pools
            // - Division by zero in share calculations
            // - Rounding exploits in subsequent liquidity additions
            pool.total_liquidity = MINIMUM_LIQUIDITY;
            liquidity_minted = liquidity - MINIMUM_LIQUIDITY;
            
            // Create and immediately destroy a position to burn the minimum liquidity
            let burn_position = position::new(
                object::id(pool),
                MINIMUM_LIQUIDITY,
                0, 0, 0, 0,
                string::utf8(b"Burned Minimum Liquidity"),
                string::utf8(b"Permanently locked for pool security"),
                ctx
            );
            position::destroy(burn_position);
            
            balance::join(&mut pool.reserve_a, coin::into_balance(coin_a));
            balance::join(&mut pool.reserve_b, coin::into_balance(coin_b));
            
            refund_a = coin::zero<CoinA>(ctx);
            refund_b = coin::zero<CoinB>(ctx);
        } else {
            // SECURITY: Overflow protection for large liquidity additions
            // Verify that amount * total_liquidity fits in u128 before multiplication
            if (pool.total_liquidity > 0) {
                let max_u128 = 340282366920938463463374607431768211455;
                assert!((amount_a as u128) <= max_u128 / (pool.total_liquidity as u128), EOverflow);
                assert!((amount_b as u128) <= max_u128 / (pool.total_liquidity as u128), EOverflow);
            };

            // Calculate liquidity shares proportional to reserves
            // Use the minimum of the two ratios to maintain pool balance
            let share_a = ((amount_a as u128) * (pool.total_liquidity as u128) / (reserve_a as u128));
            let share_b = ((amount_b as u128) * (pool.total_liquidity as u128) / (reserve_b as u128));
            liquidity_minted = if (share_a < share_b) { (share_a as u64) } else { (share_b as u64) };
            
            // Calculate exact amounts to use based on minted liquidity
            // This prevents user value loss from integer division rounding
            let amount_a_used = (((liquidity_minted as u128) * (reserve_a as u128) / (pool.total_liquidity as u128)) as u64);
            let amount_b_used = (((liquidity_minted as u128) * (reserve_b as u128) / (pool.total_liquidity as u128)) as u64);
            
            let mut balance_a = coin::into_balance(coin_a);
            let mut balance_b = coin::into_balance(coin_b);
            
            let balance_a_used = balance::split(&mut balance_a, amount_a_used);
            let balance_b_used = balance::split(&mut balance_b, amount_b_used);
            
            balance::join(&mut pool.reserve_a, balance_a_used);
            balance::join(&mut pool.reserve_b, balance_b_used);
            
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

        // Initialize NFT position with current values
        // NOTE: Metadata becomes stale after swaps. For real-time values, use get_position_view()
        // or call refresh_position_metadata() to update cached NFT data
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
        
        // Calculate proportional fee debt to remove using ceiling division
        // This prevents fee loss by rounding up the debt removal
        // Formula: ceil(old_debt * liquidity_to_remove / total_liquidity)
        // Ceiling division: ceil(a/b) = (a + b - 1) / b
        let debt_removed_a = ((old_debt_a * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        let debt_removed_b = ((old_debt_b * (liquidity_to_remove as u128)) + (total_position_liquidity as u128) - 1) / (total_position_liquidity as u128);
        
        // SECURITY: Cap debt removal at old_debt to prevent underflow
        // Ceiling division can exceed old_debt in edge cases
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
        
        // Calculate pending fees: accumulated fees per share minus position's fee debt
        let pending_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);

        // SECURITY: Validate pending fees don't exceed available pool fees
        // This defense-in-depth check prevents any potential fee double-claiming exploits
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
        
        // SECURITY: Verify new debt >= old debt to catch fee accumulation logic errors
        assert!(new_debt_a >= position::fee_debt_a(position), EArithmeticError);
        assert!(new_debt_b >= position::fee_debt_b(position), EArithmeticError);
        
        position::update_fee_debt(position, new_debt_a, new_debt_b);

        // Emit event only if fees were actually claimed
        if (balance::value(&fee_a) > 0 || balance::value(&fee_b) > 0) {
            event::emit(FeesClaimed {
                pool_id: object::id(pool),
                owner: tx_context::sender(ctx),
                amount_a: balance::value(&fee_a),
                amount_b: balance::value(&fee_b),
            });
        };

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
        assert!(!pool.paused, EPaused);
        
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EZeroAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        // SECURITY: Snapshot reserves before changes for K-invariant verification
        // Protects against flash loan attacks
        let reserve_a_initial = reserve_a;
        let reserve_b_initial = reserve_b;

        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY: MEV protection with default 5% maximum slippage
        // If max_price is not provided, enforce default slippage limit to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Calculate spot price and effective price in "input per output" representation
            // spot_price = reserve_a / reserve_b (how much A per unit B)
            // effective_price = amount_in / amount_out (how much A user pays per unit B)
            // A worse trade means HIGHER effective_price
            let spot_price = ((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000);
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
        };

        // Calculate and validate price impact using initial reserves
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

        // Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            // Use "input per output" price representation (A per B)
            let spot_price = ((reserve_a as u128) * 1_000_000_000) / (reserve_b as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
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

        // Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            // Use "input per output" price representation (B per A)
            let spot_price = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
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

        // Use safe fee calculation with overflow protection
        let (fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        sui_amm::slippage_protection::check_slippage(amount_out, min_out);

        // SECURITY FIX [P1-15.3]: Enforce MEV protection with default max slippage
        // If max_price is not provided, enforce a default 5% maximum slippage to prevent sandwich attacks
        if (option::is_some(&max_price)) {
            sui_amm::slippage_protection::check_price_limit(amount_in, amount_out, *option::borrow(&max_price));
        } else {
            // Default: enforce 5% maximum slippage (500 bps) when max_price not specified
            // Use "input per output" price representation (B per A)
            let spot_price = ((reserve_b as u128) * 1_000_000_000) / (reserve_a as u128);
            let effective_price = ((amount_in as u128) * 1_000_000_000) / (amount_out as u128);
            let max_allowed_price = spot_price + (spot_price * 500 / 10000); // 5% worse than spot
            assert!(effective_price <= max_allowed_price, EInsufficientOutput);
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

        refresh_position_metadata(pool, position, clock);

        (coin::from_balance(balance_a, ctx), coin::from_balance(balance_b, ctx))
    }

    /// Auto-compound accumulated fees back into the position
    /// 
    /// This function automatically reinvests accumulated trading fees back into the liquidity
    /// position, increasing the position's share of the pool without requiring manual withdrawal
    /// and re-deposit. This maximizes returns by continuously compounding earnings.
    /// 
    /// # How It Works
    /// 
    /// 1. **Withdraw Fees**: Extracts pending fees from the pool
    /// 2. **Balance Fees**: If fees are unbalanced, swaps to match pool ratio
    /// 3. **Add Liquidity**: Reinvests fees as additional liquidity
    /// 4. **Update Position**: Increases position's liquidity shares
    /// 5. **Emit Event**: Records the auto-compound operation
    /// 
    /// # Usage Example
    /// 
    /// ```move
    /// // Auto-compound with 1% slippage tolerance
    /// let position_view = pool::get_position_view(&pool, &position);
    /// let (pending_a, pending_b) = position::view_fees(&position_view);
    /// 
    /// // Calculate expected liquidity increase (approximate)
    /// let expected_liquidity = calculate_expected_shares(pending_a, pending_b);
    /// let min_liquidity = expected_liquidity * 99 / 100; // 1% slippage
    /// 
    /// // Execute auto-compound
    /// let liquidity_increase = pool::auto_compound_fees(
    ///     &mut pool,
    ///     &mut position,
    ///     min_liquidity,
    ///     &clock,
    ///     deadline,
    ///     ctx
    /// );
    /// 
    /// // Position now has more liquidity shares
    /// assert!(position::liquidity(&position) > original_liquidity);
    /// ```
    /// 
    /// # Gas Optimization Tips
    /// 
    /// - Only auto-compound when fees exceed MIN_COMPOUND_THRESHOLD (1000)
    /// - Consider batching multiple positions in a single transaction
    /// - Auto-compound less frequently for smaller positions
    /// - Use higher staleness thresholds to reduce metadata refresh costs
    /// 
    /// # Important Notes
    /// 
    /// - **Minimum Threshold**: Total fees must be >= MIN_COMPOUND_THRESHOLD (1000)
    /// - **Ratio Maintenance**: Fees are automatically balanced to match pool ratio
    /// - **Refunds**: Any dust amounts are refunded to the sender
    /// - **Metadata Refresh**: Position metadata is automatically updated
    /// - **Fee Debt Reset**: Fee debt is updated so pending fees become zero
    /// 
    /// # Value Preservation
    /// 
    /// The total value of the position (liquidity + fees) is preserved during auto-compound:
    /// ```
    /// value_before = position_value + pending_fees
    /// value_after = position_value_increased
    /// assert!(value_after >= value_before - rounding_error)
    /// ```
    /// 
    /// Requirements: 1.1, 1.2, 1.3, 1.4, 1.5
    /// 
    /// # Arguments
    /// * `pool` - The liquidity pool (must match position's pool_id)
    /// * `position` - The LP position to auto-compound (must have sufficient fees)
    /// * `min_liquidity_increase` - Minimum liquidity shares to mint (slippage protection)
    /// * `clock` - Clock for deadline checking and timestamp tracking
    /// * `deadline` - Transaction deadline timestamp in milliseconds
    /// * `ctx` - Transaction context (for sender address and refunds)
    /// 
    /// # Returns
    /// * `u64` - The amount of liquidity shares added to the position
    /// 
    /// # Aborts
    /// * `EWrongPool` - If position doesn't belong to this pool
    /// * `EInsufficientFeesToCompound` - If total fees < MIN_COMPOUND_THRESHOLD (1000)
    /// * `EInsufficientOutput` - If liquidity increase < min_liquidity_increase
    /// * `EPaused` - If pool is paused
    /// * Deadline exceeded - If current time > deadline
    /// 
    /// # Events Emitted
    /// * `AutoCompoundExecuted` - Contains pool_id, position_id, amounts, and liquidity_increase
    /// 
    /// # Returns
    /// * `u64` - Liquidity increase amount
    /// * `Coin<CoinA>` - Refund of unused CoinA (may be zero)
    /// * `Coin<CoinB>` - Refund of unused CoinB (may be zero)
    public fun auto_compound_fees<CoinA, CoinB>(
        pool: &mut LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        min_liquidity_increase: u64,
        clock: &clock::Clock,
        deadline: u64,
        ctx: &mut tx_context::TxContext
    ): (u64, coin::Coin<CoinA>, coin::Coin<CoinB>) {
        // Check if pool is paused
        assert!(!pool.paused, EPaused);
        
        // Check deadline
        sui_amm::slippage_protection::check_deadline(clock, deadline);
        
        // Validate position belongs to pool (Requirement 1.1)
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);

        // Get pending fees using get_position_view() (Requirement 1.1)
        let liquidity = position::liquidity(position);
        let pending_fee_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let pending_fee_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);

        // Check fees meet minimum threshold (Requirement 1.4)
        let total_fees = (pending_fee_a as u64) + (pending_fee_b as u64);
        assert!(total_fees >= MIN_COMPOUND_THRESHOLD, EInsufficientFeesToCompound);

        // Store liquidity before increase to calculate the delta
        let liquidity_before = position::liquidity(position);

        // Withdraw fees to temporary coins (Requirement 1.1)
        let (mut fee_coin_a, mut fee_coin_b) = withdraw_fees(pool, position, clock, deadline, ctx);
        
        let mut fee_amount_a = coin::value(&fee_coin_a);
        let mut fee_amount_b = coin::value(&fee_coin_b);

        // Handle unbalanced fees by swapping to match pool ratio (Requirement 1.2)
        // If one fee is zero or fees are very unbalanced, swap to balance them
        if (fee_amount_a == 0 || fee_amount_b == 0) {
            // One fee is zero - swap half of the non-zero fee to get both tokens
            if (fee_amount_a == 0 && fee_amount_b > 0) {
                // Swap half of B to A
                let swap_amount = fee_amount_b / 2;
                let swap_coin = coin::split(&mut fee_coin_b, swap_amount, ctx);
                let swapped_coin_a = swap_b_to_a(pool, swap_coin, 0, option::none(), clock, deadline, ctx);
                coin::join(&mut fee_coin_a, swapped_coin_a);
                fee_amount_a = coin::value(&fee_coin_a);
                fee_amount_b = coin::value(&fee_coin_b);
            } else if (fee_amount_b == 0 && fee_amount_a > 0) {
                // Swap half of A to B
                let swap_amount = fee_amount_a / 2;
                let swap_coin = coin::split(&mut fee_coin_a, swap_amount, ctx);
                let swapped_coin_b = swap_a_to_b(pool, swap_coin, 0, option::none(), clock, deadline, ctx);
                coin::join(&mut fee_coin_b, swapped_coin_b);
                fee_amount_a = coin::value(&fee_coin_a);
                fee_amount_b = coin::value(&fee_coin_b);
            };
        };

        // Verify we still have enough fees after potential swap
        let total_fees_after_swap = fee_amount_a + fee_amount_b;
        assert!(total_fees_after_swap >= MIN_COMPOUND_THRESHOLD / 2, EInsufficientFeesToCompound);

        // Calculate optimal amounts maintaining pool ratio (Requirement 1.2)
        // Use increase_liquidity which already handles ratio calculation
        let (refund_a, refund_b) = increase_liquidity(
            pool,
            position,
            fee_coin_a,
            fee_coin_b,
            min_liquidity_increase,
            clock,
            deadline,
            ctx
        );

        // Calculate liquidity increase (Requirement 1.3)
        let liquidity_after = position::liquidity(position);
        let liquidity_increase = liquidity_after - liquidity_before;

        // Calculate amounts actually used
        let refund_amount_a = coin::value(&refund_a);
        let refund_amount_b = coin::value(&refund_b);
        let amount_a_used = fee_amount_a - refund_amount_a;
        let amount_b_used = fee_amount_b - refund_amount_b;

        // Emit AutoCompoundExecuted event (Requirement 1.5)
        event::emit(AutoCompoundExecuted {
            pool_id: object::id(pool),
            position_id: position::get_id(position),
            amount_a: amount_a_used,
            amount_b: amount_b_used,
            liquidity_increase,
        });

        // Return liquidity increase amount and refund coins (Requirement 1.3)
        (liquidity_increase, refund_a, refund_b)
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

    public fun get_risk_params<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (pool.ratio_tolerance_bps, pool.max_price_impact_bps)
    }

    public fun is_paused<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): bool {
        pool.paused
    }

    public fun get_protocol_fees<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.protocol_fee_a), balance::value(&pool.protocol_fee_b))
    }

    public fun get_fees<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u64, u64) {
        (balance::value(&pool.fee_a), balance::value(&pool.fee_b))
    }

    public fun get_acc_fee_per_share<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): (u128, u128) {
        (pool.acc_fee_per_share_a, pool.acc_fee_per_share_b)
    }

    public fun get_creator_fee_percent<CoinA, CoinB>(pool: &LiquidityPool<CoinA, CoinB>): u64 {
        pool.creator_fee_percent
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

    /// Get comprehensive NFT display data for wallet and marketplace integration
    /// 
    /// This function provides a unified interface for retrieving all LP Position NFT information
    /// in a single call, optimized for wallet and marketplace integrations. It combines real-time
    /// calculated values with cached metadata, allowing clients to choose between accuracy and
    /// gas efficiency.
    /// 
    /// # What This Function Returns
    /// 
    /// The returned `NFTDisplayData` struct contains:
    /// 
    /// ## Real-Time Values (Always Accurate)
    /// - Current position value in both tokens
    /// - Pending unclaimed fees
    /// - Current impermanent loss percentage
    /// 
    /// ## Cached Values (May Be Stale)
    /// - Last cached position values
    /// - Last cached fees
    /// - Last cached impermanent loss
    /// 
    /// ## Metadata
    /// - Position and pool identifiers
    /// - Display name and description
    /// - Pool type and fee tier
    /// - Base64-encoded SVG image
    /// 
    /// ## Staleness Information
    /// - Boolean flag indicating if cached data is stale
    /// - Timestamp of last metadata update
    /// - Age of cached data in milliseconds
    /// 
    /// # Usage Example
    /// 
    /// ```move
    /// // Get display data with 1 hour staleness threshold
    /// let display_data = pool::get_nft_display_data(
    ///     &pool,
    ///     &position,
    ///     &clock,
    ///     3_600_000  // 1 hour in milliseconds
    /// );
    /// 
    /// // Check if metadata is stale
    /// if (position::display_is_stale(&display_data)) {
    ///     // Cached values are outdated - use real-time values
    ///     let current_value_a = position::display_current_value_a(&display_data);
    ///     let current_value_b = position::display_current_value_b(&display_data);
    ///     
    ///     // Optionally refresh metadata for future queries
    ///     pool::refresh_position_metadata(&pool, &mut position, &clock);
    /// } else {
    ///     // Cached values are fresh - can use either cached or real-time
    ///     let cached_value_a = position::display_cached_value_a(&display_data);
    /// };
    /// 
    /// // Display NFT image
    /// let image_url = position::display_image_url(&display_data);
    /// // image_url format: "data:image/svg+xml;base64,PHN2Zy4uLg=="
    /// ```
    /// 
    /// # Staleness Threshold Recommendations
    /// 
    /// Choose a threshold based on your use case:
    /// 
    /// - **Real-time trading UI**: 60,000 ms (1 minute)
    ///   - Users need up-to-the-second accuracy
    ///   - Prompt refresh frequently
    /// 
    /// - **Portfolio dashboard**: 300,000 ms (5 minutes)
    ///   - Balance between accuracy and UX
    ///   - Refresh on user action
    /// 
    /// - **Wallet display**: 3,600,000 ms (1 hour)
    ///   - Casual viewing, less critical
    ///   - Refresh when user opens position details
    /// 
    /// - **Marketplace listing**: 86,400,000 ms (24 hours)
    ///   - Static display, updated rarely
    ///   - Refresh before listing
    /// 
    /// # Performance Considerations
    /// 
    /// This function is gas-efficient because:
    /// - It only reads from storage (no writes)
    /// - Real-time calculations are done on-demand
    /// - No state changes or events emitted
    /// 
    /// For maximum gas efficiency:
    /// - Use cached values when staleness is acceptable
    /// - Batch multiple position queries in one transaction
    /// - Only call refresh_position_metadata() when necessary
    /// 
    /// # Integration Guide
    /// 
    /// ## For Wallet Developers
    /// ```move
    /// // Display position in wallet
    /// let data = pool::get_nft_display_data(&pool, &position, &clock, 3_600_000);
    /// 
    /// // Show basic info
    /// display_name(position::display_name(&data));
    /// display_image(position::display_image_url(&data));
    /// 
    /// // Show current values (always accurate)
    /// display_value(
    ///     position::display_current_value_a(&data),
    ///     position::display_current_value_b(&data)
    /// );
    /// 
    /// // Show staleness warning if needed
    /// if (position::display_is_stale(&data)) {
    ///     show_refresh_button();
    /// };
    /// ```
    /// 
    /// ## For Marketplace Developers
    /// ```move
    /// // Before listing, ensure metadata is fresh
    /// let data = pool::get_nft_display_data(&pool, &position, &clock, 86_400_000);
    /// 
    /// if (position::display_is_stale(&data)) {
    ///     // Prompt user to refresh before listing
    ///     pool::refresh_position_metadata(&pool, &mut position, &clock);
    /// };
    /// 
    /// // Use image URL for marketplace display
    /// let image = position::display_image_url(&data);
    /// ```
    /// 
    /// Requirements: 2.1, 2.2, 2.3, 2.4, 2.5
    /// 
    /// # Arguments
    /// * `pool` - The liquidity pool (must match position's pool_id)
    /// * `position` - The LP position to query
    /// * `clock` - Clock for staleness calculation
    /// * `staleness_threshold_ms` - Threshold in milliseconds for staleness check
    /// 
    /// # Returns
    /// * `NFTDisplayData` - Complete display data struct with all fields populated
    /// 
    /// # Aborts
    /// * `EWrongPool` - If position doesn't belong to this pool (checked in get_position_view)
    public fun get_nft_display_data<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &position::LPPosition,
        clock: &clock::Clock,
        staleness_threshold_ms: u64
    ): position::NFTDisplayData {
        // Get real-time position view
        let position_view = get_position_view(pool, position);
        
        // Build and return NFTDisplayData using position module's helper
        position::make_nft_display_data(
            position,
            &position_view,
            clock,
            staleness_threshold_ms
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

    /// Refresh position NFT metadata with current values
    ///
    /// Updates the cached values in the NFT metadata and regenerates the SVG image.
    /// This function allows users to update their NFT display without claiming fees.
    ///
    /// # Metadata Staleness
    ///
    /// NFT metadata is NOT automatically updated on every swap for gas efficiency.
    /// This is an intentional design decision.
    ///
    /// ## For Real-Time Data
    /// Use `get_position_view()` which computes values on-demand without gas cost for updates.
    ///
    /// ## When to Call This Function
    /// - Before listing on marketplaces
    /// - Before viewing in wallets that only read NFT metadata
    /// - Before taking screenshots for records
    ///
    /// ## Automatic Refresh
    /// Metadata IS automatically refreshed on:
    /// - `remove_liquidity_partial()`
    /// - `withdraw_fees()`
    /// - `increase_liquidity()`
    ///
    /// # What This Function Does
    /// 1. Updates `last_metadata_update_ms` timestamp
    /// 2. Regenerates SVG image (always, even if values unchanged)
    /// 3. Updates cached values if they've changed
    ///
    /// Requirements: 2.3, 2.4 - Refresh metadata and regenerate SVG
    public fun refresh_position_metadata<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        position: &mut position::LPPosition,
        clock: &sui::clock::Clock
    ) {
        assert!(position::pool_id(position) == object::id(pool), EWrongPool);
        
        let liquidity = position::liquidity(position);
        if (pool.total_liquidity == 0) {
            position::touch_metadata_timestamp(position, clock);
            position::refresh_nft_image(position);
            return
        };
        
        let value_a = (((liquidity as u128) * (balance::value(&pool.reserve_a) as u128) / (pool.total_liquidity as u128)) as u64);
        let value_b = (((liquidity as u128) * (balance::value(&pool.reserve_b) as u128) / (pool.total_liquidity as u128)) as u64);
        
        let fee_a = ((liquidity as u128) * pool.acc_fee_per_share_a / ACC_PRECISION) - position::fee_debt_a(position);
        let fee_b = ((liquidity as u128) * pool.acc_fee_per_share_b / ACC_PRECISION) - position::fee_debt_b(position);
        
        // Check if values have changed since last update
        let cached_value_a = position::cached_value_a(position);
        let cached_value_b = position::cached_value_b(position);
        let cached_fee_a = position::cached_fee_a(position);
        let cached_fee_b = position::cached_fee_b(position);
        
        if (value_a == cached_value_a && value_b == cached_value_b && 
            (fee_a as u64) == cached_fee_a && (fee_b as u64) == cached_fee_b) {
            // Values unchanged: update timestamp and regenerate SVG
            // This ensures is_metadata_stale() returns false after explicit refresh
            position::touch_metadata_timestamp(position, clock);
            position::refresh_nft_image(position);
            return
        };

        let il_bps = get_impermanent_loss(pool, position);
        
        // Update cached values (this also calls refresh_nft_image internally)
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

    /// Calculate trading fee with overflow protection
    ///
    /// Uses u128 for intermediate calculations to prevent overflow when multiplying
    /// large amounts by fee percentages.
    ///
    /// # Parameters
    /// - `amount_in`: Input amount to calculate fee from
    /// - `fee_percent`: Fee rate in basis points (e.g., 30 = 0.30%)
    ///
    /// # Returns
    /// - `fee_amount`: The fee to be collected
    /// - `amount_after_fee`: The amount remaining after fee deduction
    ///
    /// # Security
    /// Validates that the fee calculation doesn't overflow u64 after division
    fun calculate_fee_safe(amount_in: u64, fee_percent: u64): (u64, u64) {
        // Use u128 to prevent overflow in multiplication
        let fee_calculation = (amount_in as u128) * (fee_percent as u128);
        let fee_amount_u128 = fee_calculation / 10000;
        
        // SECURITY: Verify result fits in u64
        assert!(fee_amount_u128 <= (18446744073709551615 as u128), EOverflow);
        
        let fee_amount = (fee_amount_u128 as u64);
        let amount_after_fee = amount_in - fee_amount;
        (fee_amount, amount_after_fee)
    }

    /// Calculate price impact for a constant product swap
    ///
    /// Price impact measures how much the trade moves the price compared to the ideal
    /// constant product formula. Returns impact in basis points (1 bps = 0.01%).
    ///
    /// # Formula
    /// ideal_out = amount_in * reserve_out / reserve_in
    /// impact = (ideal_out - actual_out) / ideal_out * 10000
    ///
    /// # Parameters
    /// - `reserve_in`: Reserve of input token
    /// - `reserve_out`: Reserve of output token
    /// - `amount_in_after_fee`: Input amount after fee deduction
    /// - `amount_out`: Actual output amount
    ///
    /// # Returns
    /// Price impact in basis points (0-10000, where 10000 = 100%)
    ///
    /// # Edge Cases
    /// - Returns 0 if any input is zero
    /// - Returns 10000 (100%) if calculation would overflow
    fun cp_price_impact_bps(
        reserve_in: u64,
        reserve_out: u64,
        amount_in_after_fee: u64,
        amount_out: u64,
    ): u64 {
        // Handle zero cases to prevent division by zero
        if (reserve_in == 0) return 0;
        if (reserve_out == 0) return 10000;
        if (amount_in_after_fee == 0) return 0;
        if (amount_out == 0) return 0;

        // SECURITY: Overflow protection for multiplication
        // Check if amount_in * reserve_out would overflow u128
        let max_u128 = 340282366920938463463374607431768211455u128;
        
        if ((amount_in_after_fee as u128) > max_u128 / (reserve_out as u128)) {
            return 10000
        };
        
        // Calculate ideal output using constant product formula
        let ideal_out = (amount_in_after_fee as u128) * (reserve_out as u128) / (reserve_in as u128);
        
        // SECURITY: Validate intermediate values don't exceed safe bounds
        assert!(ideal_out <= MAX_SAFE_VALUE, EArithmeticError);
        
        let actual_out = (amount_out as u128);
        
        if (ideal_out <= actual_out) {
            0
        } else {
            let diff = ideal_out - actual_out;
            assert!(diff <= MAX_SAFE_VALUE, EArithmeticError);
            
            if (ideal_out == 0) {
                return 0
            };
            
            // SECURITY: Check for overflow in final calculation (diff * 10000)
            if (diff > max_u128 / 10000) {
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
        
        // Use safe fee calculation with overflow protection
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
        
        // Use safe fee calculation with overflow protection
        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);
        
        let amount_out = ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64);
        
        cp_price_impact_bps(reserve_b, reserve_a, amount_in_after_fee, amount_out)
    }

    /// Calculate expected slippage for a trade
    ///
    /// Slippage measures the difference between expected output (at spot price) and
    /// actual output (accounting for price impact).
    ///
    /// # Formula
    /// Slippage = (Expected Output - Actual Output) / Expected Output * 10000
    ///
    /// # Parameters
    /// - `pool`: The liquidity pool
    /// - `amount_in`: Input amount to swap
    /// - `is_a_to_b`: Direction of swap (true = A to B, false = B to A)
    ///
    /// # Returns
    /// Slippage in basis points (0-10000, where 10000 = 100%)
    public fun calculate_swap_slippage_bps<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);
        if (reserve_a == 0 || reserve_b == 0 || amount_in == 0) return 0;

        let (_fee_amount, amount_in_after_fee) = calculate_fee_safe(amount_in, pool.fee_percent);

        // Calculate actual output using constant product formula
        let actual_out = if (is_a_to_b) {
             ((amount_in_after_fee as u128) * (reserve_b as u128) / ((reserve_a as u128) + (amount_in_after_fee as u128)) as u64)
        } else {
             ((amount_in_after_fee as u128) * (reserve_a as u128) / ((reserve_b as u128) + (amount_in_after_fee as u128)) as u64)
        };

        // Calculate expected output at spot price
        let expected_out = if (is_a_to_b) {
            (amount_in_after_fee as u128) * (reserve_b as u128) / (reserve_a as u128)
        } else {
            (amount_in_after_fee as u128) * (reserve_a as u128) / (reserve_b as u128)
        };
        
        if (expected_out > MAX_SAFE_VALUE) {
             return 10000
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
        
        // Use safe fee calculation with overflow protection
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
        
        // Use safe fee calculation with overflow protection
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
        
        // Use safe fee calculation with overflow protection
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
        
        // Use safe fee calculation with overflow protection
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

    #[test_only]
    public fun destroy_for_testing<CoinA, CoinB>(pool: LiquidityPool<CoinA, CoinB>) {
        let LiquidityPool {
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
            ratio_tolerance_bps: _,
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
