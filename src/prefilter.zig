//! Prefilter for fast rejection of non-matches.
//!
//! The prefilter uses memchr-style byte scanning to quickly find potential
//! match regions before running the more expensive DP algorithm.

const std = @import("std");
const Config = @import("config.zig").Config;
const Char = @import("chars.zig").Char;
const Utf32Str = @import("utf32_str.zig").Utf32Str;

/// Result of ASCII prefiltering
pub const PrefilterResult = struct {
    /// Start position of first needle character
    start: usize,
    /// End position of greedy match (all needle chars found)
    greedy_end: usize,
    /// End position of last needle character's last occurrence
    end: usize,
};

/// Prefilter for ASCII haystack and needle
pub fn prefilterAscii(
    config: *const Config,
    haystack: []const u8,
    needle: []const u8,
    only_greedy: bool,
) ?PrefilterResult {
    if (needle.len > haystack.len) return null;

    if (config.ignore_case) {
        return prefilterAsciiIgnoreCase(haystack, needle, only_greedy);
    } else {
        return prefilterAsciiExact(haystack, needle, only_greedy);
    }
}

fn prefilterAsciiIgnoreCase(
    haystack: []const u8,
    needle: []const u8,
    only_greedy: bool,
) ?PrefilterResult {
    // Find first character
    const search_end = haystack.len - needle.len + 1;
    const start = findAsciiIgnoreCase(needle[0], haystack[0..search_end]) orelse return null;

    // Greedy forward match
    var greedy_end = start + 1;
    var remaining = haystack[greedy_end..];

    for (needle[1..]) |c| {
        const idx = findAsciiIgnoreCase(c, remaining) orelse return null;
        greedy_end += idx + 1;
        remaining = haystack[greedy_end..];
    }

    if (only_greedy) {
        return .{ .start = start, .greedy_end = greedy_end, .end = greedy_end };
    }

    // Find last occurrence of last needle char
    const end = greedy_end +
        (findAsciiIgnoreCaseRev(needle[needle.len - 1], remaining) orelse 0);

    return .{ .start = start, .greedy_end = greedy_end, .end = end };
}

fn prefilterAsciiExact(
    haystack: []const u8,
    needle: []const u8,
    only_greedy: bool,
) ?PrefilterResult {
    const search_end = haystack.len - needle.len + 1;
    const start = std.mem.indexOfScalar(u8, haystack[0..search_end], needle[0]) orelse return null;

    var greedy_end = start + 1;
    var remaining = haystack[greedy_end..];

    for (needle[1..]) |c| {
        const idx = std.mem.indexOfScalar(u8, remaining, c) orelse return null;
        greedy_end += idx + 1;
        remaining = haystack[greedy_end..];
    }

    if (only_greedy) {
        return .{ .start = start, .greedy_end = greedy_end, .end = greedy_end };
    }

    const end = greedy_end +
        (std.mem.lastIndexOfScalar(u8, remaining, needle[needle.len - 1]) orelse 0);

    return .{ .start = start, .greedy_end = greedy_end, .end = end };
}

/// Find ASCII character, ignoring case for lowercase letters.
/// Uses SIMD to search for both lowercase and uppercase variants simultaneously.
fn findAsciiIgnoreCase(c: u8, haystack: []const u8) ?usize {
    if (c >= 'a' and c <= 'z') {
        const upper = c - 32;
        return findAsciiIgnoreCaseSimd(c, upper, haystack);
    } else {
        return std.mem.indexOfScalar(u8, haystack, c);
    }
}

/// SIMD implementation for case-insensitive character search.
/// Searches for both lowercase `c` and uppercase `upper` simultaneously.
/// Uses 8-byte vectors for short strings, 16-byte vectors for longer ones.
fn findAsciiIgnoreCaseSimd(c: u8, upper: u8, haystack: []const u8) ?usize {
    // Fast path: use 8-byte SIMD for short strings
    if (haystack.len <= 8) {
        if (haystack.len == 8) {
            const Vec8 = @Vector(8, u8);
            const chunk: Vec8 = haystack[0..8].*;
            const lower_match = chunk == @as(Vec8, @splat(c));
            const upper_match = chunk == @as(Vec8, @splat(upper));
            const any_match = @select(bool, lower_match, lower_match, upper_match);
            const mask: u8 = @bitCast(any_match);
            if (mask != 0) return @ctz(mask);
            return null;
        }
        for (haystack, 0..) |h, j| {
            if (h == c or h == upper) return j;
        }
        return null;
    }

    const Vec = @Vector(16, u8);
    const lower_vec: Vec = @splat(c);
    const upper_vec: Vec = @splat(upper);

    var i: usize = 0;

    // Process 16 bytes at a time with SIMD
    while (i + 16 <= haystack.len) {
        const chunk: Vec = haystack[i..][0..16].*;

        // Check for matches against both lowercase and uppercase
        const lower_match = chunk == lower_vec;
        const upper_match = chunk == upper_vec;

        // Combine matches: true if either lowercase or uppercase matches
        const any_match = @select(bool, lower_match, lower_match, upper_match);

        // Convert bool vector to bitmask and find first set bit
        const mask: u16 = @bitCast(any_match);
        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += 16;
    }

    // Handle remaining bytes with scalar code
    for (haystack[i..], i..) |h, j| {
        if (h == c or h == upper) return j;
    }

    return null;
}

/// Find ASCII character from end, ignoring case.
/// Uses SIMD to search for both lowercase and uppercase variants simultaneously.
/// Returns index + 1 (position after the found character) or null if not found.
fn findAsciiIgnoreCaseRev(c: u8, haystack: []const u8) ?usize {
    if (c >= 'a' and c <= 'z') {
        const upper = c - 32;
        return findAsciiIgnoreCaseRevSimd(c, upper, haystack);
    } else {
        return if (std.mem.lastIndexOfScalar(u8, haystack, c)) |idx| idx + 1 else null;
    }
}

/// SIMD implementation for reverse case-insensitive character search.
/// Searches from the end for both lowercase `c` and uppercase `upper`.
/// Uses 8-byte vectors for short strings, 16-byte vectors for longer ones.
/// Returns index + 1 (position after the found character) or null if not found.
fn findAsciiIgnoreCaseRevSimd(c: u8, upper: u8, haystack: []const u8) ?usize {
    // Fast path: use 8-byte SIMD for short strings
    if (haystack.len <= 8) {
        if (haystack.len == 8) {
            const Vec8 = @Vector(8, u8);
            const chunk: Vec8 = haystack[0..8].*;
            const lower_match = chunk == @as(Vec8, @splat(c));
            const upper_match = chunk == @as(Vec8, @splat(upper));
            const any_match = @select(bool, lower_match, lower_match, upper_match);
            const mask: u8 = @bitCast(any_match);
            if (mask != 0) {
                const highest_bit = 7 - @clz(mask);
                return highest_bit + 1;
            }
            return null;
        }
        var i = haystack.len;
        while (i > 0) {
            i -= 1;
            if (haystack[i] == c or haystack[i] == upper) return i + 1;
        }
        return null;
    }

    const Vec = @Vector(16, u8);
    const lower_vec: Vec = @splat(c);
    const upper_vec: Vec = @splat(upper);

    var i: usize = haystack.len;

    // Process 16 bytes at a time from the end with SIMD
    while (i >= 16) {
        const start = i - 16;
        const chunk: Vec = haystack[start..][0..16].*;

        // Check for matches against both lowercase and uppercase
        const lower_match = chunk == lower_vec;
        const upper_match = chunk == upper_vec;

        // Combine matches: true if either lowercase or uppercase matches
        const any_match = @select(bool, lower_match, lower_match, upper_match);

        // Convert bool vector to bitmask
        const mask: u16 = @bitCast(any_match);
        if (mask != 0) {
            // Find the highest set bit (last match in this chunk)
            const highest_bit = 15 - @clz(mask);
            return start + highest_bit + 1;
        }

        i -= 16;
    }

    // Handle remaining bytes at the beginning with scalar code
    while (i > 0) {
        i -= 1;
        if (haystack[i] == c or haystack[i] == upper) return i + 1;
    }

    return null;
}

/// Prefilter result for non-ASCII
pub const PrefilterNonAsciiResult = struct {
    start: usize,
    end: usize,
};

/// Prefilter for non-ASCII haystack
pub fn prefilterNonAscii(
    config: *const Config,
    haystack: []const u21,
    needle: Utf32Str,
    only_greedy: bool,
) ?PrefilterNonAsciiResult {
    const needle_char = needle.get(0);
    const search_end = haystack.len - needle.len() + 1;

    // Find first occurrence of first needle char
    var start: ?usize = null;
    for (haystack[0..search_end], 0..) |c, i| {
        if (Char(u21).normalize(c, config) == needle_char) {
            start = i;
            break;
        }
    }
    const start_pos = start orelse return null;

    const last_needle_char = needle.last();

    if (only_greedy) {
        if (haystack.len - start_pos < needle.len()) {
            return null;
        }
        return .{ .start = start_pos, .end = start_pos + 1 };
    }

    // Find last occurrence of last needle char
    var end: ?usize = null;
    var i = haystack.len;
    while (i > start_pos + 1) {
        i -= 1;
        if (Char(u21).normalize(haystack[i], config) == last_needle_char) {
            end = i + 1;
            break;
        }
    }
    const end_pos = end orelse return null;

    if (end_pos - start_pos < needle.len()) {
        return null;
    }

    return .{ .start = start_pos, .end = end_pos };
}

test "prefilter ascii exact" {
    var config = Config.default();
    config.ignore_case = false;

    const result = prefilterAscii(&config, "hello world", "hlo", false);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 5), result.?.greedy_end); // h(0) + e l(3,4) + l o(4,5)
}

test "prefilter ascii ignore case" {
    const config = Config.default();

    const result = prefilterAscii(&config, "Hello World", "hlo", false);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "prefilter ascii no match" {
    const config = Config.default();

    const result = prefilterAscii(&config, "hello", "xyz", false);
    try std.testing.expect(result == null);
}

test "prefilter ascii greedy only" {
    const config = Config.default();

    const result = prefilterAscii(&config, "hello world", "hlo", true);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.greedy_end, result.?.end);
}

test "findAsciiIgnoreCase SIMD" {
    // Test forward search
    try std.testing.expectEqual(@as(?usize, 0), findAsciiIgnoreCase('h', "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findAsciiIgnoreCase('h', "Hello"));
    try std.testing.expectEqual(@as(?usize, 4), findAsciiIgnoreCase('o', "hello"));
    try std.testing.expectEqual(@as(?usize, 4), findAsciiIgnoreCase('o', "hellO"));
    try std.testing.expectEqual(@as(?usize, null), findAsciiIgnoreCase('x', "hello"));

    // Test with longer strings (exercises SIMD path)
    const long_str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX";
    try std.testing.expectEqual(@as(?usize, 32), findAsciiIgnoreCase('x', long_str));

    const long_upper = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAХ"; // note: last char is Cyrillic
    try std.testing.expectEqual(@as(?usize, 0), findAsciiIgnoreCase('a', long_upper));
}

test "findAsciiIgnoreCaseRev SIMD" {
    // Test reverse search - returns index + 1
    try std.testing.expectEqual(@as(?usize, 1), findAsciiIgnoreCaseRev('h', "hello"));
    try std.testing.expectEqual(@as(?usize, 1), findAsciiIgnoreCaseRev('h', "Hello"));
    try std.testing.expectEqual(@as(?usize, 5), findAsciiIgnoreCaseRev('o', "hello"));
    try std.testing.expectEqual(@as(?usize, 5), findAsciiIgnoreCaseRev('o', "hellO"));
    try std.testing.expectEqual(@as(?usize, null), findAsciiIgnoreCaseRev('x', "hello"));

    // Test finding last occurrence - "hello all" has 'l' at indices 2,3,8, returns 8+1=9
    try std.testing.expectEqual(@as(?usize, 9), findAsciiIgnoreCaseRev('l', "hello all"));

    // Test with longer strings (exercises SIMD path)
    const long_str = "Xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectEqual(@as(?usize, 1), findAsciiIgnoreCaseRev('x', long_str));

    // Multiple matches - should find the last one
    const multi = "aXaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX";
    try std.testing.expectEqual(@as(?usize, 34), findAsciiIgnoreCaseRev('x', multi));
}
