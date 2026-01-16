//! Character classification and handling utilities.
//!
//! This module provides character classification for scoring purposes and
//! character normalization (case folding, unicode normalization).

const std = @import("std");
const Config = @import("config.zig").Config;
const unicode = @import("unicode.zig");

/// Character class used for scoring bonuses
pub const CharClass = enum(u3) {
    whitespace,
    non_word,
    delimiter,
    lower,
    upper,
    letter,
    number,

    /// Check if this character class represents a word character
    pub fn isWord(self: CharClass) bool {
        return @intFromEnum(self) > @intFromEnum(CharClass.delimiter);
    }
};

/// Trait-like interface for character operations
pub fn Char(comptime T: type) type {
    return struct {
        pub const is_ascii = T == u8;

        /// Get the character class of this character
        pub fn charClass(c: T, config: *const Config) CharClass {
            if (T == u8) {
                return asciiCharClass(c, config);
            } else {
                if (c < 128) {
                    return asciiCharClass(@intCast(c), config);
                }
                return unicodeCharClass(c);
            }
        }

        /// Get both the normalized character and its class
        pub fn charClassAndNormalize(c: T, config: *const Config) struct { char: T, class: CharClass } {
            if (T == u8) {
                const class = asciiCharClass(c, config);
                var normalized = c;
                if (config.ignore_case and class == .upper) {
                    normalized +|= 32;
                }
                return .{ .char = normalized, .class = class };
            } else {
                if (c < 128) {
                    const result = Char(u8).charClassAndNormalize(@intCast(c), config);
                    return .{ .char = result.char, .class = result.class };
                }
                const class = unicodeCharClass(c);
                var normalized = c;
                if (config.normalize) {
                    normalized = unicode.normalize(normalized);
                }
                if (config.ignore_case) {
                    normalized = unicode.toLower(normalized);
                }
                return .{ .char = normalized, .class = class };
            }
        }

        /// Normalize a character (case folding + unicode normalization)
        pub fn normalize(c: T, config: *const Config) T {
            if (T == u8) {
                if (config.ignore_case and c >= 'A' and c <= 'Z') {
                    return c + 32;
                }
                return c;
            } else {
                var result = c;
                if (config.normalize) {
                    result = unicode.normalize(result);
                }
                if (config.ignore_case) {
                    result = unicode.toLower(result);
                }
                return result;
            }
        }
    };
}

/// Wrapper type for ASCII characters with additional functionality
pub const AsciiChar = struct {
    value: u8,

    pub fn init(c: u8) AsciiChar {
        return .{ .value = c };
    }

    pub fn charClass(self: AsciiChar, config: *const Config) CharClass {
        return asciiCharClass(self.value, config);
    }

    pub fn charClassAndNormalize(self: AsciiChar, config: *const Config) struct { char: u8, class: CharClass } {
        return Char(u8).charClassAndNormalize(self.value, config);
    }

    pub fn normalize(self: AsciiChar, config: *const Config) u8 {
        return Char(u8).normalize(self.value, config);
    }

    pub fn eql(self: AsciiChar, other: anytype) bool {
        const T = @TypeOf(other);
        if (T == AsciiChar) {
            return self.value == other.value;
        } else if (T == u8) {
            return self.value == other;
        } else if (T == u21 or T == u32) {
            return self.value == other;
        }
        return false;
    }
};

fn asciiCharClass(c: u8, config: *const Config) CharClass {
    if (c >= 'a' and c <= 'z') {
        return .lower;
    } else if (c >= 'A' and c <= 'Z') {
        return .upper;
    } else if (c >= '0' and c <= '9') {
        return .number;
    } else if (std.ascii.isWhitespace(c)) {
        return .whitespace;
    } else if (isDelimiter(c, config)) {
        return .delimiter;
    } else {
        return .non_word;
    }
}

fn isDelimiter(c: u8, config: *const Config) bool {
    for (config.delimiter_chars) |d| {
        if (c == d) return true;
    }
    return false;
}

fn unicodeCharClass(c: u21) CharClass {
    // Check if it's a lowercase letter
    if (unicode.isLower(c)) {
        return .lower;
    }
    // Check if it's uppercase
    if (unicode.isUpper(c)) {
        return .upper;
    }
    // Check numeric
    if (unicode.isNumeric(c)) {
        return .number;
    }
    // Check alphabetic (but not upper/lower - e.g., titlecase, modifier letters)
    if (unicode.isAlphabetic(c)) {
        return .letter;
    }
    // Check whitespace
    if (unicode.isWhitespace(c)) {
        return .whitespace;
    }
    return .non_word;
}


/// Iterator over graphemes in a string
/// For simplicity, this iterates over codepoints (full grapheme clustering would need more tables)
pub fn graphemes(text: []const u8) GraphemeIterator {
    return GraphemeIterator.init(text);
}

pub const GraphemeIterator = struct {
    bytes: []const u8,
    index: usize,

    pub fn init(bytes: []const u8) GraphemeIterator {
        return .{ .bytes = bytes, .index = 0 };
    }

    pub fn next(self: *GraphemeIterator) ?u21 {
        if (self.index >= self.bytes.len) return null;

        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.index]) catch return null;
        if (self.index + len > self.bytes.len) return null;

        const codepoint = std.unicode.utf8Decode(self.bytes[self.index..][0..len]) catch return null;
        self.index += len;

        // Handle \r\n as a single grapheme (maps to \n)
        if (codepoint == '\r' and self.index < self.bytes.len and self.bytes[self.index] == '\n') {
            self.index += 1;
            return '\n';
        }

        return codepoint;
    }

    pub fn reset(self: *GraphemeIterator) void {
        self.index = 0;
    }
};

test "ascii char class" {
    const config = Config.default();
    try std.testing.expectEqual(CharClass.lower, asciiCharClass('a', &config));
    try std.testing.expectEqual(CharClass.upper, asciiCharClass('A', &config));
    try std.testing.expectEqual(CharClass.number, asciiCharClass('5', &config));
    try std.testing.expectEqual(CharClass.whitespace, asciiCharClass(' ', &config));
    try std.testing.expectEqual(CharClass.delimiter, asciiCharClass('/', &config));
    try std.testing.expectEqual(CharClass.non_word, asciiCharClass('-', &config));
}

test "ascii normalization" {
    const config = Config.default();
    try std.testing.expectEqual(@as(u8, 'a'), Char(u8).normalize('A', &config));
    try std.testing.expectEqual(@as(u8, 'a'), Char(u8).normalize('a', &config));
    try std.testing.expectEqual(@as(u8, '5'), Char(u8).normalize('5', &config));
}

test "grapheme iterator" {
    var iter = graphemes("hello");
    try std.testing.expectEqual(@as(u21, 'h'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 'e'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 'l'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 'l'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 'o'), iter.next().?);
    try std.testing.expectEqual(@as(?u21, null), iter.next());
}

test "grapheme iterator unicode" {
    var iter = graphemes("héllo");
    try std.testing.expectEqual(@as(u21, 'h'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 0x00E9), iter.next().?); // é
    try std.testing.expectEqual(@as(u21, 'l'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 'l'), iter.next().?);
    try std.testing.expectEqual(@as(u21, 'o'), iter.next().?);
    try std.testing.expectEqual(@as(?u21, null), iter.next());
}
