//! UTF-32 encoded string types for efficient fuzzy matching.
//!
//! These types provide efficient iteration over codepoints without repeatedly
//! decoding UTF-8. The ASCII variant provides a fast path for ASCII-only text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chars = @import("chars.zig");
const unicode = @import("unicode.zig");

/// A UTF-32 encoded string slice used as input to fuzzy matching.
///
/// This type efficiently represents text for matching by separating ASCII
/// (stored as bytes) from Unicode (stored as codepoints).
pub const Utf32Str = union(enum) {
    /// A string represented as ASCII encoded bytes.
    ascii: []const u8,
    /// A string represented as an array of unicode codepoints.
    unicode: []const u21,

    /// Create a Utf32Str from a UTF-8 string, using the provided buffer for Unicode storage.
    pub fn init(str: []const u8, allocator: Allocator, buf: *std.ArrayListUnmanaged(u21)) Utf32Str {
        if (hasAsciiGraphemes(str)) {
            return .{ .ascii = str };
        } else {
            buf.clearRetainingCapacity();
            var iter = chars.graphemes(str);
            while (iter.next()) |c| {
                buf.append(allocator, c) catch unreachable;
            }
            return .{ .unicode = buf.items };
        }
    }

    /// Returns the number of characters in this string.
    pub fn len(self: Utf32Str) usize {
        return switch (self) {
            .ascii => |bytes| bytes.len,
            .unicode => |codepoints| codepoints.len,
        };
    }

    /// Returns whether this string is empty.
    pub fn isEmpty(self: Utf32Str) bool {
        return self.len() == 0;
    }

    /// Returns whether this string only contains ASCII characters.
    pub fn isAscii(self: Utf32Str) bool {
        return self == .ascii;
    }

    /// Get the character at index n (zero-indexed)
    pub fn get(self: Utf32Str, n: usize) u21 {
        return switch (self) {
            .ascii => |bytes| bytes[n],
            .unicode => |codepoints| codepoints[n],
        };
    }

    /// Returns the first character in this string.
    /// Panics if the string is empty.
    pub fn first(self: Utf32Str) u21 {
        return self.get(0);
    }

    /// Returns the last character in this string.
    /// Panics if the string is empty.
    pub fn last(self: Utf32Str) u21 {
        return self.get(self.len() - 1);
    }

    /// Creates a slice with a string that contains the characters in the specified range.
    pub fn slice(self: Utf32Str, start: usize, end: usize) Utf32Str {
        return switch (self) {
            .ascii => |bytes| .{ .ascii = bytes[start..end] },
            .unicode => |codepoints| .{ .unicode = codepoints[start..end] },
        };
    }

    /// Slice from start to end of string
    pub fn sliceFrom(self: Utf32Str, start: usize) Utf32Str {
        return self.slice(start, self.len());
    }

    /// Slice from beginning to end position
    pub fn sliceTo(self: Utf32Str, end: usize) Utf32Str {
        return self.slice(0, end);
    }

    /// Returns the number of leading whitespaces in this string
    pub fn leadingWhiteSpace(self: Utf32Str) usize {
        switch (self) {
            .ascii => |bytes| {
                for (bytes, 0..) |b, i| {
                    if (!std.ascii.isWhitespace(b)) return i;
                }
                return 0;
            },
            .unicode => |codepoints| {
                for (codepoints, 0..) |c, i| {
                    if (!unicode.isWhitespace(c)) return i;
                }
                return 0;
            },
        }
    }

    /// Returns the number of trailing whitespaces in this string
    pub fn trailingWhiteSpace(self: Utf32Str) usize {
        switch (self) {
            .ascii => |bytes| {
                var count: usize = 0;
                var i = bytes.len;
                while (i > 0) {
                    i -= 1;
                    if (!std.ascii.isWhitespace(bytes[i])) break;
                    count += 1;
                }
                return count;
            },
            .unicode => |codepoints| {
                var count: usize = 0;
                var i = codepoints.len;
                while (i > 0) {
                    i -= 1;
                    if (!unicode.isWhitespace(codepoints[i])) break;
                    count += 1;
                }
                return count;
            },
        }
    }

    /// Returns an iterator over the characters in this string
    pub fn iterator(self: Utf32Str) CharIterator {
        return CharIterator.init(self);
    }
};

/// An owned version of Utf32Str.
pub const Utf32String = struct {
    data: union(enum) {
        ascii: []u8,
        unicode: []u21,
    },
    allocator: Allocator,

    /// Create from a UTF-8 string
    pub fn init(allocator: Allocator, str: []const u8) !Utf32String {
        if (hasAsciiGraphemes(str)) {
            const data = try allocator.dupe(u8, str);
            return .{
                .data = .{ .ascii = data },
                .allocator = allocator,
            };
        } else {
            var codepoints: std.ArrayListUnmanaged(u21) = .empty;
            var iter = chars.graphemes(str);
            while (iter.next()) |c| {
                try codepoints.append(allocator, c);
            }
            return .{
                .data = .{ .unicode = try codepoints.toOwnedSlice(allocator) },
                .allocator = allocator,
            };
        }
    }

    pub fn deinit(self: *Utf32String) void {
        switch (self.data) {
            .ascii => |bytes| self.allocator.free(bytes),
            .unicode => |codepoints| self.allocator.free(codepoints),
        }
    }

    /// Returns the number of characters in this string.
    pub fn len(self: *const Utf32String) usize {
        return switch (self.data) {
            .ascii => |bytes| bytes.len,
            .unicode => |codepoints| codepoints.len,
        };
    }

    /// Returns whether this string is empty.
    pub fn isEmpty(self: *const Utf32String) bool {
        return self.len() == 0;
    }

    /// Get a slice view of this string
    pub fn toSlice(self: *const Utf32String) Utf32Str {
        return switch (self.data) {
            .ascii => |bytes| .{ .ascii = bytes },
            .unicode => |codepoints| .{ .unicode = codepoints },
        };
    }

    /// Creates a slice with characters in the specified range.
    pub fn slice(self: *const Utf32String, start: usize, end: usize) Utf32Str {
        return self.toSlice().slice(start, end);
    }
};

/// Iterator over characters in a Utf32Str
pub const CharIterator = struct {
    str: Utf32Str,
    index: usize,

    pub fn init(str: Utf32Str) CharIterator {
        return .{ .str = str, .index = 0 };
    }

    pub fn next(self: *CharIterator) ?u21 {
        if (self.index >= self.str.len()) return null;
        const c = self.str.get(self.index);
        self.index += 1;
        return c;
    }

    pub fn nextBack(self: *CharIterator) ?u21 {
        if (self.index >= self.str.len()) return null;
        const c = self.str.get(self.str.len() - 1 - self.index);
        self.index += 1;
        return c;
    }

    pub fn reset(self: *CharIterator) void {
        self.index = 0;
    }
};

/// Check if a string can be represented as ASCII.
/// Returns true if the string is ASCII and does not contain \r\n (which is a single grapheme).
fn hasAsciiGraphemes(str: []const u8) bool {
    for (str) |c| {
        if (c >= 128) return false;
    }
    // Check for \r\n which is a single grapheme
    return std.mem.indexOf(u8, str, "\r\n") == null;
}

test "ascii string" {
    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const str = Utf32Str.init("hello", std.testing.allocator, &buf);
    try std.testing.expect(str.isAscii());
    try std.testing.expectEqual(@as(usize, 5), str.len());
    try std.testing.expectEqual(@as(u21, 'h'), str.get(0));
    try std.testing.expectEqual(@as(u21, 'o'), str.last());
}

test "unicode string" {
    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const str = Utf32Str.init("héllo", std.testing.allocator, &buf);
    try std.testing.expect(!str.isAscii());
    try std.testing.expectEqual(@as(usize, 5), str.len());
    try std.testing.expectEqual(@as(u21, 'h'), str.get(0));
    try std.testing.expectEqual(@as(u21, 0x00E9), str.get(1)); // é
}

test "string slicing" {
    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const str = Utf32Str.init("hello world", std.testing.allocator, &buf);
    const slice1 = str.slice(0, 5);
    try std.testing.expectEqual(@as(usize, 5), slice1.len());
    try std.testing.expectEqual(@as(u21, 'h'), slice1.first());
    try std.testing.expectEqual(@as(u21, 'o'), slice1.last());
}

test "owned string" {
    var str = try Utf32String.init(std.testing.allocator, "hello");
    defer str.deinit();

    try std.testing.expectEqual(@as(usize, 5), str.len());
    const slice1 = str.toSlice();
    try std.testing.expectEqual(@as(u21, 'h'), slice1.first());
}

test "whitespace detection" {
    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const str = Utf32Str.init("  hello  ", std.testing.allocator, &buf);
    try std.testing.expectEqual(@as(usize, 2), str.leadingWhiteSpace());
    try std.testing.expectEqual(@as(usize, 2), str.trailingWhiteSpace());
}
