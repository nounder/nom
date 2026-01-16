//! Higher-level pattern API for fuzzy matching.
//!
//! This module provides the Pattern and Atom types which handle parsing
//! of fzf-style patterns with special syntax for different match types.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Matcher = @import("matcher.zig").Matcher;
const Utf32Str = @import("utf32_str.zig").Utf32Str;
const Utf32String = @import("utf32_str.zig").Utf32String;
const chars = @import("chars.zig");

/// How to treat case mismatches between characters
pub const CaseMatching = enum {
    /// Characters never match their case folded version (a != A)
    respect,
    /// Characters always match their case folded version (a == A)
    ignore,
    /// Acts like ignore if all characters in pattern are lowercase,
    /// otherwise acts like respect (smart-case)
    smart,
};

/// How to handle unicode normalization
pub const Normalization = enum {
    /// Characters never match their normalized version (a != ä)
    never,
    /// Acts like never if any character would need normalization,
    /// otherwise normalization occurs (a == ä but ä != a)
    smart,
};

/// The kind of matching algorithm to run for an atom
pub const AtomKind = enum {
    /// Fuzzy matching where needle can match with gaps
    fuzzy,
    /// Substring matching (contiguous, no gaps)
    substring,
    /// Prefix matching (must match at start)
    prefix,
    /// Postfix matching (must match at end)
    postfix,
    /// Exact matching (must match entire string)
    exact,
};

/// A single pattern component matched with a single Matcher function
pub const Atom = struct {
    /// Whether this is a negative (exclusion) match
    negative: bool,
    /// The kind of match to perform
    kind: AtomKind,
    /// The needle to match against
    needle: Utf32String,
    /// Whether to ignore case for this atom
    ignore_case: bool,
    /// Whether to normalize unicode for this atom
    normalize: bool,

    /// Create a new atom from a string
    pub fn init(
        allocator: Allocator,
        needle_str: []const u8,
        case: CaseMatching,
        normalization: Normalization,
        kind: AtomKind,
        escape_whitespace: bool,
    ) !Atom {
        return initInner(allocator, needle_str, case, normalization, kind, escape_whitespace, false);
    }

    fn initInner(
        allocator: Allocator,
        needle_str: []const u8,
        case: CaseMatching,
        normalization: Normalization,
        kind: AtomKind,
        escape_whitespace: bool,
        append_dollar: bool,
    ) !Atom {
        var ignore_case = case == .ignore;
        const do_normalize = normalization == .smart;

        // Process the needle string
        var processed: std.ArrayListUnmanaged(u8) = .empty;
        defer processed.deinit(allocator);

        if (escape_whitespace) {
            var i: usize = 0;
            while (i < needle_str.len) {
                if (needle_str[i] == '\\' and i + 1 < needle_str.len and needle_str[i + 1] == ' ') {
                    try processed.append(allocator, ' ');
                    i += 2;
                } else {
                    try processed.append(allocator, needle_str[i]);
                    i += 1;
                }
            }
        } else {
            try processed.appendSlice(allocator, needle_str);
        }

        if (append_dollar) {
            try processed.append(allocator, '$');
        }

        // Determine case sensitivity
        if (case == .smart) {
            var has_upper = false;
            for (processed.items) |c| {
                if (c >= 'A' and c <= 'Z') {
                    has_upper = true;
                    break;
                }
            }
            ignore_case = !has_upper;
        }

        // Apply case folding if needed
        if (ignore_case) {
            for (processed.items) |*c| {
                if (c.* >= 'A' and c.* <= 'Z') {
                    c.* += 32;
                }
            }
        }

        const needle = try Utf32String.init(allocator, processed.items);

        return .{
            .negative = false,
            .kind = kind,
            .needle = needle,
            .ignore_case = ignore_case,
            .normalize = do_normalize,
        };
    }

    /// Parse a pattern atom from a string with fzf-style syntax
    pub fn parse(
        allocator: Allocator,
        raw: []const u8,
        case: CaseMatching,
        normalization: Normalization,
    ) !Atom {
        var atom = raw;
        var invert = false;

        // Check for negation prefix
        if (atom.len > 0 and atom[0] == '!') {
            atom = atom[1..];
            invert = true;
        } else if (atom.len > 1 and atom[0] == '\\' and atom[1] == '!') {
            atom = atom[1..];
        }

        // Determine kind based on prefix
        var kind: AtomKind = .fuzzy;
        if (atom.len > 0) {
            if (atom[0] == '^') {
                atom = atom[1..];
                kind = .prefix;
            } else if (atom[0] == '\'') {
                atom = atom[1..];
                kind = .substring;
            } else if (atom.len > 1 and atom[0] == '\\' and (atom[1] == '^' or atom[1] == '\'')) {
                atom = atom[1..];
            }
        }

        // Check for postfix/exact suffix
        var append_dollar = false;
        if (atom.len > 1 and atom[atom.len - 2] == '\\' and atom[atom.len - 1] == '$') {
            append_dollar = true;
            atom = atom[0 .. atom.len - 2];
        } else if (atom.len > 0 and atom[atom.len - 1] == '$') {
            kind = if (kind == .fuzzy) .postfix else .exact;
            atom = atom[0 .. atom.len - 1];
        }

        // Negated fuzzy becomes substring (to avoid too many false positives)
        if (invert and kind == .fuzzy) {
            kind = .substring;
        }

        var pattern = try initInner(allocator, atom, case, normalization, kind, true, append_dollar);
        pattern.negative = invert;
        return pattern;
    }

    pub fn deinit(self: *Atom) void {
        self.needle.deinit();
    }

    /// Get the needle text
    pub fn needleText(self: *const Atom) Utf32Str {
        return self.needle.toSlice();
    }

    /// Match this atom against a haystack and return the score
    pub fn score(self: *const Atom, haystack: Utf32Str, matcher: *Matcher) ?u16 {
        // Temporarily override matcher config
        const old_ignore_case = matcher.config.ignore_case;
        const old_normalize = matcher.config.normalize;
        matcher.config.ignore_case = self.ignore_case;
        matcher.config.normalize = self.normalize;
        defer {
            matcher.config.ignore_case = old_ignore_case;
            matcher.config.normalize = old_normalize;
        }

        const pattern_score = switch (self.kind) {
            .exact => matcher.exactMatch(haystack, self.needle.toSlice()),
            .fuzzy => matcher.fuzzyMatch(haystack, self.needle.toSlice()),
            .substring => matcher.substringMatch(haystack, self.needle.toSlice()),
            .prefix => matcher.prefixMatch(haystack, self.needle.toSlice()),
            .postfix => matcher.postfixMatch(haystack, self.needle.toSlice()),
        };

        if (self.negative) {
            if (pattern_score != null) return null;
            return 0;
        } else {
            return pattern_score;
        }
    }

    /// Match and compute indices
    pub fn indices(
        self: *const Atom,
        haystack: Utf32Str,
        matcher: *Matcher,
        result_indices: *std.ArrayList(u32),
    ) ?u16 {
        const old_ignore_case = matcher.config.ignore_case;
        const old_normalize = matcher.config.normalize;
        matcher.config.ignore_case = self.ignore_case;
        matcher.config.normalize = self.normalize;
        defer {
            matcher.config.ignore_case = old_ignore_case;
            matcher.config.normalize = old_normalize;
        }

        if (self.negative) {
            const pattern_score = switch (self.kind) {
                .exact => matcher.exactMatch(haystack, self.needle.toSlice()),
                .fuzzy => matcher.fuzzyMatch(haystack, self.needle.toSlice()),
                .substring => matcher.substringMatch(haystack, self.needle.toSlice()),
                .prefix => matcher.prefixMatch(haystack, self.needle.toSlice()),
                .postfix => matcher.postfixMatch(haystack, self.needle.toSlice()),
            };
            if (pattern_score != null) return null;
            return 0;
        } else {
            return switch (self.kind) {
                .exact => matcher.exactIndices(haystack, self.needle.toSlice(), result_indices),
                .fuzzy => matcher.fuzzyIndices(haystack, self.needle.toSlice(), result_indices),
                .substring => matcher.substringIndices(haystack, self.needle.toSlice(), result_indices),
                .prefix => matcher.prefixIndices(haystack, self.needle.toSlice(), result_indices),
                .postfix => matcher.postfixIndices(haystack, self.needle.toSlice(), result_indices),
            };
        }
    }

    /// Match and compute indices (unmanaged version)
    pub fn scoreWithIndices(
        self: *const Atom,
        haystack: Utf32Str,
        matcher: *Matcher,
        result_indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        const old_ignore_case = matcher.config.ignore_case;
        const old_normalize = matcher.config.normalize;
        matcher.config.ignore_case = self.ignore_case;
        matcher.config.normalize = self.normalize;
        defer {
            matcher.config.ignore_case = old_ignore_case;
            matcher.config.normalize = old_normalize;
        }

        if (self.negative) {
            const pattern_score = switch (self.kind) {
                .exact => matcher.exactMatch(haystack, self.needle.toSlice()),
                .fuzzy => matcher.fuzzyMatch(haystack, self.needle.toSlice()),
                .substring => matcher.substringMatch(haystack, self.needle.toSlice()),
                .prefix => matcher.prefixMatch(haystack, self.needle.toSlice()),
                .postfix => matcher.postfixMatch(haystack, self.needle.toSlice()),
            };
            if (pattern_score != null) return null;
            return 0;
        } else {
            return switch (self.kind) {
                .exact => matcher.exactIndices(haystack, self.needle.toSlice(), result_indices),
                .fuzzy => matcher.fuzzyIndices(haystack, self.needle.toSlice(), result_indices),
                .substring => matcher.substringIndices(haystack, self.needle.toSlice(), result_indices),
                .prefix => matcher.prefixIndices(haystack, self.needle.toSlice(), result_indices),
                .postfix => matcher.postfixIndices(haystack, self.needle.toSlice(), result_indices),
            };
        }
    }

    /// Match a list of items and return sorted results
    pub fn matchList(
        self: *const Atom,
        comptime T: type,
        items: []const T,
        matcher: *Matcher,
        allocator: Allocator,
        getString: fn (T) []const u8,
    ) ![]struct { item: T, score_val: u16 } {
        if (self.needle.isEmpty()) {
            var result = try allocator.alloc(struct { item: T, score_val: u16 }, items.len);
            for (items, 0..) |item, i| {
                result[i] = .{ .item = item, .score_val = 0 };
            }
            return result;
        }

        var matches = std.ArrayList(struct { item: T, score_val: u16 }).init(allocator);
        var buf = std.ArrayList(u21).init(allocator);
        defer buf.deinit();

        for (items) |item| {
            const str = getString(item);
            const haystack = Utf32Str.init(str, &buf);
            if (self.score(haystack, matcher)) |s| {
                try matches.append(.{ .item = item, .score_val = s });
            }
        }

        // Sort by score descending
        const result = try matches.toOwnedSlice();
        std.mem.sort(@TypeOf(result[0]), result, {}, struct {
            fn lessThan(_: void, a: anytype, b: anytype) bool {
                return a.score_val > b.score_val;
            }
        }.lessThan);

        return result;
    }
};

/// A text pattern made up of potentially multiple atoms
pub const Pattern = struct {
    /// The individual pattern atoms (words) in this pattern
    atoms: std.ArrayListUnmanaged(Atom),
    allocator: Allocator,

    /// Create an empty pattern
    pub fn init(allocator: Allocator) Pattern {
        return .{
            .atoms = .empty,
            .allocator = allocator,
        };
    }

    /// Create a pattern where each word is matched individually
    pub fn new(
        allocator: Allocator,
        pattern_str: []const u8,
        case: CaseMatching,
        normalization: Normalization,
        kind: AtomKind,
    ) !Pattern {
        var result = init(allocator);
        errdefer result.deinit();

        var iter = PatternAtomIterator.init(pattern_str);
        while (iter.next()) |atom_str| {
            var atom = try Atom.init(allocator, atom_str, case, normalization, kind, true);
            if (!atom.needle.isEmpty()) {
                try result.atoms.append(allocator, atom);
            } else {
                atom.deinit();
            }
        }

        return result;
    }

    /// Parse a pattern with fzf-style syntax
    pub fn parse(
        allocator: Allocator,
        pattern_str: []const u8,
        case: CaseMatching,
        normalization: Normalization,
    ) !Pattern {
        var result = init(allocator);
        errdefer result.deinit();

        var iter = PatternAtomIterator.init(pattern_str);
        while (iter.next()) |atom_str| {
            var atom = try Atom.parse(allocator, atom_str, case, normalization);
            if (!atom.needle.isEmpty()) {
                try result.atoms.append(allocator, atom);
            } else {
                atom.deinit();
            }
        }

        return result;
    }

    pub fn deinit(self: *Pattern) void {
        for (self.atoms.items) |*atom| {
            atom.deinit();
        }
        self.atoms.deinit(self.allocator);
    }

    /// Check if pattern is empty
    pub fn isEmpty(self: *const Pattern) bool {
        return self.atoms.items.len == 0;
    }

    /// Match this pattern against a haystack
    pub fn score(self: *const Pattern, haystack: Utf32Str, matcher: *Matcher) ?u32 {
        if (self.isEmpty()) return 0;

        var total: u32 = 0;
        for (self.atoms.items) |*atom| {
            const s = atom.score(haystack, matcher) orelse return null;
            total += s;
        }
        return total;
    }

    /// Match and compute indices for all atoms
    pub fn indices(
        self: *const Pattern,
        haystack: Utf32Str,
        matcher: *Matcher,
        result_indices: *std.ArrayList(u32),
    ) ?u32 {
        if (self.isEmpty()) return 0;

        var total: u32 = 0;
        for (self.atoms.items) |*atom| {
            const s = atom.indices(haystack, matcher, result_indices) orelse return null;
            total += s;
        }
        return total;
    }

    /// Match and compute indices for all atoms (unmanaged version)
    pub fn scoreWithIndices(
        self: *const Pattern,
        haystack: Utf32Str,
        matcher: *Matcher,
        result_indices: *std.ArrayListUnmanaged(u32),
    ) ?u32 {
        if (self.isEmpty()) return 0;

        var total: u32 = 0;
        for (self.atoms.items) |*atom| {
            const s = atom.scoreWithIndices(haystack, matcher, result_indices) orelse return null;
            total += s;
        }
        return total;
    }

    /// Reparse the pattern from a new string
    pub fn reparse(
        self: *Pattern,
        pattern_str: []const u8,
        case: CaseMatching,
        normalization: Normalization,
    ) !void {
        // Clear existing atoms
        for (self.atoms.items) |*atom| {
            atom.deinit();
        }
        self.atoms.clearRetainingCapacity();

        // Parse new atoms
        var iter = PatternAtomIterator.init(pattern_str);
        while (iter.next()) |atom_str| {
            var atom = try Atom.parse(self.allocator, atom_str, case, normalization);
            if (!atom.needle.isEmpty()) {
                try self.atoms.append(self.allocator, atom);
            } else {
                atom.deinit();
            }
        }
    }
};

/// Iterator over pattern atoms (words)
const PatternAtomIterator = struct {
    pattern: []const u8,
    index: usize,

    fn init(pattern: []const u8) PatternAtomIterator {
        return .{ .pattern = pattern, .index = 0 };
    }

    fn next(self: *PatternAtomIterator) ?[]const u8 {
        // Skip leading whitespace
        while (self.index < self.pattern.len and isWhitespace(self.pattern[self.index])) {
            self.index += 1;
        }

        if (self.index >= self.pattern.len) return null;

        const start = self.index;
        var saw_backslash = false;

        while (self.index < self.pattern.len) {
            const c = self.pattern[self.index];
            if (saw_backslash) {
                saw_backslash = false;
            } else if (c == '\\') {
                saw_backslash = true;
            } else if (isWhitespace(c)) {
                break;
            }
            self.index += 1;
        }

        if (self.index == start) return null;
        return self.pattern[start..self.index];
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

// ============================================================
// Tests
// ============================================================

test "atom parse fuzzy" {
    var atom = try Atom.parse(std.testing.allocator, "foo", .smart, .smart);
    defer atom.deinit();

    try std.testing.expectEqual(AtomKind.fuzzy, atom.kind);
    try std.testing.expect(!atom.negative);
}

test "atom parse prefix" {
    var atom = try Atom.parse(std.testing.allocator, "^foo", .smart, .smart);
    defer atom.deinit();

    try std.testing.expectEqual(AtomKind.prefix, atom.kind);
    try std.testing.expect(!atom.negative);
}

test "atom parse postfix" {
    var atom = try Atom.parse(std.testing.allocator, "foo$", .smart, .smart);
    defer atom.deinit();

    try std.testing.expectEqual(AtomKind.postfix, atom.kind);
}

test "atom parse exact" {
    var atom = try Atom.parse(std.testing.allocator, "^foo$", .smart, .smart);
    defer atom.deinit();

    try std.testing.expectEqual(AtomKind.exact, atom.kind);
}

test "atom parse substring" {
    var atom = try Atom.parse(std.testing.allocator, "'foo", .smart, .smart);
    defer atom.deinit();

    try std.testing.expectEqual(AtomKind.substring, atom.kind);
}

test "atom parse negation" {
    var atom = try Atom.parse(std.testing.allocator, "!foo", .smart, .smart);
    defer atom.deinit();

    try std.testing.expect(atom.negative);
    try std.testing.expectEqual(AtomKind.substring, atom.kind); // negated fuzzy becomes substring
}

test "pattern parse multiple words" {
    var pattern = try Pattern.parse(std.testing.allocator, "foo bar", .smart, .smart);
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 2), pattern.atoms.items.len);
}

test "pattern score" {
    var pattern = try Pattern.parse(std.testing.allocator, "foo", .smart, .smart);
    defer pattern.deinit();

    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("foobar", std.testing.allocator, &buf);
    const result = pattern.score(haystack, &matcher);
    try std.testing.expect(result != null);
}

test "smart case - lowercase pattern" {
    var atom = try Atom.parse(std.testing.allocator, "foo", .smart, .smart);
    defer atom.deinit();

    try std.testing.expect(atom.ignore_case);
}

test "smart case - mixed case pattern" {
    var atom = try Atom.parse(std.testing.allocator, "Foo", .smart, .smart);
    defer atom.deinit();

    try std.testing.expect(!atom.ignore_case);
}
