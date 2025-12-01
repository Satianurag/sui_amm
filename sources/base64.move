module sui_amm::base64 {
    use std::string::{Self, String};

    /// Encode a string to base64
    public fun encode(input: &String): String {
        let bytes = string::as_bytes(input);
        encode_bytes(bytes)
    }

    /// Encode bytes to base64 string
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

            // Process 3 bytes into 4 base64 characters
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

        // Handle remaining bytes
        if (i < len) {
            let remaining = len - i;
            let b1 = *vector::borrow(input, i);
            
            if (remaining == 1) {
                let idx1 = (b1 >> 2) & 0x3F;
                let idx2 = (b1 & 0x03) << 4;
                
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx1 as u64)));
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx2 as u64)));
                vector::push_back(&mut output, 61); // '='
                vector::push_back(&mut output, 61); // '='
            } else { // remaining == 2
                let b2 = *vector::borrow(input, i + 1);
                let idx1 = (b1 >> 2) & 0x3F;
                let idx2 = ((b1 & 0x03) << 4) | ((b2 >> 4) & 0x0F);
                let idx3 = (b2 & 0x0F) << 2;
                
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx1 as u64)));
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx2 as u64)));
                vector::push_back(&mut output, *vector::borrow(&base64_table, (idx3 as u64)));
                vector::push_back(&mut output, 61); // '='
            };
        };

        string::utf8(output)
    }

    /// Create a data URI from SVG string
    /// Returns: "data:image/svg+xml;base64,{encoded}"
    public fun create_svg_data_uri(svg: String): String {
        let encoded = encode(&svg);
        let mut result = string::utf8(b"data:image/svg+xml;base64,");
        string::append(&mut result, encoded);
        result
    }

    /// Create a data URI from any string with custom MIME type
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
        let mut result = encode(&input);
        assert!(result == string::utf8(b"TWFu"), 0);
    }

    #[test]
    fun test_encode_with_padding() {
        // "Ma" should be "TWE="
        let input = string::utf8(b"Ma");
        let mut result = encode(&input);
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
        let mut result = encode(&input);
        // Expected: "SGVsbG8gV29ybGQ="
        assert!(result == string::utf8(b"SGVsbG8gV29ybGQ="), 0);
    }

    #[test]
    fun test_create_svg_data_uri() {
        let mut svg = string::utf8(b"<svg></svg>");
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
        let mut result = encode(&input);
        assert!(result == string::utf8(b""), 0);
    }
}
