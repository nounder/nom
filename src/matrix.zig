//! The matrix is used for the Smith-Waterman dynamic programming algorithm.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const CharClass = @import("chars.zig").CharClass;
const Char = @import("chars.zig").Char;
const score = @import("score.zig");

pub const MAX_MATRIX_SIZE: usize = 100 * 1024;

pub const MAX_HAYSTACK_LEN: usize = 2048;

pub const MAX_NEEDLE_LEN: usize = 2048;

pub const ScoreCell = struct {
    score_val: u16 = 0,
    consecutive_bonus: u8 = 0,
    matched: bool = false,

    pub const UNMATCHED: ScoreCell = .{
        .score_val = 0,
        .consecutive_bonus = 0,
        // consecutive_bonus=0 with matched=true can't occur naturally
        .matched = true,
    };

    pub fn eql(self: ScoreCell, other: ScoreCell) bool {
        return self.score_val == other.score_val and
            self.consecutive_bonus == other.consecutive_bonus and
            self.matched == other.matched;
    }
};

pub const MatrixCell = packed struct {
    data: u8 = 0,

    pub fn set(self: *MatrixCell, p_match: bool, m_match: bool) void {
        self.data = @intFromBool(p_match) | (@as(u8, @intFromBool(m_match)) << 1);
    }

    pub fn get(self: MatrixCell, m_matrix: bool) bool {
        const mask: u8 = @as(u8, @intFromBool(m_matrix)) + 1;
        return (self.data & mask) != 0;
    }
};

pub fn MatcherDataView(comptime CharType: type) type {
    return struct {
        const Self = @This();

        haystack: []CharType,
        bonus: []u8,
        current_row: []ScoreCell,
        row_offs: []u16,
        matrix_cells: []MatrixCell,

        /// returns false if no match is possible
        pub fn setup(
            self: *Self,
            comptime NeedleCharType: type,
            needle: []const NeedleCharType,
            prev_class: CharClass,
            config: *const Config,
            start: u32,
        ) bool {
            var current_prev_class = prev_class;
            var row_iter_idx: usize = 0;
            var needle_char = needle[0];

            var matched = false;

            // Process haystack: normalize chars, compute bonus, find first occurrence of each needle char
            for (self.haystack, 0..) |*c, i| {
                const result = Char(CharType).charClassAndNormalize(c.*, config);
                c.* = result.char;
                const class = result.class;

                const bonus_val = config.bonusFor(current_prev_class, class);
                self.bonus[i] = @truncate(bonus_val);
                current_prev_class = class;

                // Track first occurrence of each needle character
                if (charEql(CharType, NeedleCharType, c.*, needle_char)) {
                    if (row_iter_idx + 1 < needle.len) {
                        self.row_offs[row_iter_idx] = @intCast(i);
                        row_iter_idx += 1;
                        needle_char = needle[row_iter_idx];
                    } else if (!matched) {
                        self.row_offs[row_iter_idx] = @intCast(i);
                        matched = true;
                    }
                }
            }

            if (!matched) return false;

            // Score the first row
            self.scoreFirstRow(NeedleCharType, needle, config, start);

            return true;
        }

        fn scoreFirstRow(
            self: *Self,
            comptime NeedleCharType: type,
            needle: []const NeedleCharType,
            config: *const Config,
            start: u32,
        ) void {
            const row_off: usize = self.row_offs[0];
            const next_row_off = if (needle.len > 1) self.row_offs[1] else @as(u16, @intCast(self.haystack.len - 1));

            var prefix_bonus: u16 = 0;
            if (config.prefer_prefix) {
                if (start == 0) {
                    prefix_bonus = score.MAX_PREFIX_BONUS * score.PREFIX_BONUS_SCALE;
                } else {
                    const penalty = score.PENALTY_GAP_START +|
                        @as(u16, @truncate(start -| 1)) *| score.PENALTY_GAP_EXTENSION;
                    prefix_bonus = (score.MAX_PREFIX_BONUS * score.PREFIX_BONUS_SCALE) -| penalty;
                }
            }

            var prev_p_score: u16 = 0;
            var prev_m_score: u16 = 0;

            // Process columns before next_row_off
            var col: usize = row_off;
            while (col < next_row_off) : (col += 1) {
                const p_result = pScore(prev_p_score, prev_m_score);
                const p_score_val = p_result.score_val;
                const p_matched = p_result.matched;

                var m_cell: ScoreCell = undefined;
                if (charEql(CharType, NeedleCharType, self.haystack[col], needle[0])) {
                    m_cell = .{
                        .score_val = @as(u16, self.bonus[col]) * score.BONUS_FIRST_CHAR_MULTIPLIER +
                            score.SCORE_MATCH +
                            prefix_bonus / score.PREFIX_BONUS_SCALE,
                        .matched = false,
                        .consecutive_bonus = self.bonus[col],
                    };
                } else {
                    m_cell = ScoreCell.UNMATCHED;
                }

                self.matrix_cells[col - row_off].set(p_matched, m_cell.matched);

                prefix_bonus -|= score.PENALTY_GAP_EXTENSION;
                prev_p_score = p_score_val;
                prev_m_score = m_cell.score_val;
            }

            // Process remaining columns and compute next row cells
            while (col < self.haystack.len) : (col += 1) {
                const p_result = pScore(prev_p_score, prev_m_score);
                const p_score_val = p_result.score_val;
                const p_matched = p_result.matched;

                var m_cell: ScoreCell = undefined;
                if (charEql(CharType, NeedleCharType, self.haystack[col], needle[0])) {
                    m_cell = .{
                        .score_val = @as(u16, self.bonus[col]) * score.BONUS_FIRST_CHAR_MULTIPLIER +
                            score.SCORE_MATCH +
                            prefix_bonus / score.PREFIX_BONUS_SCALE,
                        .matched = false,
                        .consecutive_bonus = self.bonus[col],
                    };
                } else {
                    m_cell = ScoreCell.UNMATCHED;
                }

                // Store score for next needle char
                if (needle.len > 1 and col + 1 < self.haystack.len) {
                    if (charEql(CharType, NeedleCharType, self.haystack[col + 1], needle[1])) {
                        self.current_row[col - row_off] = nextMCell(p_score_val, self.bonus[col + 1], m_cell);
                    } else {
                        self.current_row[col - row_off] = ScoreCell.UNMATCHED;
                    }
                }

                self.matrix_cells[col - row_off].set(p_matched, m_cell.matched);

                prefix_bonus -|= score.PENALTY_GAP_EXTENSION;
                prev_p_score = p_score_val;
                prev_m_score = m_cell.score_val;
            }
        }

        /// Populate the full matrix and return total cells used
        pub fn populateMatrix(
            self: *Self,
            comptime NeedleCharType: type,
            needle: []const NeedleCharType,
        ) usize {
            const haystack_len = self.haystack.len;

            if (needle.len <= 2) {
                return haystack_len;
            }

            var matrix_offset: usize = haystack_len;

            var needle_idx: usize = 1;
            var needle_char = needle[1];
            var row_off = self.row_offs[1];

            while (needle_idx + 1 < needle.len) {
                const next_needle_idx = needle_idx + 1;
                const next_needle_char = needle[next_needle_idx];
                const next_row_off = self.row_offs[next_needle_idx];

                self.scoreRow(
                    NeedleCharType,
                    next_needle_char,
                    row_off,
                    next_row_off,
                    @intCast(needle_idx),
                    matrix_offset,
                );

                const row_width = haystack_len + needle_idx - row_off;
                matrix_offset += row_width;

                needle_idx = next_needle_idx;
                needle_char = next_needle_char;
                row_off = next_row_off;
            }

            return matrix_offset;
        }

        fn scoreRow(
            self: *Self,
            comptime NeedleCharType: type,
            next_needle_char: NeedleCharType,
            row_off: u16,
            next_row_off: u16,
            needle_idx: u16,
            matrix_offset: usize,
        ) void {
            const adjusted_next_row_off = next_row_off - 1;
            const relative_row_off = row_off - needle_idx;
            const next_relative_row_off = adjusted_next_row_off - needle_idx;

            var prev_p_score: u16 = 0;
            var prev_m_score: u16 = 0;

            // Process skipped columns
            var col = row_off;
            while (col < adjusted_next_row_off) : (col += 1) {
                const rel_col = col - row_off;
                const p_result = pScore(prev_p_score, prev_m_score);

                const m_cell = self.current_row[relative_row_off + rel_col];
                self.matrix_cells[matrix_offset + rel_col].set(p_result.matched, m_cell.matched);

                prev_p_score = p_result.score_val;
                prev_m_score = m_cell.score_val;
            }

            // Process remaining columns
            while (col < self.haystack.len) : (col += 1) {
                const rel_col = col - row_off;
                const p_result = pScore(prev_p_score, prev_m_score);

                const m_cell = self.current_row[relative_row_off + rel_col];

                // Update current_row for next iteration
                if (col + 1 < self.haystack.len and
                    charEql(CharType, NeedleCharType, self.haystack[col + 1], next_needle_char))
                {
                    self.current_row[next_relative_row_off + rel_col] =
                        nextMCell(p_result.score_val, self.bonus[col + 1], m_cell);
                } else {
                    self.current_row[next_relative_row_off + rel_col] = ScoreCell.UNMATCHED;
                }

                self.matrix_cells[matrix_offset + rel_col].set(p_result.matched, m_cell.matched);

                prev_p_score = p_result.score_val;
                prev_m_score = m_cell.score_val;
            }
        }

        /// Reconstruct the optimal matching path and fill indices
        pub fn reconstructOptimalPath(
            self: *const Self,
            max_score_end: u16,
            allocator: std.mem.Allocator,
            indices: *std.ArrayListUnmanaged(u32),
            matrix_len: usize,
            start: u32,
        ) void {
            const needle_len = self.row_offs.len;
            const start_idx = indices.items.len;
            indices.resize(allocator, start_idx + needle_len) catch return;
            const result_indices = indices.items[start_idx..];

            const last_row_off = self.row_offs[needle_len - 1];
            result_indices[needle_len - 1] = start + @as(u32, max_score_end) + @as(u32, last_row_off);

            if (needle_len == 1) return;

            var matrix_cells = self.matrix_cells[0..matrix_len];
            const haystack_len = self.haystack.len;

            var row_idx = needle_len - 2;
            var row_off = self.row_offs[row_idx];
            var relative_off = @as(usize, row_off) - row_idx;

            // Calculate row width for this needle position
            const row_width = haystack_len + row_idx - row_off;
            if (row_width > matrix_cells.len) return;

            var row_end = matrix_cells.len - row_width;
            var row = matrix_cells[row_end..matrix_cells.len];
            matrix_cells = matrix_cells[0..row_end];

            var col = max_score_end;
            const relative_last_row_off = @as(usize, last_row_off) + 1 - needle_len;
            var matched = self.current_row[col + relative_last_row_off].matched;
            col += last_row_off - row_off - 1;

            while (true) {
                if (matched) {
                    result_indices[row_idx] = start + col + row_off;
                }

                if (col >= row.len) return; // Bounds check
                const next_matched = row[col].get(matched);

                if (matched) {
                    if (row_idx == 0) break;
                    row_idx -= 1;
                    const next_row_off = self.row_offs[row_idx];
                    col += row_off - next_row_off;
                    row_off = next_row_off;
                    relative_off = @as(usize, row_off) - row_idx;

                    // Calculate row width for this needle position
                    const next_row_width = haystack_len + row_idx - row_off;
                    if (next_row_width > matrix_cells.len) return;

                    row_end = matrix_cells.len - next_row_width;
                    row = matrix_cells[row_end..matrix_cells.len];
                    matrix_cells = matrix_cells[0..row_end];
                }

                if (col == 0) break;
                col -= 1;
                matched = next_matched;
            }
        }
    };
}

/// Calculate P-matrix score (skip score)
fn pScore(prev_p_score: u16, prev_m_score: u16) struct { score_val: u16, matched: bool } {
    const score_match = prev_m_score -| score.PENALTY_GAP_START;
    const score_skip = prev_p_score -| score.PENALTY_GAP_EXTENSION;
    if (score_match > score_skip) {
        return .{ .score_val = score_match, .matched = true };
    } else {
        return .{ .score_val = score_skip, .matched = false };
    }
}

/// Calculate next M-matrix cell (match score)
fn nextMCell(p_score_val: u16, bonus: u8, m_cell: ScoreCell) ScoreCell {
    if (m_cell.eql(ScoreCell.UNMATCHED)) {
        return .{
            .score_val = p_score_val + bonus + score.SCORE_MATCH,
            .matched = false,
            .consecutive_bonus = bonus,
        };
    }

    var consecutive_bonus = @max(@as(u16, m_cell.consecutive_bonus), score.BONUS_CONSECUTIVE);
    if (bonus >= score.BONUS_BOUNDARY and bonus > consecutive_bonus) {
        consecutive_bonus = bonus;
    }

    const score_match = m_cell.score_val + @max(consecutive_bonus, @as(u16, bonus));
    const score_skip = p_score_val + bonus;

    if (score_match > score_skip) {
        return .{
            .score_val = score_match + score.SCORE_MATCH,
            .matched = true,
            .consecutive_bonus = @truncate(consecutive_bonus),
        };
    } else {
        return .{
            .score_val = score_skip + score.SCORE_MATCH,
            .matched = false,
            .consecutive_bonus = bonus,
        };
    }
}

fn charEql(comptime H: type, comptime N: type, h: H, n: N) bool {
    if (H == N) {
        return h == n;
    }
    // Cross-type comparison
    if (H == u8 and (N == u21 or N == u32)) {
        return h == @as(H, @truncate(n));
    }
    if ((H == u21 or H == u32) and N == u8) {
        return @as(N, @truncate(h)) == n;
    }
    return h == n;
}

pub const MatrixSlab = struct {
    memory: []align(8) u8,
    allocator: Allocator,

    const SLAB_SIZE: usize = 256 * 1024; // 256kb should be enough

    pub fn init(allocator: Allocator) !MatrixSlab {
        const memory = try allocator.alignedAlloc(u8, .@"8", SLAB_SIZE);
        @memset(memory, 0);
        return .{
            .memory = memory,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MatrixSlab) void {
        self.allocator.free(self.memory);
    }

    /// Allocate a view into the slab for matching
    pub fn alloc(
        self: *MatrixSlab,
        comptime CharType: type,
        haystack_slice: []const CharType,
        needle_len: usize,
    ) ?MatcherDataView(CharType) {
        const haystack_len = haystack_slice.len;
        const cells = haystack_len * needle_len;

        // Check limits
        if (cells > MAX_MATRIX_SIZE or
            haystack_len > MAX_HAYSTACK_LEN or
            needle_len > MAX_NEEDLE_LEN)
        {
            return null;
        }

        // Calculate memory layout
        const char_size = @sizeOf(CharType);
        const haystack_bytes = haystack_len * char_size;
        const bonus_bytes = haystack_len;
        const row_offs_bytes = needle_len * @sizeOf(u16);
        // current_row needs to be big enough for sliding window across all rows
        // Each row can span from its row_off to haystack_len, and we need space
        // for both current row and next row values indexed relative to their offsets
        // Use 2 * haystack_len to be safe for the sliding window approach
        const score_cells_count = haystack_len * 2;
        const score_bytes = score_cells_count * @sizeOf(ScoreCell);
        // Use a more conservative bound for matrix cells
        // The sparse matrix stores cells for each row from row_off to haystack_len
        // Worst case is haystack_len * needle_len
        const matrix_cells_count = haystack_len * needle_len;
        const matrix_bytes = matrix_cells_count * @sizeOf(MatrixCell);

        const total_bytes = haystack_bytes + bonus_bytes + row_offs_bytes + score_bytes + matrix_bytes;

        if (total_bytes > self.memory.len) {
            return null;
        }

        // Slice out each component
        var offset: usize = 0;

        const haystack_ptr: [*]CharType = @ptrCast(@alignCast(self.memory[offset..].ptr));
        const haystack = haystack_ptr[0..haystack_len];
        @memcpy(haystack, haystack_slice);
        offset += haystack_bytes;

        const bonus = self.memory[offset..][0..haystack_len];
        offset += bonus_bytes;

        const row_offs_ptr: [*]u16 = @ptrCast(@alignCast(self.memory[offset..].ptr));
        const row_offs = row_offs_ptr[0..needle_len];
        offset += row_offs_bytes;

        const score_ptr: [*]ScoreCell = @ptrCast(@alignCast(self.memory[offset..].ptr));
        const current_row = score_ptr[0..score_cells_count];
        offset += score_bytes;

        const matrix_ptr: [*]MatrixCell = @ptrCast(@alignCast(self.memory[offset..].ptr));
        const matrix_cells = matrix_ptr[0..matrix_cells_count];

        return .{
            .haystack = haystack,
            .bonus = bonus,
            .current_row = current_row,
            .row_offs = row_offs,
            .matrix_cells = matrix_cells,
        };
    }
};

test "score cell" {
    const cell = ScoreCell{ .score_val = 100, .consecutive_bonus = 5, .matched = true };
    try std.testing.expect(cell.eql(cell));
    try std.testing.expect(!cell.eql(ScoreCell.UNMATCHED));
}

test "matrix cell" {
    var cell = MatrixCell{};
    cell.set(true, false);
    try std.testing.expect(cell.get(false)); // p_match
    try std.testing.expect(!cell.get(true)); // m_match

    cell.set(false, true);
    try std.testing.expect(!cell.get(false));
    try std.testing.expect(cell.get(true));
}

test "matrix slab allocation" {
    var slab = try MatrixSlab.init(std.testing.allocator);
    defer slab.deinit();

    const haystack = "hello world";
    const view = slab.alloc(u8, haystack, 3);
    try std.testing.expect(view != null);
    try std.testing.expectEqualSlices(u8, haystack, view.?.haystack);
}
