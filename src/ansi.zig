//! ANSI escape sequence parsing and handling.
//!
//! Handles CSI sequences (\x1b[...m), OSC sequences (\x1b]...), and simple escapes.

const std = @import("std");

/// Result of scanning for an ANSI escape sequence
pub const ScanResult = struct {
    /// Length of the escape sequence in bytes (0 if not a valid sequence)
    len: usize,
    /// Whether this is a valid ANSI sequence that should be passed through
    valid: bool,
};

/// Check if a byte is a valid CSI intermediate character (parameter bytes)
fn isParamByte(c: u8) bool {
    // 0-9 ; : ? are valid in CSI sequences
    return (c >= '0' and c <= '9') or c == ';' or c == ':' or c == '?';
}

/// Check if a byte is a valid CSI terminator
fn isTerminator(c: u8) bool {
    // a-z A-Z @ are valid terminators
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '@';
}

/// Scan for an ANSI escape sequence starting at the given position.
/// Returns the length of the sequence and whether it's valid.
///
/// Handles:
/// - CSI sequences: \x1b[...m (colors, cursor movement, etc.)
/// - OSC sequences: \x1b]...BEL or \x1b]...\x1b\\ (hyperlinks, window title, etc.)
/// - Simple escapes: \x1b followed by single char (e.g., \x1bM for reverse linefeed)
pub fn scanEscapeSequence(text: []const u8) ScanResult {
    if (text.len < 2 or text[0] != 0x1b) {
        return .{ .len = 0, .valid = false };
    }

    const next = text[1];

    // CSI sequence: \x1b[...
    if (next == '[') {
        var j: usize = 2;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            if (isParamByte(c)) {
                continue;
            }
            if (isTerminator(c)) {
                return .{ .len = j + 1, .valid = true };
            }
            // Invalid byte - not a valid CSI sequence
            break;
        }
        // No valid terminator found
        return .{ .len = 0, .valid = false };
    }

    // OSC sequence: \x1b]...
    if (next == ']') {
        var j: usize = 2;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            // BEL terminates OSC
            if (c == 0x07) {
                return .{ .len = j + 1, .valid = true };
            }
            // ST (\x1b\\) terminates OSC
            if (c == 0x1b and j + 1 < text.len and text[j + 1] == '\\') {
                return .{ .len = j + 2, .valid = true };
            }
        }
        // No terminator - invalid
        return .{ .len = 0, .valid = false };
    }

    // Simple escape: \x1b followed by one printable char
    // (but not newline, which should be treated as actual newline)
    if (next != '\n' and next >= 0x20) {
        return .{ .len = 2, .valid = true };
    }

    return .{ .len = 0, .valid = false };
}

/// Strip ANSI escape sequences from text, returning the visible text.
/// Allocates a new string.
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const scan = scanEscapeSequence(text[i..]);
        if (scan.valid) {
            i += scan.len;
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Count visible characters (excluding ANSI sequences) in text.
pub fn visibleLength(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const scan = scanEscapeSequence(text[i..]);
        if (scan.valid) {
            i += scan.len;
        } else {
            // Count UTF-8 codepoint
            const byte = text[i];
            const cp_len: usize = if (byte < 0x80)
                1
            else if (byte < 0xE0)
                2
            else if (byte < 0xF0)
                3
            else
                4;
            i += @min(cp_len, text.len - i);
            count += 1;
        }
    }
    return count;
}

test "CSI sequences" {
    const testing = std.testing;

    // Basic color
    const r1 = scanEscapeSequence("\x1b[31mhello");
    try testing.expectEqual(@as(usize, 5), r1.len);
    try testing.expect(r1.valid);

    // 256 color
    const r2 = scanEscapeSequence("\x1b[38;5;81mtext");
    try testing.expectEqual(@as(usize, 10), r2.len);
    try testing.expect(r2.valid);

    // True color
    const r3 = scanEscapeSequence("\x1b[38;2;255;128;0mtext");
    try testing.expectEqual(@as(usize, 17), r3.len);
    try testing.expect(r3.valid);

    // Reset
    const r4 = scanEscapeSequence("\x1b[0mtext");
    try testing.expectEqual(@as(usize, 4), r4.len);
    try testing.expect(r4.valid);

    // Invalid - no terminator
    const r5 = scanEscapeSequence("\x1b[123");
    try testing.expectEqual(@as(usize, 0), r5.len);
    try testing.expect(!r5.valid);

    // Invalid - bad intermediate
    const r6 = scanEscapeSequence("\x1b[12#3m");
    try testing.expectEqual(@as(usize, 0), r6.len);
    try testing.expect(!r6.valid);
}

test "OSC sequences" {
    const testing = std.testing;

    // Hyperlink with BEL terminator
    const r1 = scanEscapeSequence("\x1b]8;;https://example.com\x07text");
    try testing.expectEqual(@as(usize, 25), r1.len);
    try testing.expect(r1.valid);

    // OSC with ST terminator
    const r2 = scanEscapeSequence("\x1b]0;title\x1b\\rest");
    try testing.expectEqual(@as(usize, 10), r2.len);
    try testing.expect(r2.valid);
}

test "simple escapes" {
    const testing = std.testing;

    // Reverse linefeed
    const r1 = scanEscapeSequence("\x1bMtext");
    try testing.expectEqual(@as(usize, 2), r1.len);
    try testing.expect(r1.valid);

    // Not an escape - newline after ESC
    const r2 = scanEscapeSequence("\x1b\ntext");
    try testing.expectEqual(@as(usize, 0), r2.len);
    try testing.expect(!r2.valid);
}

test "strip ansi" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try stripAnsi(allocator, "\x1b[38;5;81mhello\x1b[0m world");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "visible length" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 11), visibleLength("\x1b[31mhello\x1b[0m world"));
    try testing.expectEqual(@as(usize, 5), visibleLength("hello"));
    try testing.expectEqual(@as(usize, 0), visibleLength("\x1b[0m"));
}
