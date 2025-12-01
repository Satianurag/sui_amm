#[test_only]
module sui_amm::svg_nft_tests {
    use std::string;
    use std::vector;
    use sui_amm::svg_nft;

    #[test]
    fun test_generate_lp_position_svg() {
        let pool_type = string::utf8(b"Standard");
        let svg = svg_nft::generate_lp_position_svg(
            pool_type,
            1000000,   // liquidity
            500000,    // value_a
            500000,    // value_b
            1000,      // fee_a
            1000,      // fee_b
            50,        // il_bps (0.5%)
            30         // fee_tier_bps (0.3%)
        );
        
        // Should be a data URI
        let bytes = string::as_bytes(&svg);
        let prefix = b"data:image/svg+xml;base64,";
        let prefix_len = vector::length(&prefix);
        
        // Verify prefix
        let i = 0;
        while (i < prefix_len) {
            assert!(*vector::borrow(bytes, i) == *vector::borrow(&prefix, i), i);
            i = i + 1;
        };
        
        // Should have content after prefix
        assert!(vector::length(bytes) > prefix_len + 100, 100);
    }

    #[test]
    fun test_generate_stable_pool_svg() {
        let pool_type = string::utf8(b"Stable");
        let svg = svg_nft::generate_lp_position_svg(
            pool_type,
            2000000,   // liquidity
            1000000,   // value_a
            1000000,   // value_b
            5000,      // fee_a
            5000,      // fee_b
            10,        // il_bps (0.1% - low for stable)
            5          // fee_tier_bps (0.05%)
        );
        
        let bytes = string::as_bytes(&svg);
        let prefix = b"data:image/svg+xml;base64,";
        
        // Verify it's a valid data URI
        let i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(bytes, i) == *vector::borrow(&prefix, i), i);
            i = i + 1;
        };
    }

    #[test]
    fun test_generate_badge_svg() {
        let pool_type = string::utf8(b"Standard");
        let badge = svg_nft::generate_badge_svg(pool_type, 500000);
        
        let bytes = string::as_bytes(&badge);
        let prefix = b"data:image/svg+xml;base64,";
        
        // Verify prefix
        let i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(bytes, i) == *vector::borrow(&prefix, i), i);
            i = i + 1;
        };
    }

    #[test]
    fun test_svg_with_high_il() {
        // Test with high IL (should show red color)
        let pool_type = string::utf8(b"Standard");
        let svg = svg_nft::generate_lp_position_svg(
            pool_type,
            1000000,
            400000,    // value_a (decreased)
            600000,    // value_b (increased)
            500,
            500,
            750,       // il_bps (7.5% - high)
            30
        );
        
        // Just verify it generates without error
        assert!(string::length(&svg) > 0, 0);
    }

    #[test]
    fun test_svg_with_zero_values() {
        let pool_type = string::utf8(b"Standard");
        let svg = svg_nft::generate_lp_position_svg(
            pool_type,
            0,    // zero liquidity
            0,    // zero value_a
            0,    // zero value_b
            0,    // zero fee_a
            0,    // zero fee_b
            0,    // zero il
            30
        );
        
        // Should still generate valid SVG
        let bytes = string::as_bytes(&svg);
        let prefix = b"data:image/svg+xml;base64,";
        
        let i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(bytes, i) == *vector::borrow(&prefix, i), i);
            i = i + 1;
        };
    }

    #[test]
    fun test_svg_with_large_values() {
        let pool_type = string::utf8(b"Standard");
        let svg = svg_nft::generate_lp_position_svg(
            pool_type,
            1000000000000,  // 1 trillion liquidity
            500000000000,   // 500 billion value_a
            500000000000,   // 500 billion value_b
            10000000,       // 10 million fee_a
            10000000,       // 10 million fee_b
            100,            // 1% IL
            100             // 1% fee tier
        );
        
        // Should handle large numbers
        assert!(string::length(&svg) > 0, 0);
    }
}
