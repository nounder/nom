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

/// Find ASCII character, ignoring case for lowercase letters
fn findAsciiIgnoreCase(c: u8, haystack: []const u8) ?usize {
    if (c >= 'a' and c <= 'z') {
        // Search for both lowercase and uppercase
        const upper = c - 32;
        for (haystack, 0..) |h, i| {
            if (h == c or h == upper) return i;
        }
        return null;
    } else {
        return std.mem.indexOfScalar(u8, haystack, c);
    }
}

/// Find ASCII character from end, ignoring case
fn findAsciiIgnoreCaseRev(c: u8, haystack: []const u8) ?usize {
    if (c >= 'a' and c <= 'z') {
        const upper = c - 32;
        var i = haystack.len;
        while (i > 0) {
            i -= 1;
            if (haystack[i] == c or haystack[i] == upper) return i + 1;
        }
        return null;
    } else {
        return if (std.mem.lastIndexOfScalar(u8, haystack, c)) |idx| idx + 1 else null;
    }
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
