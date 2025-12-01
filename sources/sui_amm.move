module sui_amm::sui_amm {
    use sui::package;
    use sui::transfer;
    // TxContext not needed - auto-imported

    /// OTW for the package
    public struct SUI_AMM has drop {}

    fun init(otw: SUI_AMM, ctx: &mut tx_context::TxContext) {
        let publisher = package::claim(otw, ctx);
        transfer::public_share_object(publisher);
    }
}


