/// String manipulation utilities for formatting numbers and text
///
/// This module provides utilities for converting numbers to strings with various
/// formatting options including decimal places, thousand separators, and hexadecimal
/// representation. These functions are primarily used for generating human-readable
/// output in NFT metadata and user interfaces.
module sui_amm::string_utils {
    use std::string::{Self, String};

    /// Convert a u64 integer to its string representation
    ///
    /// Handles the zero case explicitly and builds the string by extracting
    /// digits in reverse order, then reversing the result.
    ///
    /// # Parameters
    /// - `value`: The u64 integer to convert
    ///
    /// # Returns
    /// String representation of the number (e.g., 123 -> "123")
    ///
    /// # Examples
    /// - u64_to_string(0) = "0"
    /// - u64_to_string(123) = "123"
    /// - u64_to_string(1000) = "1000"
    public fun u64_to_string(value: u64): String {
        if (value == 0) {
            return string::utf8(b"0")
        };

        let mut digits = vector::empty<u8>();
        let mut v = value;
        while (v > 0) {
            // Convert digit to ASCII by adding 48 (ASCII code for '0')
            let digit = ((v % 10) as u8) + 48;
            vector::push_back(&mut digits, digit);
            v = v / 10;
        };

        // Digits were extracted in reverse order, so reverse to get correct order
        vector::reverse(&mut digits);
        string::utf8(digits)
    }

    /// Convert a u128 integer to its string representation
    ///
    /// Similar to u64_to_string but handles larger 128-bit integers.
    /// Used for cumulative statistics that may exceed u64 range.
    ///
    /// # Parameters
    /// - `value`: The u128 integer to convert
    ///
    /// # Returns
    /// String representation of the number
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
    ///
    /// Treats the value as a fixed-point number with the specified number of
    /// decimal places. This is essential for displaying token amounts correctly
    /// since blockchain tokens store amounts as integers (e.g., 1.5 USDC with
    /// 6 decimals is stored as 1500000).
    ///
    /// # Parameters
    /// - `value`: The integer value representing the fixed-point number
    /// - `decimals`: Number of decimal places to format
    ///
    /// # Returns
    /// Formatted string with decimal point and leading zeros preserved
    ///
    /// # Examples
    /// - format_decimal(1500000, 6) = "1.500000"
    /// - format_decimal(123456789, 6) = "123.456789"
    /// - format_decimal(1000, 0) = "1000"
    public fun format_decimal(value: u64, decimals: u8): String {
        if (decimals == 0) {
            return u64_to_string(value)
        };

        let divisor = pow10(decimals);
        let integer_part = value / divisor;
        let decimal_part = value % divisor;

        let mut result = u64_to_string(integer_part);
        string::append(&mut result, string::utf8(b"."));
        
        // Pad decimal part with leading zeros to maintain precision
        // For example, 0.05 with 6 decimals should be "0.050000" not "0.5"
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

    /// Format a number with thousand separators for readability
    ///
    /// Inserts commas every three digits from right to left to make large
    /// numbers easier to read in user interfaces.
    ///
    /// # Parameters
    /// - `value`: The number to format
    ///
    /// # Returns
    /// String with commas inserted as thousand separators
    ///
    /// # Examples
    /// - format_with_commas(1000) = "1,000"
    /// - format_with_commas(1000000) = "1,000,000"
    /// - format_with_commas(123) = "123" (no commas needed)
    public fun format_with_commas(value: u64): String {
        let base = u64_to_string(value);
        let bytes = string::as_bytes(&base);
        let len = vector::length(bytes);
        
        if (len <= 3) {
            return base
        };

        let mut result = vector::empty<u8>();
        let mut count = 0;
        
        let mut i = len;
        while (i > 0) {
            i = i - 1;
            if (count == 3) {
                // Insert comma separator (ASCII 44)
                vector::push_back(&mut result, 44);
                count = 0;
            };
            vector::push_back(&mut result, *vector::borrow(bytes, i));
            count = count + 1;
        };
        
        // Built in reverse, so reverse to get correct order
        vector::reverse(&mut result);
        string::utf8(result)
    }

    /// Convert a number to hexadecimal string representation
    ///
    /// Converts a u64 to lowercase hexadecimal with optional zero-padding.
    /// Used primarily for generating color codes in SVG generation.
    ///
    /// # Parameters
    /// - `value`: The number to convert to hex
    /// - `padding`: Minimum number of hex digits (pads with leading zeros)
    ///
    /// # Returns
    /// Lowercase hexadecimal string
    ///
    /// # Examples
    /// - to_hex_string(255, 2) = "ff"
    /// - to_hex_string(15, 2) = "0f"
    /// - to_hex_string(0, 2) = "00"
    public fun to_hex_string(value: u64, padding: u8): String {
        let hex_chars = b"0123456789abcdef";
        let mut result = vector::empty<u8>();
        
        if (value == 0) {
            // Special case: zero needs explicit padding
            let mut i = 0;
            while (i < padding) {
                vector::push_back(&mut result, 48);
                i = i + 1;
            };
            return string::utf8(result)
        };

        let mut v = value;
        while (v > 0) {
            // Convert to hex digit (0-9, a-f)
            let digit = ((v % 16) as u8);
            vector::push_back(&mut result, *vector::borrow(&hex_chars, (digit as u64)));
            v = v / 16;
        };

        // Pad with leading zeros to reach minimum length
        let mut len = vector::length(&result);
        while (len < (padding as u64)) {
            vector::push_back(&mut result, 48);
            len = len + 1;
        };

        // Built in reverse, so reverse to get correct order
        vector::reverse(&mut result);
        string::utf8(result)
    }

    /// Convert a u8 to two-digit hexadecimal string
    ///
    /// Convenience wrapper for converting color components (0-255) to hex.
    /// Always produces exactly 2 hex digits with leading zero if needed.
    ///
    /// # Parameters
    /// - `value`: The u8 value to convert (typically 0-255 for RGB)
    ///
    /// # Returns
    /// Two-character hex string (e.g., "ff", "0a", "00")
    public fun u8_to_hex(value: u8): String {
        to_hex_string((value as u64), 2)
    }

    /// Concatenate multiple strings into a single string
    ///
    /// Efficiently combines a vector of strings in order without intermediate
    /// allocations for each append operation.
    ///
    /// # Parameters
    /// - `parts`: Vector of strings to concatenate
    ///
    /// # Returns
    /// Single string containing all parts in order
    public fun concat(parts: vector<String>): String {
        let mut result = string::utf8(b"");
        let len = vector::length(&parts);
        let mut i = 0;
        
        while (i < len) {
            string::append(&mut result, *vector::borrow(&parts, i));
            i = i + 1;
        };
        
        result
    }

    /// Append multiple strings to an existing string in place
    ///
    /// More efficient than repeated individual appends when combining many strings.
    /// Modifies the base string directly rather than creating a new string.
    ///
    /// # Parameters
    /// - `base`: The string to append to (modified in place)
    /// - `parts`: Vector of strings to append in order
    public fun append_all(base: &mut String, parts: vector<String>) {
        let len = vector::length(&parts);
        let mut i = 0;
        
        while (i < len) {
            string::append(base, *vector::borrow(&parts, i));
            i = i + 1;
        };
    }

    /// Calculate 10 raised to the power of n
    ///
    /// Helper function for decimal formatting. Computes powers of 10 up to 10^18
    /// (maximum that fits in u64).
    ///
    /// # Parameters
    /// - `n`: The exponent (0-18)
    ///
    /// # Returns
    /// 10^n as a u64
    fun pow10(n: u8): u64 {
        let mut result = 1u64;
        let mut i = 0u8;
        while (i < n) {
            result = result * 10;
            i = i + 1;
        };
        result
    }

    /// Truncate a string to maximum length with ellipsis
    ///
    /// If the string exceeds max_len, truncates it and appends "..." to indicate
    /// truncation. Used for displaying long addresses or identifiers in UIs.
    ///
    /// # Parameters
    /// - `s`: The string to truncate
    /// - `max_len`: Maximum length including ellipsis
    ///
    /// # Returns
    /// Original string if short enough, otherwise truncated with "..."
    ///
    /// # Examples
    /// - truncate("0x1234567890abcdef", 10) = "0x12345..."
    /// - truncate("short", 20) = "short" (unchanged)
    public fun truncate(s: &String, max_len: u64): String {
        let bytes = string::as_bytes(s);
        let len = vector::length(bytes);
        
        if (len <= max_len) {
            return *s
        };

        let mut result = vector::empty<u8>();
        let mut i = 0;
        while (i < max_len - 3) {
            vector::push_back(&mut result, *vector::borrow(bytes, i));
            i = i + 1;
        };
        
        // Append three dots (ASCII 46) to indicate truncation
        vector::push_back(&mut result, 46);
        vector::push_back(&mut result, 46);
        vector::push_back(&mut result, 46);
        
        string::utf8(result)
    }

    /// Create a hex color string from RGB components
    ///
    /// Converts three color components (red, green, blue) into a standard
    /// hex color code format used in SVG and CSS.
    ///
    /// # Parameters
    /// - `r`: Red component (0-255)
    /// - `g`: Green component (0-255)
    /// - `b`: Blue component (0-255)
    ///
    /// # Returns
    /// Hex color string in format "#rrggbb"
    ///
    /// # Examples
    /// - rgb_to_hex(255, 100, 50) = "#ff6432"
    /// - rgb_to_hex(255, 255, 255) = "#ffffff"
    /// - rgb_to_hex(0, 0, 0) = "#000000"
    public fun rgb_to_hex(r: u8, g: u8, b: u8): String {
        let mut result = string::utf8(b"#");
        string::append(&mut result, u8_to_hex(r));
        string::append(&mut result, u8_to_hex(g));
        string::append(&mut result, u8_to_hex(b));
        result
    }

    /// Check if a string starts with a given prefix
    ///
    /// Performs byte-by-byte comparison to determine if the string begins
    /// with the specified prefix. Used for validating data URI formats.
    ///
    /// # Parameters
    /// - `s`: The string to check
    /// - `prefix`: The prefix to look for
    ///
    /// # Returns
    /// true if s starts with prefix, false otherwise
    ///
    /// # Examples
    /// - starts_with("data:image/svg", "data:") = true
    /// - starts_with("http://example.com", "https:") = false
    /// - starts_with("short", "very long prefix") = false
    public fun starts_with(s: &String, prefix: &String): bool {
        let s_bytes = string::as_bytes(s);
        let prefix_bytes = string::as_bytes(prefix);
        let s_len = vector::length(s_bytes);
        let prefix_len = vector::length(prefix_bytes);
        
        // Early return: prefix cannot be longer than the string itself
        if (prefix_len > s_len) {
            return false
        };
        
        // Compare each byte of the prefix with the string
        let mut i = 0;
        while (i < prefix_len) {
            if (*vector::borrow(s_bytes, i) != *vector::borrow(prefix_bytes, i)) {
                return false
            };
            i = i + 1;
        };
        
        true
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

    #[test]
    fun test_starts_with() {
        let s = string::utf8(b"data:image/svg+xml;base64,abc123");
        let prefix1 = string::utf8(b"data:");
        let prefix2 = string::utf8(b"data:image/svg+xml;base64,");
        let prefix3 = string::utf8(b"http:");
        let prefix4 = string::utf8(b"data:image/svg+xml;base64,abc123def");
        
        assert!(starts_with(&s, &prefix1) == true, 0);
        assert!(starts_with(&s, &prefix2) == true, 1);
        assert!(starts_with(&s, &prefix3) == false, 2);
        assert!(starts_with(&s, &prefix4) == false, 3); // prefix longer than string
    }
}
