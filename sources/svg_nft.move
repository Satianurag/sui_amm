/// On-chain SVG generation for LP Position NFTs
///
/// This module generates dynamic SVG images for liquidity position NFTs that display
/// real-time position data including liquidity shares, token values, accumulated fees,
/// and impermanent loss. The SVGs are encoded as base64 data URIs and can be displayed
/// directly in wallets and marketplaces without external hosting.
///
/// The visual design adapts based on pool type (Standard vs Stable) with different
/// color schemes and displays key metrics in a card-like format.
module sui_amm::svg_nft {
    use std::string::{Self, String};
    use sui_amm::string_utils;
    use sui_amm::base64;

    /// Generate a complete SVG image for an LP position NFT
    ///
    /// Creates a visually rich SVG displaying all key position metrics in a card format.
    /// The SVG includes gradient backgrounds, color-coded sections, and formatted numbers
    /// for easy readability.
    ///
    /// # Parameters
    /// - `pool_type`: Pool type string (e.g., "Standard", "Stable")
    /// - `liquidity`: Total liquidity shares owned
    /// - `value_a`: Current value in token A
    /// - `value_b`: Current value in token B
    /// - `fee_a`: Accumulated fees in token A
    /// - `fee_b`: Accumulated fees in token B
    /// - `il_bps`: Impermanent loss in basis points (e.g., 50 = 0.5%)
    /// - `fee_tier_bps`: Pool fee tier in basis points (e.g., 30 = 0.3%)
    ///
    /// # Returns
    /// Base64-encoded data URI suitable for NFT image_url field
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

    /// Build the SVG XML string with all visual elements
    ///
    /// Constructs a 400x500px SVG with multiple sections:
    /// - Gradient background (color varies by pool type)
    /// - Title and pool type badge
    /// - Liquidity shares display
    /// - Position value breakdown (Token A and B)
    /// - Accumulated fees display
    /// - Impermanent loss indicator (color-coded by severity)
    /// - Fee tier information
    ///
    /// The function builds the SVG by concatenating string fragments for each element.
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
        
        // Define gradient background that varies by pool type
        string::append(&mut svg, string::utf8(b"<defs><linearGradient id='bg' x1='0%' y1='0%' x2='100%' y2='100%'>"));
        
        // Use blue gradient for stable pools, gray for standard pools
        let is_stable = string_contains(&pool_type, b"Stable");
        if (is_stable) {
            string::append(&mut svg, string::utf8(b"<stop offset='0%' style='stop-color:#1a365d'/><stop offset='100%' style='stop-color:#2c5282'/>"));
        } else {
            string::append(&mut svg, string::utf8(b"<stop offset='0%' style='stop-color:#1a202c'/><stop offset='100%' style='stop-color:#2d3748'/>"));
        };
        string::append(&mut svg, string::utf8(b"</linearGradient></defs>"));
        
        // Apply gradient background with rounded corners
        string::append(&mut svg, string::utf8(b"<rect width='400' height='500' fill='url(#bg)' rx='20'/>"));
        
        // Add subtle border for depth
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
        
        // Impermanent loss section with color-coded severity
        string::append(&mut svg, string::utf8(b"<text x='30' y='400' fill='#a0aec0' font-family='Arial' font-size='12'>IMPERMANENT LOSS</text>"));
        // Color coding: red (>5%), yellow (1-5%), green (<1%)
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

    /// Check if a string contains a substring
    ///
    /// Performs a sliding window search to find if substr appears anywhere in s.
    /// Used to detect pool type keywords like "Stable" in pool type strings.
    ///
    /// # Parameters
    /// - `s`: The string to search in
    /// - `substr`: The substring to search for (as bytes)
    ///
    /// # Returns
    /// true if substr is found anywhere in s, false otherwise
    fun string_contains(s: &String, substr: vector<u8>): bool {
        let s_bytes = string::as_bytes(s);
        let s_len = vector::length(s_bytes);
        let sub_len = vector::length(&substr);
        
        if (sub_len > s_len) {
            return false
        };
        
        // Sliding window search: try each position in the string
        let mut i = 0;
        while (i <= s_len - sub_len) {
            let mut is_match = true;
            let mut j = 0;
            // Check if substring matches at current position
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

    /// Generate a compact badge SVG for simplified display
    ///
    /// Creates a smaller 200x100px SVG with minimal information (pool type and
    /// liquidity shares). Useful for list views or compact displays where the
    /// full position card would be too large.
    ///
    /// # Parameters
    /// - `pool_type`: Pool type string (e.g., "Standard", "Stable")
    /// - `liquidity`: Total liquidity shares owned
    ///
    /// # Returns
    /// Base64-encoded data URI suitable for compact NFT display
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
