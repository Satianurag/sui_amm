/// Module: svg_nft
/// Description: On-chain SVG generation for LP Position NFTs.
/// This satisfies PRD requirement: "Display my LP NFT in wallets and marketplaces"
module sui_amm::svg_nft {
    use std::string::{Self, String};
    use sui_amm::string_utils;
    use sui_amm::base64;

    /// Generate SVG for an LP position NFT
    /// Returns a base64-encoded data URI that can be used as image_url
    public fun generate_lp_position_svg(
        pool_type: string::String,
        liquidity: u64,
        value_a: u64,
        value_b: u64,
        fee_a: u64,
        fee_b: u64,
        il_bps: u64,
        fee_tier_bps: u64,
    ): String {
        let svg = build_svg(
            pool_type,
            liquidity,
            value_a,
            value_b,
            fee_a,
            fee_b,
            il_bps,
            fee_tier_bps
        );
        base64::create_svg_data_uri(svg)
    }

    /// Build the SVG string
    fun build_svg(
        pool_type: string::String,
        liquidity: u64,
        value_a: u64,
        value_b: u64,
        fee_a: u64,
        fee_b: u64,
        il_bps: u64,
        fee_tier_bps: u64,
    ): String {
        let mut svg = string::utf8(b"<svg xmlns='http://www.w3.org/2000/svg' width='400' height='500' viewBox='0 0 400 500'>");
        
        // Background gradient
        string::append(&mut svg, string::utf8(b"<defs><linearGradient id='bg' x1='0%' y1='0%' x2='100%' y2='100%'>"));
        
        // Color based on pool type
        let is_stable = string_contains(&pool_type, b"Stable");
        if (is_stable) {
            string::append(&mut svg, string::utf8(b"<stop offset='0%' style='stop-color:#1a365d'/><stop offset='100%' style='stop-color:#2c5282'/>"));
        } else {
            string::append(&mut svg, string::utf8(b"<stop offset='0%' style='stop-color:#1a202c'/><stop offset='100%' style='stop-color:#2d3748'/>"));
        };
        string::append(&mut svg, string::utf8(b"</linearGradient></defs>"));
        
        // Background rect
        string::append(&mut svg, string::utf8(b"<rect width='400' height='500' fill='url(#bg)' rx='20'/>"));
        
        // Border
        string::append(&mut svg, string::utf8(b"<rect x='10' y='10' width='380' height='480' fill='none' stroke='#4a5568' stroke-width='2' rx='15'/>"));
        
        // Title
        string::append(&mut svg, string::utf8(b"<text x='200' y='50' text-anchor='middle' fill='#e2e8f0' font-family='Arial' font-size='24' font-weight='bold'>SUI AMM LP</text>"));
        
        // Pool type badge
        string::append(&mut svg, string::utf8(b"<rect x='140' y='65' width='120' height='30' fill='#4299e1' rx='15'/>"));
        string::append(&mut svg, string::utf8(b"<text x='200' y='86' text-anchor='middle' fill='white' font-family='Arial' font-size='14'>"));
        string::append(&mut svg, pool_type);
        string::append(&mut svg, string::utf8(b"</text>"));
        
        // Liquidity section
        string::append(&mut svg, string::utf8(b"<text x='30' y='140' fill='#a0aec0' font-family='Arial' font-size='12'>LIQUIDITY SHARES</text>"));
        string::append(&mut svg, string::utf8(b"<text x='30' y='165' fill='#e2e8f0' font-family='Arial' font-size='20' font-weight='bold'>"));
        string::append(&mut svg, string_utils::format_with_commas(liquidity));
        string::append(&mut svg, string::utf8(b"</text>"));
        
        // Value section
        string::append(&mut svg, string::utf8(b"<text x='30' y='210' fill='#a0aec0' font-family='Arial' font-size='12'>POSITION VALUE</text>"));
        string::append(&mut svg, string::utf8(b"<text x='30' y='235' fill='#48bb78' font-family='Arial' font-size='18'>Token A: "));
        string::append(&mut svg, string_utils::format_with_commas(value_a));
        string::append(&mut svg, string::utf8(b"</text>"));
        string::append(&mut svg, string::utf8(b"<text x='30' y='260' fill='#48bb78' font-family='Arial' font-size='18'>Token B: "));
        string::append(&mut svg, string_utils::format_with_commas(value_b));
        string::append(&mut svg, string::utf8(b"</text>"));
        
        // Fees section
        string::append(&mut svg, string::utf8(b"<text x='30' y='305' fill='#a0aec0' font-family='Arial' font-size='12'>ACCUMULATED FEES</text>"));
        string::append(&mut svg, string::utf8(b"<text x='30' y='330' fill='#f6e05e' font-family='Arial' font-size='16'>Fee A: "));
        string::append(&mut svg, string_utils::format_with_commas(fee_a));
        string::append(&mut svg, string::utf8(b"</text>"));
        string::append(&mut svg, string::utf8(b"<text x='30' y='355' fill='#f6e05e' font-family='Arial' font-size='16'>Fee B: "));
        string::append(&mut svg, string_utils::format_with_commas(fee_b));
        string::append(&mut svg, string::utf8(b"</text>"));
        
        // IL section
        string::append(&mut svg, string::utf8(b"<text x='30' y='400' fill='#a0aec0' font-family='Arial' font-size='12'>IMPERMANENT LOSS</text>"));
        let il_color = if (il_bps > 500) { b"#fc8181" } else if (il_bps > 100) { b"#f6e05e" } else { b"#48bb78" };
        string::append(&mut svg, string::utf8(b"<text x='30' y='425' fill='"));
        string::append(&mut svg, string::utf8(il_color));
        string::append(&mut svg, string::utf8(b"' font-family='Arial' font-size='18'>"));
        string::append(&mut svg, string_utils::format_decimal(il_bps, 2));
        string::append(&mut svg, string::utf8(b"%</text>"));
        
        // Fee tier
        string::append(&mut svg, string::utf8(b"<text x='370' y='475' text-anchor='end' fill='#718096' font-family='Arial' font-size='12'>Fee: "));
        string::append(&mut svg, string_utils::format_decimal(fee_tier_bps, 2));
        string::append(&mut svg, string::utf8(b"%</text>"));
        
        // Close SVG
        string::append(&mut svg, string::utf8(b"</svg>"));
        
        svg
    }

    /// Helper to check if string contains substring
    fun string_contains(s: &String, substr: vector<u8>): bool {
        let s_bytes = string::as_bytes(s);
        let s_len = vector::length(s_bytes);
        let sub_len = vector::length(&substr);
        
        if (sub_len > s_len) {
            return false
        };
        
        let mut i = 0;
        while (i <= s_len - sub_len) {
            let mut is_match = true;
            let mut j = 0;
            while (j < sub_len) {
                if (*vector::borrow(s_bytes, i + j) != *vector::borrow(&substr, j)) {
                    is_match = false;
                    break
                };
                j = j + 1;
            };
            if (is_match) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Generate a simple badge SVG for compact display
    public fun generate_badge_svg(
        pool_type: string::String,
        liquidity: u64,
    ): String {
        let mut svg = string::utf8(b"<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='0 0 200 100'>");
        string::append(&mut svg, string::utf8(b"<rect width='200' height='100' fill='#2d3748' rx='10'/>"));
        string::append(&mut svg, string::utf8(b"<text x='100' y='35' text-anchor='middle' fill='#e2e8f0' font-family='Arial' font-size='14' font-weight='bold'>SUI AMM LP</text>"));
        string::append(&mut svg, string::utf8(b"<text x='100' y='55' text-anchor='middle' fill='#4299e1' font-family='Arial' font-size='12'>"));
        string::append(&mut svg, pool_type);
        string::append(&mut svg, string::utf8(b"</text>"));
        string::append(&mut svg, string::utf8(b"<text x='100' y='80' text-anchor='middle' fill='#48bb78' font-family='Arial' font-size='16'>"));
        string::append(&mut svg, string_utils::format_with_commas(liquidity));
        string::append(&mut svg, string::utf8(b" shares</text>"));
        string::append(&mut svg, string::utf8(b"</svg>"));
        
        base64::create_svg_data_uri(svg)
    }

    #[test]
    fun test_generate_svg() {
        let pool_type = string::utf8(b"Standard");
        let svg = generate_lp_position_svg(
            pool_type,
            1000000,
            500000,
            500000,
            1000,
            1000,
            50,
            30
        );
        // Should start with data:image/svg+xml;base64,
        let bytes = string::as_bytes(&svg);
        let prefix = b"data:image/svg+xml;base64,";
        let mut i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(bytes, i) == *vector::borrow(&prefix, i), i);
            i = i + 1;
        };
    }

    #[test]
    fun test_string_contains() {
        let s = string::utf8(b"StableSwap Pool");
        assert!(string_contains(&s, b"Stable"), 0);
        assert!(!string_contains(&s, b"Regular"), 1);
    }
}
