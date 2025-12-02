/// Base64 encoding utilities for data URIs
///
/// This module implements RFC 4648 base64 encoding for converting binary data
/// and strings into base64 format. This is primarily used for embedding SVG
/// images directly in NFT metadata as data URIs.
///
/// Base64 encoding converts 3 bytes (24 bits) into 4 base64 characters (6 bits each).
/// Padding with '=' is used when the input length is not a multiple of 3.
module sui_amm::base64 {
    use std::string::{Self, String};

    /// Encode a string to base64 format
    ///
    /// Convenience wrapper that converts a string to bytes and encodes it.
    ///
    /// # Parameters
    /// - `input`: The string to encode
    ///
    /// # Returns
    /// Base64-encoded string
    public fun encode(input: &String): String {
        let bytes = string::as_bytes(input);
        encode_bytes(bytes)
    }

    /// Encode raw bytes to base64 string
    ///
    /// Implements the standard base64 encoding algorithm:
    /// 1. Process input in 3-byte chunks
    /// 2. Convert each 3-byte chunk to 4 base64 characters
    /// 3. Handle remaining 1-2 bytes with appropriate padding
    ///
    /// The base64 alphabet is: A-Z, a-z, 0-9, +, /
    /// Padding character is '=' (ASCII 61)
    ///
    /// # Parameters
    /// - `input`: Raw bytes to encode
    ///
    /// # Returns
    /// Base64-encoded string with padding if needed
    public fun encode_bytes(input: &vector<u8>): String {
        let len = vector::length(input);
        if (len == 0) {
            return string::utf8(b"")
        };

        let mut output = vector::empty<u8>();
        let base64_table = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        
        let mut i = 0;
        while (i + 2 < len) {
            let b1 = *vector::borrow(input, i);
            let b2 = *vector::borrow(input, i + 1);
            let b3 = *vector::borrow(input, i + 2);

            // Convert 3 bytes (24 bits) into 4 base64 characters (6 bits each)
            // idx1: first 6 bits of b1
            // idx2: last 2 bits of b1 + first 4 bits of b2
            // idx3: last 4 bits of b2 + first 2 bits of b3
            // idx4: last 6 bits of b3
            let idx1 = (b1 >> 2) & 0x3F;
            let idx2 = ((b1 & 0x03) << 4) | ((b2 >> 4) & 0x0F);
            let idx3 = ((b2 & 0x0F) << 2) | ((b3 >> 6) & 0x03);
            let idx4 = b3 & 0x3F;

            vector::push_back(&mut output, *vector::borrow(&base64_table, (idx1 as u64)));
            vector::push_back(&mut output, *vector::borrow(&base64_table, (idx2 as u64)));
            vector::push_back(&mut output, *vector::borrow(&base64_table, (idx3 as u64)));
            vector::push_back(&mut output, *vector::borrow(&base64_table, (idx4 as u64)));

            i = i + 3;
        };

        // Handle remaining 1 or 2 bytes with appropriate padding
        if (i < len) {
            let remaining = len - i;
            let b1 = *vector::borrow(input, i);
            
            if (remaining == 1) {
                // 1 byte remaining: encode to 2 characters + 2 padding
                let idx1 = (b1 >> 2) & 0x3F;
                let idx2 = (b1 & 0x03) << 4;
                
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx1 as u64)));
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx2 as u64)));
                vector::push_back(&mut output, 61); // '=' padding
                vector::push_back(&mut output, 61); // '=' padding
            } else { // remaining == 2
                // 2 bytes remaining: encode to 3 characters + 1 padding
                let b2 = *vector::borrow(input, i + 1);
                let idx1 = (b1 >> 2) & 0x3F;
                let idx2 = ((b1 & 0x03) << 4) | ((b2 >> 4) & 0x0F);
                let idx3 = (b2 & 0x0F) << 2;
                
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx1 as u64)));
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx2 as u64)));
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx3 as u64)));
                vector::push_back(&mut output, 61); // '=' padding
            };
        };

        string::utf8(output)
    }

    /// Create a data URI from an SVG string
    ///
    /// Encodes the SVG as base64 and wraps it in a data URI with the appropriate
    /// MIME type. This allows the SVG to be embedded directly in NFT metadata
    /// without requiring external hosting.
    ///
    /// # Parameters
    /// - `svg`: The SVG XML string to encode
    ///
    /// # Returns
    /// Complete data URI in format: "data:image/svg+xml;base64,{encoded_svg}"
    ///
    /// # Examples
    /// Input: "<svg>...</svg>"
    /// Output: "data:image/svg+xml;base64,PHN2Zz4uLi48L3N2Zz4="
    public fun create_svg_data_uri(svg: String): String {
        let encoded = encode(&svg);
        let mut result = string::utf8(b"data:image/svg+xml;base64,");
        string::append(&mut result, encoded);
        result
    }

    /// Create a data URI with custom MIME type
    ///
    /// Generic function for creating data URIs with any MIME type.
    /// Useful for embedding various types of content (JSON, text, images)
    /// directly in metadata.
    ///
    /// # Parameters
    /// - `content`: The content to encode
    /// - `mime_type`: MIME type string (e.g., "application/json", "text/plain")
    ///
    /// # Returns
    /// Complete data URI in format: "data:{mime_type};base64,{encoded_content}"
    public fun create_data_uri(content: string::String, mime_type: String): String {
        let encoded = encode(&content);
        let mut result = string::utf8(b"data:");
        string::append(&mut result, mime_type);
        string::append(&mut result, string::utf8(b";base64,"));
        string::append(&mut result, encoded);
        result
    }

    #[test]
    fun test_encode_simple() {
        // "Man" in base64 should be "TWFu"
        let input = string::utf8(b"Man");
        let result = encode(&input);
        assert!(result == string::utf8(b"TWFu"), 0);
    }

    #[test]
    fun test_encode_with_padding() {
        // "Ma" should be "TWE="
        let input = string::utf8(b"Ma");
        let result = encode(&input);
        assert!(result == string::utf8(b"TWE="), 0);

        // "M" should be "TQ=="
        let input2 = string::utf8(b"M");
        let result2 = encode(&input2);
        assert!(result2 == string::utf8(b"TQ=="), 1);
    }

    #[test]
    fun test_encode_longer() {
        // "Hello World" 
        let input = string::utf8(b"Hello World");
        let result = encode(&input);
        // Expected: "SGVsbG8gV29ybGQ="
        assert!(result == string::utf8(b"SGVsbG8gV29ybGQ="), 0);
    }

    #[test]
    fun test_create_svg_data_uri() {
        let svg = string::utf8(b"<svg></svg>");
        let uri = create_svg_data_uri(svg);
        
        // Should start with data:image/svg+xml;base64,
        let bytes = string::as_bytes(&uri);
        let prefix = b"data:image/svg+xml;base64,";
        let prefix_len = vector::length(&prefix);
        
        let mut i = 0;
        while (i < prefix_len) {
            assert!(*vector::borrow(bytes, i) == *vector::borrow(&prefix, i), (i as u64));
            i = i + 1;
        };
    }

    #[test]
    fun test_empty_string() {
        let input = string::utf8(b"");
        let result = encode(&input);
        assert!(result == string::utf8(b""), 0);
    }
}
