module sui_amm::string_utils {
    use std::string::{Self, String};
    use std::vector;

    /// Convert u64 to string
    public fun u64_to_string(value: u64): String {
        if (value == 0) {
            return string::utf8(b"0")
        };

        let mut digits = vector::empty<u8>();
        let mut v = value;
        while (v > 0) {
            let digit = ((v % 10) as u8) + 48; // ASCII '0'  is 48
            vector::push_back(&mut digits, digit);
            v = v / 10;
        };

        // Reverse the digits
        vector::reverse(&mut digits);
        string::utf8(digits)
    }

    /// Convert u128 to string
    public fun u128_to_string(value: u128): String {
        if (value == 0) {
            return string::utf8(b"0")
        };

        let mut digits = vector::empty<u8>();
        let mut v = value;
        while (v > 0) {
            let digit = (((v % 10) as u8) + 48);
            vector::push_back(&mut digits, digit);
            v = v / 10;
        };

        vector::reverse(&mut digits);
        string::utf8(digits)
    }

    /// Format a u64 value with decimal places
    /// Example: format_decimal(1500000, 6) = "1.500000"
    public fun format_decimal(value: u64, decimals: u8): String {
        if (decimals == 0) {
            return u64_to_string(value)
        };

        let divisor = pow10(decimals);
        let integer_part = value / divisor;
        let decimal_part = value % divisor;

        let mut result = u64_to_string(integer_part);
        string::append(&mut result, string::utf8(b"."));
        
        // Pad decimal part with leading zeros
        let decimal_str = u64_to_string(decimal_part);
        let decimal_bytes = string::as_bytes(&decimal_str);
        let decimal_len = vector::length(decimal_bytes);
        
        let mut i = (decimals as u64);
        while (i > decimal_len) {
            string::append(&mut result, string::utf8(b"0"));
            i = i - 1;
        };
        
        string::append(&mut result, decimal_str);
        result
    }

    /// Format with thousand separators
    /// Example: format_with_commas(1000000) = "1,000,000"
    public fun format_with_commas(value: u64): String {
        let base = u64_to_string(value);
        let bytes = string::as_bytes(&base);
        let mut len = vector::length(bytes);
        
        if (len <= 3) {
            return base
        };

        let mut result = vector::empty<u8>();
        let mut count = 0;
        
        let mut i = len;
        while (i > 0) {
            i = i - 1;
            if (count == 3) {
                vector::push_back(&mut result, 44); // ASCII ','
                count = 0;
            };
            vector::push_back(&mut result, *vector::borrow(bytes, i));
            count = count + 1;
        };
        
        vector::reverse(&mut result);
        string::utf8(result)
    }

    /// Convert number to hex string
    /// Example: to_hex_string(255, 2) = "ff"
    public fun to_hex_string(value: u64, padding: u8): String {
        let hex_chars = b"0123456789abcdef";
        let mut result = vector::empty<u8>();
        
        if (value == 0) {
            let mut i = 0;
            while (i < padding) {
                vector::push_back(&mut result, 48); // '0'
                i = i + 1;
            };
            return string::utf8(result)
        };

        let mut v = value;
        while (v > 0) {
            let digit = ((v % 16) as u8);
            vector::push_back(&mut result, *vector::borrow(&hex_chars, (digit as u64)));
            v = v / 16;
        };

        // Pad with zeros
        let mut len = vector::length(&result);
        while (len < (padding as u64)) {
            vector::push_back(&mut result, 48);
            len = len + 1;
        };

        vector::reverse(&mut result);
        string::utf8(result)
    }

    /// Convert u8 to hex (for colors)
    public fun u8_to_hex(value: u8): String {
        to_hex_string((value as u64), 2)
    }

    /// Concatenate a vector of strings
    public fun concat(parts: vector<String>): String {
        let mut result = string::utf8(b"");
        let mut len = vector::length(&parts);
        let mut i = 0;
        
        while (i < len) {
            string::append(&mut result, *vector::borrow(&parts, i));
            i = i + 1;
        };
        
        result
    }

    /// Append multiple strings to a base string
    public fun append_all(base: &mut String, parts: vector<String>) {
        let mut len = vector::length(&parts);
        let mut i = 0;
        
        while (i < len) {
            string::append(base, *vector::borrow(&parts, i));
            i = i + 1;
        };
    }

    /// Helper: Calculate 10^n
    fun pow10(n: u8): u64 {
        let mut result = 1u64;
        let mut i = 0u8;
        while (i < n) {
            result = result * 10;
            i = i + 1;
        };
        result
    }

    /// Truncate string to max length with ellipsis
    public fun truncate(s: &String, max_len: u64): String {
        let bytes = string::as_bytes(s);
        let mut len = vector::length(bytes);
        
        if (len <= max_len) {
            return *s
        };

        let mut result = vector::empty<u8>();
        let mut i = 0;
        while (i < max_len - 3) {
            vector::push_back(&mut result, *vector::borrow(bytes, i));
            i = i + 1;
        };
        
        vector::push_back(&mut result, 46); // '.'
        vector::push_back(&mut result, 46);
        vector::push_back(&mut result, 46);
        
        string::utf8(result)
    }

    /// Create RGB hex color from components
    /// Example: rgb_to_hex(255, 100, 50) = "#ff6432"
    public fun rgb_to_hex(r: u8, g: u8, b: u8): String {
        let mut result = string::utf8(b"#");
        string::append(&mut result, u8_to_hex(r));
        string::append(&mut result, u8_to_hex(g));
        string::append(&mut result, u8_to_hex(b));
        result
    }

    #[test]
    fun test_u64_to_string() {
        assert!(u64_to_string(0) == string::utf8(b"0"), 0);
        assert!(u64_to_string(123) == string::utf8(b"123"), 1);
        assert!(u64_to_string(1000) == string::utf8(b"1000"), 2);
    }

    #[test]
    fun test_format_decimal() {
        assert!(format_decimal(1000000, 6) == string::utf8(b"1.000000"), 0);
        assert!(format_decimal(1500000, 6) == string::utf8(b"1.500000"), 1);
        assert!(format_decimal(123456789, 6) == string::utf8(b"123.456789"), 2);
    }

    #[test]
    fun test_format_with_commas() {
        assert!(format_with_commas(1000) == string::utf8(b"1,000"), 0);
        assert!(format_with_commas(1000000) == string::utf8(b"1,000,000"), 1);
        assert!(format_with_commas(123) == string::utf8(b"123"), 2);
    }

    #[test]
    fun test_to_hex_string() {
        assert!(to_hex_string(255, 2) == string::utf8(b"ff"), 0);
        assert!(to_hex_string(15, 2) == string::utf8(b"0f"), 1);
        assert!(to_hex_string(0, 2) == string::utf8(b"00"), 2);
    }

    #[test]
    fun test_rgb_to_hex() {
        assert!(rgb_to_hex(255, 255, 255) == string::utf8(b"#ffffff"), 0);
        assert!(rgb_to_hex(0, 0, 0) == string::utf8(b"#000000"), 1);
        assert!(rgb_to_hex(255, 100, 50) == string::utf8(b"#ff6432"), 2);
    }

    #[test]
    fun test_concat() {
        let parts = vector[
            string::utf8(b"Hello"),
            string::utf8(b" "),
            string::utf8(b"World")
        ];
        assert!(concat(parts) == string::utf8(b"Hello World"), 0);
    }

    #[test]
    fun test_truncate() {
        let s = string::utf8(b"0x1234567890abcdef");
        assert!(truncate(&s, 10) == string::utf8(b"0x12345..."), 0);
        assert!(truncate(&s, 20) == s, 1);
    }
}
