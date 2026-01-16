//! Unicode utilities for character classification and normalization.

const std = @import("std");

/// Check if a codepoint is a lowercase letter (basic Unicode ranges).
pub fn isLower(c: u21) bool {
    // ASCII lowercase
    if (c >= 'a' and c <= 'z') return true;
    // Latin-1 Supplement lowercase
    if (c >= 0x00E0 and c <= 0x00F6) return true;
    if (c >= 0x00F8 and c <= 0x00FF) return true;
    // Latin Extended-A lowercase (odd codepoints from 0x0101-0x017F generally)
    if (c >= 0x0100 and c <= 0x017F) {
        // Simple heuristic: in this range, lowercase are often odd codepoints.
        return (c & 1) == 1;
    }
    // Greek lowercase
    if (c >= 0x03B1 and c <= 0x03C9) return true;
    // Cyrillic lowercase
    if (c >= 0x0430 and c <= 0x044F) return true;
    return false;
}

/// Check if a codepoint is an uppercase letter (basic Unicode ranges).
pub fn isUpper(c: u21) bool {
    // ASCII uppercase
    if (c >= 'A' and c <= 'Z') return true;
    // Latin-1 Supplement uppercase
    if (c >= 0x00C0 and c <= 0x00D6) return true;
    if (c >= 0x00D8 and c <= 0x00DE) return true;
    // Latin Extended-A uppercase (even codepoints from 0x0100-0x017E generally)
    if (c >= 0x0100 and c <= 0x017E) {
        return (c & 1) == 0;
    }
    // Greek uppercase
    if (c >= 0x0391 and c <= 0x03A9) return true;
    // Cyrillic uppercase
    if (c >= 0x0410 and c <= 0x042F) return true;
    return false;
}

/// Check if a codepoint is alphabetic.
pub fn isAlphabetic(c: u21) bool {
    if (isLower(c) or isUpper(c)) return true;
    // Basic Latin letters
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= 'a' and c <= 'z') return true;
    // Latin Extended ranges
    if (c >= 0x0100 and c <= 0x024F) return true;
    // Greek and Coptic
    if (c >= 0x0370 and c <= 0x03FF) return true;
    // Cyrillic
    if (c >= 0x0400 and c <= 0x04FF) return true;
    // CJK Unified Ideographs (treat as alphabetic for matching purposes)
    if (c >= 0x4E00 and c <= 0x9FFF) return true;
    // Hiragana
    if (c >= 0x3040 and c <= 0x309F) return true;
    // Katakana
    if (c >= 0x30A0 and c <= 0x30FF) return true;
    // Hangul Syllables
    if (c >= 0xAC00 and c <= 0xD7AF) return true;
    return false;
}

pub fn isNumeric(c: u21) bool {
    // ASCII digits
    if (c >= '0' and c <= '9') return true;
    // Full-width digits
    if (c >= 0xFF10 and c <= 0xFF19) return true;
    // Arabic-Indic digits
    if (c >= 0x0660 and c <= 0x0669) return true;
    // Extended Arabic-Indic digits
    if (c >= 0x06F0 and c <= 0x06F9) return true;
    return false;
}

pub fn isWhitespace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true, // ASCII whitespace
        0x00A0 => true, // Non-breaking space
        0x1680 => true, // Ogham space mark
        0x2000...0x200A => true, // En quad through hair space
        0x2028 => true, // Line separator
        0x2029 => true, // Paragraph separator
        0x202F => true, // Narrow no-break space
        0x205F => true, // Medium mathematical space
        0x3000 => true, // Ideographic space
        else => false,
    };
}

/// Simple unicode case folding (lowercase conversion).
/// This is a simplified version - full unicode case folding would need lookup tables.
pub fn toLower(c: u21) u21 {
    // ASCII fast path
    if (c >= 'A' and c <= 'Z') {
        return c + 32;
    }
    // Latin-1 Supplement uppercase
    if (c >= 0x00C0 and c <= 0x00D6) {
        return c + 32;
    }
    if (c >= 0x00D8 and c <= 0x00DE) {
        return c + 32;
    }
    // Special case: Ÿ (0x0178) -> ÿ (0x00FF)
    if (c == 0x0178) {
        return 0x00FF;
    }
    // Latin Extended-A uppercase (even codepoints map to the next odd codepoint)
    if (c >= 0x0100 and c <= 0x017E and (c & 1) == 0) {
        return c + 1;
    }
    // Greek uppercase
    if (c >= 0x0391 and c <= 0x03A1) {
        return c + 32;
    }
    if (c >= 0x03A3 and c <= 0x03A9) {
        return c + 32;
    }
    // Cyrillic uppercase
    if (c >= 0x0410 and c <= 0x042F) {
        return c + 32;
    }
    // For other characters, return as-is (a full implementation would use lookup tables).
    return c;
}

/// Check if a character is uppercase using simple unicode rules.
pub fn isUpperCase(c: u21) bool {
    return std.unicode.isUpper(c);
}

/// Unicode normalization (simplified - mainly handles common Latin diacritics).
pub fn normalize(c: u21) u21 {
    // Common Latin letters with diacritics -> base letter
    return switch (c) {
        // A variants
        0x00C0...0x00C5 => 'A',
        0x00E0...0x00E5 => 'a',
        // C variants
        0x00C7 => 'C',
        0x00E7 => 'c',
        // E variants
        0x00C8...0x00CB => 'E',
        0x00E8...0x00EB => 'e',
        // I variants
        0x00CC...0x00CF => 'I',
        0x00EC...0x00EF => 'i',
        // N variants
        0x00D1 => 'N',
        0x00F1 => 'n',
        // O variants
        0x00D2...0x00D6 => 'O',
        0x00F2...0x00F6 => 'o',
        // U variants
        0x00D9...0x00DC => 'U',
        0x00F9...0x00FC => 'u',
        // Y variants
        0x00DD => 'Y',
        0x00FD, 0x00FF => 'y',
        else => c,
    };
}

test "unicode classification" {
    try std.testing.expect(isLower(@as(u21, 'a')));
    try std.testing.expect(isUpper(@as(u21, 'A')));
    try std.testing.expect(isLower(@as(u21, 0x00E9)));
    try std.testing.expect(isUpper(@as(u21, 0x00C9)));
    try std.testing.expect(isLower(@as(u21, 0x03BB)));
    try std.testing.expect(isUpper(@as(u21, 0x03A9)));
    try std.testing.expect(isNumeric(@as(u21, '7')));
    try std.testing.expect(isNumeric(@as(u21, 0x0665)));
    try std.testing.expect(isWhitespace(@as(u21, ' ')));
    try std.testing.expect(isWhitespace(@as(u21, 0x3000)));
    try std.testing.expect(isAlphabetic(@as(u21, 0x4E00)));
}

test "unicode toLower" {
    try std.testing.expectEqual(@as(u21, 'a'), toLower(@as(u21, 'A')));
    try std.testing.expectEqual(@as(u21, 0x00E9), toLower(@as(u21, 0x00C9)));
    try std.testing.expectEqual(@as(u21, 0x0101), toLower(@as(u21, 0x0100)));
    try std.testing.expectEqual(@as(u21, 0x00FF), toLower(@as(u21, 0x0178)));
    try std.testing.expectEqual(@as(u21, 0x03C9), toLower(@as(u21, 0x03A9)));
}

test "unicode normalize" {
    try std.testing.expectEqual(@as(u21, 'A'), normalize(@as(u21, 0x00C1)));
    try std.testing.expectEqual(@as(u21, 'c'), normalize(@as(u21, 0x00E7)));
    try std.testing.expectEqual(@as(u21, 'y'), normalize(@as(u21, 0x00FF)));
}
