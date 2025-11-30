# Security Audit Checklist - Sui AMM

## 1. Mathematical Integrity
- [ ] **Constant Product Formula**: Verify `x * y = k` invariant is maintained after every swap, add liquidity, and remove liquidity operation.
- [ ] **StableSwap Invariant**: Verify the Curve-like invariant holds for stable pools.
- [ ] **Overflow Protection**: Ensure all intermediate calculations (especially those involving `u128`) do not overflow.
    - [ ] Check `stable_math::get_y` and `stable_math::get_d`.
    - [ ] Check price impact calculations.
- [ ] **Rounding Errors**: Verify that rounding always favors the protocol/pool to prevent value extraction (e.g., round down output, round up input).
- [ ] **Division by Zero**: Ensure all divisions are protected against zero denominators.

## 2. Access Control & Permissions
- [ ] **Admin Capabilities**: Verify `AdminCap` is required for sensitive operations (fee setting, protocol fee withdrawal).
- [ ] **Friend Modules**: Ensure `public(friend)` functions are only accessible by authorized modules (`factory`, `router`, etc.).
- [ ] **Creator Privileges**: Verify that only the pool creator can withdraw creator fees.

## 3. Liquidity Management
- [ ] **Minimum Liquidity**: Confirm `MINIMUM_LIQUIDITY` is burned upon pool creation to prevent inflation attacks.
- [ ] **Initial Liquidity**: Verify sufficient initial liquidity is required to prevent empty pool states.
- [ ] **Ratio Checks**: Ensure `add_liquidity` enforces current reserve ratios within tolerance to prevent manipulation.
- [ ] **Slippage Protection**: Verify `min_out` parameters are enforced for all swaps and liquidity removals.

## 4. Economic Security
- [ ] **Sandwich Attacks**: Ensure slippage protection (`min_out`) is mandatory and effective.
- [ ] **Flash Loans**: If flash loans are implemented, verify reserves are snapshotted before execution and K-invariant is checked after.
- [ ] **Fee Distribution**: Verify fees are correctly calculated, collected, and distributed to LPs, Protocol, and Creator.
- [ ] **Reentrancy**: Although Move has no reentrancy by default, check for logical reentrancy in complex flows (e.g., auto-compounding).

## 5. Move-Specific Checks
- [ ] **Object Ownership**: Verify objects are correctly shared, transferred, or destroyed.
- [ ] **Coin Management**: Ensure no coins are accidentally dropped or locked.
- [ ] **Type Safety**: Verify generic type constraints are appropriate (e.g., `phantom` parameters).
- [ ] **Sui Version**: Ensure compatibility with the target Sui framework version.

## 6. Denial of Service (DoS)
- [ ] **Unbounded Loops**: Check for any loops over unbounded data structures (e.g., iterating all pools).
- [ ] **Gas Limits**: Verify that complex operations (like stable math convergence) fit within gas limits.
- [ ] **Spam Protection**: Ensure pool creation fees or limits prevent registry spamming.

## 7. Oracle & Price Manipulation
- [ ] **Price Impact**: Verify price impact checks prevent large trades from manipulating the pool significantly in a single block.
- [ ] **TWAP**: If TWAP is implemented, verify the accumulation logic is robust against manipulation.
