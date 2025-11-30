module sui_amm::sui_amm {
    use sui::package;
    use sui::transfer;
    use sui::tx_context::{TxContext};

    /// OTW for the package
    struct SUI_AMM has drop {}

    fun init(otw: SUI_AMM, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);
        transfer::public_share_object(publisher);
    }
}


