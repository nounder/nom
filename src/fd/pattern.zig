//! Pattern matching for fd-zig.
//!
//! Supports three pattern types:
//! - glob: Shell-style glob patterns (*, **, ?, [...])
//! - fixed: Literal substring matching
//! - regex: Basic regular expression matching

const std = @import("std");

pub const PatternKind = enum {
    glob,
    fixed,
    regex,
};

pub const PatternOptions = struct {
    case_sensitive: bool = true,
    full_path: bool = false,
};

pub const Pattern = struct {
    allocator: std.mem.Allocator,
    kind: PatternKind,
    case_sensitive: bool,
    full_path: bool,
    pattern: []const u8,
    lowercase_pattern: ?[]u8, // For case-insensitive matching

    pub fn init(allocator: std.mem.Allocator, pat: []const u8, kind: PatternKind, options: PatternOptions) !Pattern {
        var lowercase: ?[]u8 = null;
        if (!options.case_sensitive) {
            lowercase = try allocator.alloc(u8, pat.len);
            for (pat, 0..) |c, i| {
                lowercase.?[i] = std.ascii.toLower(c);
            }
        }

        return .{
            .allocator = allocator,
            .kind = kind,
            .case_sensitive = options.case_sensitive,
            .full_path = options.full_path,
            .pattern = pat,
            .lowercase_pattern = lowercase,
        };
    }

    pub fn deinit(self: *Pattern, allocator: std.mem.Allocator) void {
        _ = self.allocator;
        if (self.lowercase_pattern) |lp| {
            allocator.free(lp);
        }
    }

    pub fn matches(self: *const Pattern, text: []const u8) bool {
        const pat = if (self.case_sensitive) self.pattern else self.lowercase_pattern.?;

        return switch (self.kind) {
            .glob => self.globMatches(pat, text),
            .fixed => self.fixedMatches(pat, text),
            .regex => self.regexMatches(pat, text),
        };
    }

    fn globMatches(self: *const Pattern, pat: []const u8, text: []const u8) bool {
        if (self.case_sensitive) {
            return globMatch(pat, text);
        } else {
            // For case-insensitive, we need to lowercase the text temporarily
            var buf: [4096]u8 = undefined;
            if (text.len > buf.len) return false;
            for (text, 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            return globMatch(pat, buf[0..text.len]);
        }
    }

    fn fixedMatches(self: *const Pattern, pat: []const u8, text: []const u8) bool {
        if (self.case_sensitive) {
            return std.mem.indexOf(u8, text, pat) != null;
        } else {
            // Case-insensitive substring search
            var buf: [4096]u8 = undefined;
            if (text.len > buf.len) return false;
            for (text, 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            return std.mem.indexOf(u8, buf[0..text.len], pat) != null;
        }
    }

    fn regexMatches(self: *const Pattern, pat: []const u8, text: []const u8) bool {
        // For now, treat regex as glob
        // A full regex implementation is complex; this provides basic compatibility
        return self.globMatches(pat, text);
    }
};

/// Glob matching optimized for gitignore/fd patterns.
/// Supports: * (any non-slash), ** (any including slashes), ? (single non-slash), [...] (char class)
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;

    // For backtracking on * matches
    var star_pi: usize = 0;
    var star_ti: usize = 0;
    var has_star = false;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];

            // Check for **
            if (pc == '*' and pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                // ** matches everything including /
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                if (pi >= pattern.len) return true; // ** at end matches all

                // Try matching rest at every position
                while (ti <= text.len) {
                    if (globMatch(pattern[pi..], text[ti..])) return true;
                    if (ti < text.len) ti += 1 else break;
                }
                return false;
            }

            // Single *
            if (pc == '*') {
                star_pi = pi;
                star_ti = ti;
                has_star = true;
                pi += 1;
                continue;
            }

            // ?
            if (pc == '?') {
                if (ti < text.len and text[ti] != '/') {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            } else if (pc == '[') {
                // Character class
                if (ti < text.len) {
                    const tc = text[ti];
                    if (std.mem.indexOfScalarPos(u8, pattern, pi + 1, ']')) |end| {
                        const class = pattern[pi + 1 .. end];
                        if (matchCharClass(class, tc)) {
                            pi = end + 1;
                            ti += 1;
                            continue;
                        }
                    }
                }
            } else if (ti < text.len and pc == text[ti]) {
                // Literal match
                pi += 1;
                ti += 1;
                continue;
            }
        }

        // No match - backtrack if we had a *
        if (has_star and star_ti < text.len and text[star_ti] != '/') {
            star_ti += 1;
            ti = star_ti;
            pi = star_pi + 1;
            continue;
        }

        return false;
    }

    return true;
}

fn matchCharClass(class: []const u8, c: u8) bool {
    var i: usize = 0;
    var negated = false;

    if (i < class.len and (class[i] == '!' or class[i] == '^')) {
        negated = true;
        i += 1;
    }

    var matched = false;
    while (i < class.len) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (c >= class[i] and c <= class[i + 2]) matched = true;
            i += 3;
        } else {
            if (c == class[i]) matched = true;
            i += 1;
        }
    }

    return if (negated) !matched else matched;
}

test "globMatch basic" {
    try std.testing.expect(globMatch("foo", "foo"));
    try std.testing.expect(!globMatch("foo", "bar"));
    try std.testing.expect(!globMatch("foo", "foobar"));
}

test "globMatch wildcards" {
    // Single * wildcard
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("foo*", "foobar"));
    try std.testing.expect(globMatch("*bar", "foobar"));
    try std.testing.expect(globMatch("*", "anything"));

    // ** wildcard
    try std.testing.expect(globMatch("**/*.txt", "file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "a/b/c/file.txt"));
    try std.testing.expect(globMatch("src/**", "src/main.zig"));
    try std.testing.expect(globMatch("src/**", "src/foo/bar.zig"));
}

test "globMatch question mark" {
    try std.testing.expect(globMatch("?.txt", "a.txt"));
    try std.testing.expect(!globMatch("?.txt", "ab.txt"));
    try std.testing.expect(globMatch("?oo", "foo"));
    try std.testing.expect(globMatch("?oo", "boo"));
}

test "globMatch character class" {
    try std.testing.expect(globMatch("[abc]", "a"));
    try std.testing.expect(globMatch("[abc]", "b"));
    try std.testing.expect(!globMatch("[abc]", "d"));
    try std.testing.expect(globMatch("[a-z]", "m"));
    try std.testing.expect(!globMatch("[a-z]", "A"));
    try std.testing.expect(globMatch("[!a-z]", "A"));
}

test "Pattern fixed" {
    const allocator = std.testing.allocator;

    var p = try Pattern.init(allocator, "test", .fixed, .{ .case_sensitive = true });
    defer p.deinit(allocator);

    try std.testing.expect(p.matches("test"));
    try std.testing.expect(p.matches("testing"));
    try std.testing.expect(p.matches("a_test_file"));
    try std.testing.expect(!p.matches("TEST"));
}

test "Pattern fixed case insensitive" {
    const allocator = std.testing.allocator;

    var p = try Pattern.init(allocator, "test", .fixed, .{ .case_sensitive = false });
    defer p.deinit(allocator);

    try std.testing.expect(p.matches("test"));
    try std.testing.expect(p.matches("TEST"));
    try std.testing.expect(p.matches("TeSt"));
    try std.testing.expect(p.matches("Testing"));
}

test "Pattern glob" {
    const allocator = std.testing.allocator;

    var p = try Pattern.init(allocator, "*.zig", .glob, .{ .case_sensitive = true });
    defer p.deinit(allocator);

    try std.testing.expect(p.matches("main.zig"));
    try std.testing.expect(p.matches("test.zig"));
    try std.testing.expect(!p.matches("main.rs"));
    try std.testing.expect(!p.matches("dir/main.zig"));
}
