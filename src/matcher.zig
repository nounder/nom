//! The core fuzzy matcher implementation.
//!
//! This module provides the Matcher struct which implements various matching
//! algorithms including fuzzy, substring, exact, prefix, and postfix matching.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const CharClass = @import("chars.zig").CharClass;
const Char = @import("chars.zig").Char;
const Utf32Str = @import("utf32_str.zig").Utf32Str;
const score = @import("score.zig");
const matrix = @import("matrix.zig");
const prefilter = @import("prefilter.zig");

const MatrixSlab = matrix.MatrixSlab;
const MatcherDataView = matrix.MatcherDataView;

/// A matcher engine that can execute fuzzy matches.
///
/// The matcher contains heap-allocated scratch memory that is reused during
/// matching. This allows the matcher to avoid allocations during matching
/// (except for growing the indices vector if needed).
pub const Matcher = struct {
    /// Configuration for this matcher
    config: Config,
    /// Preallocated memory for matrix operations
    slab: MatrixSlab,
    allocator: Allocator,

    /// Create a new matcher with the given configuration
    pub fn init(allocator: Allocator, config: Config) !Matcher {
        return .{
            .config = config,
            .slab = try MatrixSlab.init(allocator),
            .allocator = allocator,
        };
    }

    /// Create a matcher with default configuration
    pub fn initDefault(allocator: Allocator) !Matcher {
        return init(allocator, Config.default());
    }

    pub fn deinit(self: *Matcher) void {
        self.slab.deinit();
    }

    // ============================================================
    // Fuzzy Matching
    // ============================================================

    /// Find the fuzzy match with the highest score in the haystack.
    /// Returns null if no match is found.
    pub fn fuzzyMatch(self: *Matcher, haystack: Utf32Str, needle: Utf32Str) ?u16 {
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);
        return self.fuzzyMatchImpl(false, haystack, needle, &indices);
    }

    /// Find the fuzzy match with the highest score and compute match indices.
    pub fn fuzzyIndices(
        self: *Matcher,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        return self.fuzzyMatchImpl(true, haystack, needle, indices);
    }

    fn fuzzyMatchImpl(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.len() > haystack.len()) return null;
        if (needle.isEmpty()) return 0;
        if (needle.len() == haystack.len()) {
            return self.exactMatchImpl(compute_indices, haystack, needle, 0, haystack.len(), indices);
        }

        // Dispatch based on haystack/needle types
        switch (haystack) {
            .ascii => |h_bytes| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        // Single char optimization
                        if (n_bytes.len == 1) {
                            return self.substringMatch1Ascii(compute_indices, h_bytes, n_bytes[0], indices);
                        }

                        const pf = prefilter.prefilterAscii(&self.config, h_bytes, n_bytes, false) orelse return null;

                        if (n_bytes.len == pf.end - pf.start) {
                            return self.calculateScore(u8, u8, compute_indices, h_bytes, n_bytes, pf.start, pf.greedy_end, indices);
                        }

                        return self.fuzzyMatchOptimal(
                            u8,
                            u8,
                            compute_indices,
                            h_bytes,
                            n_bytes,
                            pf.start,
                            pf.greedy_end,
                            pf.end,
                            indices,
                        );
                    },
                    .unicode => {
                        // ASCII haystack can't match Unicode needle
                        return null;
                    },
                }
            },
            .unicode => |h_chars| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        if (n_bytes.len == 1) {
                            const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, true) orelse return null;
                            return self.substringMatch1NonAscii(compute_indices, h_chars, n_bytes[0], pf.start, indices);
                        }

                        const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, false) orelse return null;

                        if (needle.len() == pf.end - pf.start) {
                            return self.exactMatchImpl(compute_indices, haystack, needle, pf.start, pf.end, indices);
                        }

                        return self.fuzzyMatchOptimal(
                            u21,
                            u8,
                            compute_indices,
                            h_chars,
                            n_bytes,
                            pf.start,
                            pf.start + 1,
                            pf.end,
                            indices,
                        );
                    },
                    .unicode => |n_chars| {
                        if (n_chars.len == 1) {
                            const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, true) orelse return null;
                            return self.substringMatch1NonAscii(compute_indices, h_chars, n_chars[0], pf.start, indices);
                        }

                        const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, false) orelse return null;

                        if (needle.len() == pf.end - pf.start) {
                            return self.exactMatchImpl(compute_indices, haystack, needle, pf.start, pf.end, indices);
                        }

                        return self.fuzzyMatchOptimal(
                            u21,
                            u21,
                            compute_indices,
                            h_chars,
                            n_chars,
                            pf.start,
                            pf.start + 1,
                            pf.end,
                            indices,
                        );
                    },
                }
            },
        }
    }

    /// Optimal fuzzy matching using Smith-Waterman algorithm
    fn fuzzyMatchOptimal(
        self: *Matcher,
        comptime H: type,
        comptime N: type,
        comptime compute_indices: bool,
        haystack: []const H,
        needle: []const N,
        start: usize,
        greedy_end: usize,
        end: usize,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        const view = self.slab.alloc(H, haystack[start..end], needle.len) orelse {
            // Fall back to greedy matching
            return self.fuzzyMatchGreedyImpl(H, N, compute_indices, haystack, needle, start, greedy_end, indices);
        };

        const prev_class = if (start > 0)
            Char(H).charClass(haystack[start - 1], &self.config)
        else
            self.config.initial_char_class;

        var view_mut = view;
        const matched = view_mut.setup(N, needle, prev_class, &self.config, @intCast(start));
        if (!matched) return null;

        const matrix_len = view_mut.populateMatrix(N, needle);

        // Find best score in last row
        const last_row_off = view_mut.row_offs[needle.len - 1];
        const relative_last_row_off = @as(usize, last_row_off) + 1 - needle.len;

        var best_score: u16 = 0;
        var best_end: u16 = 0;

        for (view_mut.current_row[relative_last_row_off..], 0..) |cell, i| {
            if (cell.score_val > best_score) {
                best_score = cell.score_val;
                best_end = @intCast(i);
            }
        }

        if (compute_indices) {
            view_mut.reconstructOptimalPath(best_end, self.allocator, indices, matrix_len, @intCast(start));
        }

        return best_score;
    }

    // ============================================================
    // Greedy Fuzzy Matching
    // ============================================================

    /// Greedy fuzzy match - faster but may not find optimal match
    pub fn fuzzyMatchGreedy(self: *Matcher, haystack: Utf32Str, needle: Utf32Str) ?u16 {
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);
        return self.fuzzyMatchGreedyDispatch(false, haystack, needle, &indices);
    }

    /// Greedy fuzzy match with indices
    pub fn fuzzyIndicesGreedy(
        self: *Matcher,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        return self.fuzzyMatchGreedyDispatch(true, haystack, needle, indices);
    }

    fn fuzzyMatchGreedyDispatch(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.len() > haystack.len()) return null;
        if (needle.isEmpty()) return 0;
        if (needle.len() == haystack.len()) {
            return self.exactMatchImpl(compute_indices, haystack, needle, 0, haystack.len(), indices);
        }

        switch (haystack) {
            .ascii => |h_bytes| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        const pf = prefilter.prefilterAscii(&self.config, h_bytes, n_bytes, true) orelse return null;
                        if (n_bytes.len == pf.greedy_end - pf.start) {
                            return self.calculateScore(u8, u8, compute_indices, h_bytes, n_bytes, pf.start, pf.greedy_end, indices);
                        }
                        return self.fuzzyMatchGreedyImpl(u8, u8, compute_indices, h_bytes, n_bytes, pf.start, pf.greedy_end, indices);
                    },
                    .unicode => return null,
                }
            },
            .unicode => |h_chars| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, true) orelse return null;
                        return self.fuzzyMatchGreedyImpl(u21, u8, compute_indices, h_chars, n_bytes, pf.start, pf.start + 1, indices);
                    },
                    .unicode => |n_chars| {
                        const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, true) orelse return null;
                        return self.fuzzyMatchGreedyImpl(u21, u21, compute_indices, h_chars, n_chars, pf.start, pf.start + 1, indices);
                    },
                }
            },
        }
    }

    fn fuzzyMatchGreedyImpl(
        self: *Matcher,
        comptime H: type,
        comptime N: type,
        comptime compute_indices: bool,
        haystack: []const H,
        needle: []const N,
        start_in: usize,
        end_in: usize,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        var start = start_in;
        var end = end_in;

        const first_char_end = if (H == u8 and N == u8) start + 1 else end;

        // Forward scan for non-ASCII
        if (H != u8 or N != u8) {
            var needle_idx: usize = 1;
            if (needle_idx < needle.len) {
                var needle_char = needle[needle_idx];
                for (haystack[first_char_end..], first_char_end..) |c, i| {
                    if (Char(H).normalize(c, &self.config) == Char(N).normalize(needle_char, &self.config)) {
                        needle_idx += 1;
                        if (needle_idx >= needle.len) {
                            end = i + 1;
                            break;
                        }
                        needle_char = needle[needle_idx];
                    }
                }
                if (needle_idx < needle.len) return null;
            }
        }

        // Backward scan to minimize match range
        var needle_idx = needle.len;
        var needle_char = needle[needle_idx - 1];

        var i = end;
        while (i > start) {
            i -= 1;
            const c = Char(H).normalize(haystack[i], &self.config);
            if (charEql(H, N, c, Char(N).normalize(needle_char, &self.config))) {
                needle_idx -= 1;
                if (needle_idx == 0) {
                    start = i;
                    break;
                }
                needle_char = needle[needle_idx - 1];
            }
        }

        return self.calculateScore(H, N, compute_indices, haystack, needle, start, end, indices);
    }

    // ============================================================
    // Substring Matching
    // ============================================================

    /// Find substring match with highest score
    pub fn substringMatch(self: *Matcher, haystack: Utf32Str, needle: Utf32Str) ?u16 {
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);
        return self.substringMatchImpl(false, haystack, needle, &indices);
    }

    /// Find substring match with indices
    pub fn substringIndices(
        self: *Matcher,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        return self.substringMatchImpl(true, haystack, needle, indices);
    }

    fn substringMatchImpl(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.len() > haystack.len()) return null;
        if (needle.isEmpty()) return 0;
        if (needle.len() == haystack.len()) {
            return self.exactMatchImpl(compute_indices, haystack, needle, 0, haystack.len(), indices);
        }

        switch (haystack) {
            .ascii => |h_bytes| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        if (n_bytes.len == 1) {
                            return self.substringMatch1Ascii(compute_indices, h_bytes, n_bytes[0], indices);
                        }
                        return self.substringMatchAscii(compute_indices, h_bytes, n_bytes, indices);
                    },
                    .unicode => return null,
                }
            },
            .unicode => |h_chars| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        if (n_bytes.len == 1) {
                            const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, true) orelse return null;
                            return self.substringMatch1NonAscii(compute_indices, h_chars, n_bytes[0], pf.start, indices);
                        }
                        const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, false) orelse return null;
                        return self.substringMatchNonAscii(u21, u8, compute_indices, h_chars, n_bytes, pf.start, indices);
                    },
                    .unicode => |n_chars| {
                        if (n_chars.len == 1) {
                            const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, true) orelse return null;
                            return self.substringMatch1NonAscii(compute_indices, h_chars, n_chars[0], pf.start, indices);
                        }
                        const pf = prefilter.prefilterNonAscii(&self.config, h_chars, needle, false) orelse return null;
                        return self.substringMatchNonAscii(u21, u21, compute_indices, h_chars, n_chars, pf.start, indices);
                    },
                }
            },
        }
    }

    fn substringMatch1Ascii(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: []const u8,
        c: u8,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        var max_score: u16 = 0;
        var max_pos: u32 = 0;

        for (haystack, 0..) |h, i| {
            const matches = if (self.config.ignore_case and c >= 'a' and c <= 'z')
                (h == c or h == c - 32)
            else
                h == c;

            if (matches) {
                const prev_class = if (i > 0)
                    Char(u8).charClass(haystack[i - 1], &self.config)
                else
                    self.config.initial_char_class;
                const char_class = Char(u8).charClass(h, &self.config);
                const bonus = self.config.bonusFor(prev_class, char_class);
                const s = bonus * score.BONUS_FIRST_CHAR_MULTIPLIER + score.SCORE_MATCH;

                if (s > max_score) {
                    max_pos = @intCast(i);
                    max_score = s;
                    if (bonus >= self.config.bonus_boundary_white) break;
                }
            }
        }

        if (max_score == 0) return null;

        if (compute_indices) {
            indices.append(self.allocator, max_pos) catch {};
        }
        return max_score;
    }

    fn substringMatch1NonAscii(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: []const u21,
        needle_char: anytype,
        start: usize,
        indices: *std.ArrayListUnmanaged(u32),
    ) u16 {
        var max_score: u16 = 0;
        var max_pos: u32 = 0;

        var prev_class = if (start > 0)
            Char(u21).charClass(haystack[start - 1], &self.config)
        else
            self.config.initial_char_class;

        for (haystack[start..], start..) |c, i| {
            const result = Char(u21).charClassAndNormalize(c, &self.config);
            if (result.char != needle_char) continue;

            const bonus = self.config.bonusFor(prev_class, result.class);
            prev_class = result.class;
            const s = bonus * score.BONUS_FIRST_CHAR_MULTIPLIER + score.SCORE_MATCH;

            if (s > max_score) {
                max_pos = @intCast(i);
                max_score = s;
                if (bonus >= self.config.bonus_boundary_white) break;
            }
        }

        if (compute_indices) {
            indices.append(self.allocator, max_pos) catch {};
        }
        return max_score;
    }

    fn substringMatchAscii(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: []const u8,
        needle: []const u8,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        var max_score: u16 = 0;
        var max_pos: usize = 0;

        // Simple substring search
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            const matches = if (self.config.ignore_case)
                asciiEqualIgnoreCase(haystack[i..][0..needle.len], needle)
            else
                std.mem.eql(u8, haystack[i..][0..needle.len], needle);

            if (matches) {
                const prev_class = if (i > 0)
                    Char(u8).charClass(haystack[i - 1], &self.config)
                else
                    self.config.initial_char_class;
                const char_class = Char(u8).charClass(haystack[i], &self.config);
                const bonus = self.config.bonusFor(prev_class, char_class);
                const s = bonus * score.BONUS_FIRST_CHAR_MULTIPLIER + score.SCORE_MATCH;

                if (s > max_score) {
                    max_pos = i;
                    max_score = s;
                    if (bonus >= self.config.bonus_boundary_white) break;
                }
            }
        }

        if (max_score == 0) return null;

        return self.calculateScore(u8, u8, compute_indices, haystack, needle, max_pos, max_pos + needle.len, indices);
    }

    fn substringMatchNonAscii(
        self: *Matcher,
        comptime H: type,
        comptime N: type,
        comptime compute_indices: bool,
        haystack: []const H,
        needle: []const N,
        start: usize,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        var max_score: u16 = 0;
        var max_pos: usize = 0;

        var prev_class = if (start > 0)
            Char(H).charClass(haystack[start - 1], &self.config)
        else
            self.config.initial_char_class;

        const search_end = haystack.len - needle.len;
        var i = start;
        while (i <= search_end) : (i += 1) {
            const result = Char(H).charClassAndNormalize(haystack[i], &self.config);
            if (result.char != Char(N).normalize(needle[0], &self.config)) continue;

            const bonus = self.config.bonusFor(prev_class, result.class);
            prev_class = result.class;

            // Check if rest of needle matches
            var match = true;
            for (needle[1..], 1..) |n, j| {
                if (Char(H).normalize(haystack[i + j], &self.config) != Char(N).normalize(n, &self.config)) {
                    match = false;
                    break;
                }
            }

            if (match) {
                const s = bonus * score.BONUS_FIRST_CHAR_MULTIPLIER + score.SCORE_MATCH;
                if (s > max_score) {
                    max_pos = i;
                    max_score = s;
                    if (bonus >= self.config.bonus_boundary_white) break;
                }
            }
        }

        if (max_score == 0) return null;

        return self.calculateScore(H, N, compute_indices, haystack, needle, max_pos, max_pos + needle.len, indices);
    }

    // ============================================================
    // Exact Matching
    // ============================================================

    /// Check if needle matches haystack exactly (ignoring leading/trailing whitespace)
    pub fn exactMatch(self: *Matcher, haystack: Utf32Str, needle: Utf32Str) ?u16 {
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);

        if (needle.isEmpty()) return 0;

        var leading_space: usize = 0;
        var trailing_space: usize = 0;

        if (!isWhitespace(needle.first())) {
            leading_space = haystack.leadingWhiteSpace();
        }
        if (!isWhitespace(needle.last())) {
            trailing_space = haystack.trailingWhiteSpace();
        }

        if (trailing_space == haystack.len()) return null;

        return self.exactMatchImpl(false, haystack, needle, leading_space, haystack.len() - trailing_space, &indices);
    }

    /// Check exact match and compute indices
    pub fn exactIndices(
        self: *Matcher,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.isEmpty()) return 0;

        var leading_space: usize = 0;
        var trailing_space: usize = 0;

        if (!isWhitespace(needle.first())) {
            leading_space = haystack.leadingWhiteSpace();
        }
        if (!isWhitespace(needle.last())) {
            trailing_space = haystack.trailingWhiteSpace();
        }

        if (trailing_space == haystack.len()) return null;

        return self.exactMatchImpl(true, haystack, needle, leading_space, haystack.len() - trailing_space, indices);
    }

    fn exactMatchImpl(
        self: *Matcher,
        comptime compute_indices: bool,
        haystack: Utf32Str,
        needle: Utf32Str,
        start: usize,
        end: usize,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.len() != end - start) return null;

        switch (haystack) {
            .ascii => |h_bytes| {
                switch (needle) {
                    .ascii => |n_bytes| {
                        const h_slice = h_bytes[start..end];
                        const matches = if (self.config.ignore_case)
                            asciiEqualIgnoreCase(h_slice, n_bytes)
                        else
                            std.mem.eql(u8, h_slice, n_bytes);

                        if (!matches) return null;
                        return self.calculateScore(u8, u8, compute_indices, h_bytes, n_bytes, start, end, indices);
                    },
                    .unicode => return null,
                }
            },
            .unicode => |h_chars| {
                const h_slice = h_chars[start..end];
                switch (needle) {
                    .ascii => |n_bytes| {
                        for (h_slice, n_bytes) |h, n| {
                            if (Char(u21).normalize(h, &self.config) != Char(u8).normalize(n, &self.config)) {
                                return null;
                            }
                        }
                        return self.calculateScore(u21, u8, compute_indices, h_chars, n_bytes, start, end, indices);
                    },
                    .unicode => |n_chars| {
                        for (h_slice, n_chars) |h, n| {
                            if (Char(u21).normalize(h, &self.config) != Char(u21).normalize(n, &self.config)) {
                                return null;
                            }
                        }
                        return self.calculateScore(u21, u21, compute_indices, h_chars, n_chars, start, end, indices);
                    },
                }
            },
        }
    }

    // ============================================================
    // Prefix Matching
    // ============================================================

    /// Check if needle is a prefix of haystack
    pub fn prefixMatch(self: *Matcher, haystack: Utf32Str, needle: Utf32Str) ?u16 {
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);

        if (needle.isEmpty()) return 0;

        var leading_space: usize = 0;
        if (!isWhitespace(needle.first())) {
            leading_space = haystack.leadingWhiteSpace();
        }

        if (haystack.len() - leading_space < needle.len()) return null;

        return self.exactMatchImpl(false, haystack, needle, leading_space, needle.len() + leading_space, &indices);
    }

    /// Check prefix match and compute indices
    pub fn prefixIndices(
        self: *Matcher,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.isEmpty()) return 0;

        var leading_space: usize = 0;
        if (!isWhitespace(needle.first())) {
            leading_space = haystack.leadingWhiteSpace();
        }

        if (haystack.len() - leading_space < needle.len()) return null;

        return self.exactMatchImpl(true, haystack, needle, leading_space, needle.len() + leading_space, indices);
    }

    // ============================================================
    // Postfix Matching
    // ============================================================

    /// Check if needle is a postfix of haystack
    pub fn postfixMatch(self: *Matcher, haystack: Utf32Str, needle: Utf32Str) ?u16 {
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);

        if (needle.isEmpty()) return 0;

        var trailing_space: usize = 0;
        if (!isWhitespace(needle.last())) {
            trailing_space = haystack.trailingWhiteSpace();
        }

        if (haystack.len() - trailing_space < needle.len()) return null;

        const start = haystack.len() - needle.len() - trailing_space;
        const end = haystack.len() - trailing_space;

        return self.exactMatchImpl(false, haystack, needle, start, end, &indices);
    }

    /// Check postfix match and compute indices
    pub fn postfixIndices(
        self: *Matcher,
        haystack: Utf32Str,
        needle: Utf32Str,
        indices: *std.ArrayListUnmanaged(u32),
    ) ?u16 {
        if (needle.isEmpty()) return 0;

        var trailing_space: usize = 0;
        if (!isWhitespace(needle.last())) {
            trailing_space = haystack.trailingWhiteSpace();
        }

        if (haystack.len() - trailing_space < needle.len()) return null;

        const start = haystack.len() - needle.len() - trailing_space;
        const end = haystack.len() - trailing_space;

        return self.exactMatchImpl(true, haystack, needle, start, end, indices);
    }

    // ============================================================
    // Score Calculation
    // ============================================================

    fn calculateScore(
        self: *Matcher,
        comptime H: type,
        comptime N: type,
        comptime compute_indices: bool,
        haystack: []const H,
        needle: []const N,
        start: usize,
        end: usize,
        indices: *std.ArrayListUnmanaged(u32),
    ) u16 {
        if (compute_indices) {
            indices.ensureUnusedCapacity(self.allocator, needle.len) catch {};
        }

        var prev_class = if (start > 0)
            Char(H).charClass(haystack[start - 1], &self.config)
        else
            self.config.initial_char_class;

        var needle_iter: usize = 0;
        var needle_char = needle[0];

        var in_gap = false;
        var consecutive: u16 = 1;

        // First character
        if (compute_indices) {
            indices.append(self.allocator, @intCast(start)) catch {};
        }

        const first_class = Char(H).charClass(haystack[start], &self.config);
        var first_bonus = self.config.bonusFor(prev_class, first_class);
        var total_score = score.SCORE_MATCH + first_bonus * score.BONUS_FIRST_CHAR_MULTIPLIER;
        prev_class = first_class;

        needle_iter = 1;
        if (needle_iter < needle.len) {
            needle_char = needle[needle_iter];
        }

        // Remaining characters
        var i = start + 1;
        while (i < end) : (i += 1) {
            const result = Char(H).charClassAndNormalize(haystack[i], &self.config);
            const c = result.char;
            const class = result.class;

            if (charEql(H, N, c, Char(N).normalize(needle_char, &self.config))) {
                if (compute_indices) {
                    indices.append(self.allocator, @intCast(i)) catch {};
                }

                var bonus = self.config.bonusFor(prev_class, class);
                if (consecutive != 0) {
                    if (bonus >= score.BONUS_BOUNDARY and bonus > first_bonus) {
                        first_bonus = bonus;
                    }
                    bonus = @max(@max(bonus, first_bonus), score.BONUS_CONSECUTIVE);
                } else {
                    first_bonus = bonus;
                }

                total_score +|= score.SCORE_MATCH + bonus;
                in_gap = false;
                consecutive += 1;

                needle_iter += 1;
                if (needle_iter < needle.len) {
                    needle_char = needle[needle_iter];
                }
            } else {
                const penalty = if (in_gap) score.PENALTY_GAP_EXTENSION else score.PENALTY_GAP_START;
                total_score -|= penalty;
                in_gap = true;
                consecutive = 0;
            }

            prev_class = class;
        }

        // Prefix bonus
        if (self.config.prefer_prefix) {
            if (start != 0) {
                const penalty = score.PENALTY_GAP_START +|
                    @as(u16, @truncate(@min(start -| 1, std.math.maxInt(u16)))) *| score.PENALTY_GAP_START;
                total_score +|= score.MAX_PREFIX_BONUS -| (penalty / score.PREFIX_BONUS_SCALE);
            } else {
                total_score +|= score.MAX_PREFIX_BONUS;
            }
        }

        return total_score;
    }
};

// ============================================================
// Helper Functions
// ============================================================

fn charEql(comptime H: type, comptime N: type, h: H, n: N) bool {
    if (H == N) {
        return h == n;
    }
    // Cross-type comparison - cast to larger type
    const h_val: u32 = h;
    const n_val: u32 = n;
    return h_val == n_val;
}

fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn isWhitespace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        0x00A0, 0x1680 => true,
        0x2000...0x200A => true,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

// ============================================================
// Tests
// ============================================================

test "fuzzy match basic" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello world", std.testing.allocator, &buf);
    const needle = Utf32Str.init("hlo", std.testing.allocator, &buf);

    const result = matcher.fuzzyMatch(haystack, needle);
    try std.testing.expect(result != null);
}

test "fuzzy match with indices" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello", std.testing.allocator, &buf);
    const needle = Utf32Str.init("hlo", std.testing.allocator, &buf);

    const result = matcher.fuzzyIndices(haystack, needle, &indices);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), indices.items.len);
}

test "substring match" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello world", std.testing.allocator, &buf);
    const needle = Utf32Str.init("wor", std.testing.allocator, &buf);

    const result = matcher.substringMatch(haystack, needle);
    try std.testing.expect(result != null);
}

test "exact match" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello", std.testing.allocator, &buf);
    const needle = Utf32Str.init("hello", std.testing.allocator, &buf);

    const result = matcher.exactMatch(haystack, needle);
    try std.testing.expect(result != null);
}

test "prefix match" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello world", std.testing.allocator, &buf);
    const needle = Utf32Str.init("hello", std.testing.allocator, &buf);

    const result = matcher.prefixMatch(haystack, needle);
    try std.testing.expect(result != null);

    const needle2 = Utf32Str.init("world", std.testing.allocator, &buf);
    const result2 = matcher.prefixMatch(haystack, needle2);
    try std.testing.expect(result2 == null);
}

test "postfix match" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello world", std.testing.allocator, &buf);
    const needle = Utf32Str.init("world", std.testing.allocator, &buf);

    const result = matcher.postfixMatch(haystack, needle);
    try std.testing.expect(result != null);

    const needle2 = Utf32Str.init("hello", std.testing.allocator, &buf);
    const result2 = matcher.postfixMatch(haystack, needle2);
    try std.testing.expect(result2 == null);
}

test "case insensitive match" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("Hello World", std.testing.allocator, &buf);
    const needle = Utf32Str.init("hello", std.testing.allocator, &buf);

    const result = matcher.prefixMatch(haystack, needle);
    try std.testing.expect(result != null);
}

test "no match" {
    var matcher = try Matcher.initDefault(std.testing.allocator);
    defer matcher.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(std.testing.allocator);

    const haystack = Utf32Str.init("hello", std.testing.allocator, &buf);
    const needle = Utf32Str.init("xyz", std.testing.allocator, &buf);

    const result = matcher.fuzzyMatch(haystack, needle);
    try std.testing.expect(result == null);
}
