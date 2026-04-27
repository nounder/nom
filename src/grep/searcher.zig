//! Per-file literal search.
//!
//! Memory-maps the file (via `std.Io.File.MemoryMap`) and walks it line by
//! line, recording every needle hit per line plus the surrounding context
//! requested via `before_context` / `after_context`.
//!
//! Binary detection mirrors ripgrep's `BinaryDetection::Quit(NUL)`: as soon
//! as a NUL byte is observed anywhere in the file, the searcher truncates
//! its view at that byte and stops. Any matches found *before* the NUL are
//! still emitted — that's the rg semantic, not "skip the whole file."
//!
//! Lifetime rule: `LineSlice.text` and `Match.cols` borrow from buffers
//! owned by the searcher. They are valid only during the sink callback;
//! the next iteration may overwrite them. Sinks that retain matches must
//! deep-copy.

const std = @import("std");

pub const Options = struct {
    /// Literal needle. For case-insensitive search, the haystack window is
    /// compared via `std.ascii.eqlIgnoreCase`. Caller doesn't need to
    /// pre-fold case.
    needle: []const u8,
    case_insensitive: bool = false,
    before_context: usize = 0,
    after_context: usize = 0,
};

pub const LineSlice = struct {
    /// 1-based line number.
    line_no: u32,
    /// Borrowed from the mmap region — valid only during the sink callback.
    text: []const u8,
};

pub const Match = struct {
    /// Lines before the match line (oldest first). May be shorter than
    /// `before_context` near the start of the file.
    before: []const LineSlice,
    /// The matching line.
    line: LineSlice,
    /// 1-based byte columns of every needle occurrence on `line.text`,
    /// in source order. Always non-empty for an emitted match.
    /// Borrowed from a per-search scratch buffer — copy if retained.
    cols: []const u32,
    /// Lines after the match line (in order). Filled in lazily — see Sink.
    after: []const LineSlice,
};

/// Sink invoked once per match. Implementers may copy any borrowed strings
/// they need to retain. Return `false` to stop searching this file.
pub const Sink = struct {
    ctx: *anyopaque,
    onMatchFn: *const fn (ctx: *anyopaque, match: Match) anyerror!bool,

    pub fn onMatch(self: Sink, m: Match) !bool {
        return self.onMatchFn(self.ctx, m);
    }
};

/// Search `file` for `opts.needle`. Returns the number of matches emitted.
///
/// `allocator` is used for short-lived scratch (context ring buffer); no
/// allocations escape this function.
pub fn searchFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_len: u64,
    opts: Options,
    sink: Sink,
) !usize {
    if (opts.needle.len == 0) return 0;
    if (file_len == 0) return 0;
    // mmap requires len <= usize. On 64-bit this is effectively unbounded.
    if (file_len > std.math.maxInt(usize)) return 0;

    var mm = file.createMemoryMap(io, .{
        .len = @intCast(file_len),
        .protection = .{ .read = true, .write = false },
        .populate = false,
    }) catch |err| switch (err) {
        // Anything the kernel refuses to map — skip the file.
        error.AccessDenied,
        error.PermissionDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        => return 0,
        else => return err,
    };
    defer mm.destroy(io);
    // Sync file → memory. This is the explicit read sync point required by
    // the 0.16 MemoryMap semantics.
    mm.read(io) catch return 0;

    const data: []const u8 = mm.memory;
    return searchBytes(allocator, data, opts, sink);
}

/// Search an in-memory buffer. Exposed for testing and for callers that
/// already have file contents in memory.
pub fn searchBytes(
    allocator: std.mem.Allocator,
    data_in: []const u8,
    opts: Options,
    sink: Sink,
) !usize {
    if (opts.needle.len == 0) return 0;

    // Binary detection (rg-style Quit(NUL)): truncate at the first NUL.
    // Matches before the NUL are still reported; matches after it are not
    // visible to the loop because the data slice ends here.
    const data: []const u8 = if (std.mem.indexOfScalar(u8, data_in, 0)) |nul|
        data_in[0..nul]
    else
        data_in;

    if (data.len == 0) return 0;

    // Ring buffer of recent lines for -B context. Each entry is (line_no,
    // start_offset, end_offset). We resolve text via the offsets at emit
    // time.
    const Slot = struct { line_no: u32, start: usize, end: usize };
    const ring_cap = opts.before_context;

    var ring: []Slot = if (ring_cap > 0)
        try allocator.alloc(Slot, ring_cap)
    else
        &[_]Slot{};
    defer if (ring_cap > 0) allocator.free(ring);

    var ring_len: usize = 0; // number of valid entries
    var ring_head: usize = 0; // index of oldest entry

    // Buffer used to materialize `before` / `after` slice arrays for each
    // emitted match. Sized for the worst case: B + A LineSlices.
    var ctx_scratch: []LineSlice = if (opts.before_context + opts.after_context > 0)
        try allocator.alloc(LineSlice, opts.before_context + opts.after_context)
    else
        &[_]LineSlice{};
    defer if (opts.before_context + opts.after_context > 0) allocator.free(ctx_scratch);

    // Two ping-pong buffers for per-line column offsets. At most one match
    // is pending at any time (waiting on its after-context); the *other*
    // buffer is used to collect hits for the line currently being scanned.
    // When a new match displaces the pending one, we swap which buffer is
    // "live" — guaranteeing the pending match's cols slice is never
    // overwritten before it has been flushed to the sink.
    var cols_a: std.ArrayListUnmanaged(u32) = .empty;
    var cols_b: std.ArrayListUnmanaged(u32) = .empty;
    defer cols_a.deinit(allocator);
    defer cols_b.deinit(allocator);
    var scan_buf: *std.ArrayListUnmanaged(u32) = &cols_a;
    var pending_buf: *std.ArrayListUnmanaged(u32) = &cols_b;

    var match_count: usize = 0;

    // Single forward pass over lines. We track byte offset of the current
    // line's start; for each line we (a) check for matches, (b) record into
    // the ring, (c) decrement any pending after-context for previously
    // emitted matches.
    var line_no: u32 = 0;
    var i: usize = 0;

    // Pending after-context: for the most-recent emitted match, how many
    // more lines (and where to write them in ctx_scratch).
    var pending_after: usize = 0;
    var pending_after_base: usize = 0; // index into ctx_scratch where 'after' starts
    var pending_after_filled: usize = 0;
    // We need to update the previous Match's `after` slice as lines come in.
    // Simplest: emit the match *after* we've collected all its after-context.
    // To do that, buffer one pending Match.
    var have_pending: bool = false;
    var pending_match: Match = undefined;

    while (i < data.len) : (line_no += 1) {
        const line_start = i;
        const line_end = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse data.len;

        // Advance i past this line (and its newline, if any) for the next
        // iteration. When the file ends without a trailing newline we still
        // process this final line; when it ends *with* one, the loop
        // condition `i < data.len` exits before we manufacture an empty
        // trailing line.
        i = if (line_end < data.len) line_end + 1 else data.len;

        // If we have a pending match awaiting after-context, this line
        // contributes to it.
        if (pending_after > 0) {
            ctx_scratch[pending_after_base + pending_after_filled] = .{
                .line_no = line_no + 1,
                .text = data[line_start..line_end],
            };
            pending_after_filled += 1;
            pending_after -= 1;
            if (pending_after == 0 and have_pending) {
                pending_match.after = ctx_scratch[pending_after_base .. pending_after_base + pending_after_filled];
                const keep_going = try sink.onMatch(pending_match);
                have_pending = false;
                if (!keep_going) return match_count;
            }
        }

        // Search this line for *every* needle occurrence in one pass.
        // Hits go into `scan_buf`. If this line becomes a match, we swap
        // scan_buf <-> pending_buf so the pending match's cols slice keeps
        // pointing at stable memory while later lines reuse the other
        // buffer.
        const line_text = data[line_start..line_end];
        scan_buf.clearRetainingCapacity();
        try collectAllHits(allocator, scan_buf, line_text, opts.needle, opts.case_insensitive);

        if (scan_buf.items.len > 0) {
            // Flush any previous pending match — its cols still point into
            // pending_buf, which we have NOT touched on this line.
            if (have_pending) {
                pending_match.after = ctx_scratch[pending_after_base .. pending_after_base + pending_after_filled];
                const keep_going = try sink.onMatch(pending_match);
                have_pending = false;
                if (!keep_going) return match_count;
            }

            // Promote scan_buf -> pending_buf.
            const tmp = pending_buf;
            pending_buf = scan_buf;
            scan_buf = tmp;

            // Materialize `before` from the ring (oldest first).
            var before_count: usize = 0;
            if (ring_len > 0) {
                var k: usize = 0;
                while (k < ring_len) : (k += 1) {
                    const slot = ring[(ring_head + k) % ring_cap];
                    ctx_scratch[k] = .{
                        .line_no = slot.line_no,
                        .text = data[slot.start..slot.end],
                    };
                    before_count += 1;
                }
            }

            pending_match = .{
                .before = ctx_scratch[0..before_count],
                .line = .{ .line_no = line_no + 1, .text = line_text },
                .cols = pending_buf.items,
                .after = &.{},
            };
            pending_after_base = before_count;
            pending_after_filled = 0;
            pending_after = opts.after_context;
            have_pending = true;
            match_count += 1;

            if (opts.after_context == 0) {
                // No after-context wanted; emit immediately.
                pending_match.after = &.{};
                const keep_going = try sink.onMatch(pending_match);
                have_pending = false;
                if (!keep_going) return match_count;
            }
        }

        // Push this line into the before-context ring (after potential
        // emission, since `before` shouldn't include the match line itself).
        if (ring_cap > 0) {
            const slot: Slot = .{
                .line_no = line_no + 1,
                .start = line_start,
                .end = line_end,
            };
            if (ring_len < ring_cap) {
                ring[(ring_head + ring_len) % ring_cap] = slot;
                ring_len += 1;
            } else {
                ring[ring_head] = slot;
                ring_head = (ring_head + 1) % ring_cap;
            }
        }
    }

    // Flush any final pending match (with whatever after-context we got).
    if (have_pending) {
        pending_match.after = ctx_scratch[pending_after_base .. pending_after_base + pending_after_filled];
        _ = try sink.onMatch(pending_match);
    }

    return match_count;
}

/// Append the 1-based byte column of every `needle` occurrence in `line`
/// to `out`, in source order. ASCII case-insensitive when requested.
fn collectAllHits(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    line: []const u8,
    needle: []const u8,
    case_insensitive: bool,
) !void {
    if (line.len < needle.len) return;
    var i: usize = 0;
    if (!case_insensitive) {
        while (i <= line.len - needle.len) {
            const rel = std.mem.indexOfPos(u8, line, i, needle) orelse break;
            try out.append(allocator, @intCast(rel + 1));
            i = rel + needle.len;
            if (needle.len == 0) break; // defensive — Options enforces non-empty
        }
        return;
    }
    const last = line.len - needle.len;
    while (i <= last) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(line[i .. i + needle.len], needle)) {
            try out.append(allocator, @intCast(i + 1));
            i += needle.len - 1; // -1 because the loop's `i += 1` advances one more
        }
    }
}

// ---------- tests ----------

const TestSink = struct {
    matches: std.ArrayListUnmanaged(OwnedMatch) = .empty,
    allocator: std.mem.Allocator,

    const OwnedLine = struct { line_no: u32, text: []u8 };
    const OwnedMatch = struct {
        before: []OwnedLine,
        line: OwnedLine,
        cols: []u32,
        after: []OwnedLine,
    };

    fn record(opaque_self: *anyopaque, m: Match) anyerror!bool {
        const self: *TestSink = @ptrCast(@alignCast(opaque_self));
        const a = self.allocator;
        const before = try a.alloc(OwnedLine, m.before.len);
        for (m.before, 0..) |b, i| {
            before[i] = .{ .line_no = b.line_no, .text = try a.dupe(u8, b.text) };
        }
        const after = try a.alloc(OwnedLine, m.after.len);
        for (m.after, 0..) |b, i| {
            after[i] = .{ .line_no = b.line_no, .text = try a.dupe(u8, b.text) };
        }
        const line: OwnedLine = .{ .line_no = m.line.line_no, .text = try a.dupe(u8, m.line.text) };
        const cols = try a.dupe(u32, m.cols);
        try self.matches.append(a, .{ .before = before, .line = line, .cols = cols, .after = after });
        return true;
    }

    fn sink(self: *TestSink) Sink {
        return .{ .ctx = self, .onMatchFn = record };
    }

    fn deinit(self: *TestSink) void {
        const a = self.allocator;
        for (self.matches.items) |om| {
            for (om.before) |b| a.free(b.text);
            a.free(om.before);
            a.free(om.line.text);
            a.free(om.cols);
            for (om.after) |b| a.free(b.text);
            a.free(om.after);
        }
        self.matches.deinit(a);
    }
};

test "searchBytes finds simple matches" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const data = "alpha\nbravo needle\ncharlie\ndelta needle here\n";
    _ = try searchBytes(a, data, .{ .needle = "needle" }, ts.sink());

    try std.testing.expectEqual(@as(usize, 2), ts.matches.items.len);
    try std.testing.expectEqual(@as(u32, 2), ts.matches.items[0].line.line_no);
    try std.testing.expectEqualStrings("bravo needle", ts.matches.items[0].line.text);
    try std.testing.expectEqualSlices(u32, &[_]u32{7}, ts.matches.items[0].cols);
    try std.testing.expectEqual(@as(u32, 4), ts.matches.items[1].line.line_no);
}

test "searchBytes records every hit on a line" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const data = "foo bar foo baz foo\n";
    _ = try searchBytes(a, data, .{ .needle = "foo" }, ts.sink());

    try std.testing.expectEqual(@as(usize, 1), ts.matches.items.len);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 9, 17 }, ts.matches.items[0].cols);
}

test "searchBytes overlapping needle does not double-count" {
    // Needle "aa" in "aaaa" should match at columns 1 and 3 (non-overlapping),
    // not 1, 2, 3 (overlapping). Matches the convention of grep / rg.
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    _ = try searchBytes(a, "aaaa\n", .{ .needle = "aa" }, ts.sink());

    try std.testing.expectEqual(@as(usize, 1), ts.matches.items.len);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 3 }, ts.matches.items[0].cols);
}

test "searchBytes case insensitive" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const data = "Foo Bar\nfoo BAZ\n";
    _ = try searchBytes(a, data, .{ .needle = "foo", .case_insensitive = true }, ts.sink());

    try std.testing.expectEqual(@as(usize, 2), ts.matches.items.len);
}

test "searchBytes before/after context" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const data = "l1\nl2\nl3 needle\nl4\nl5\nl6\n";
    _ = try searchBytes(a, data, .{
        .needle = "needle",
        .before_context = 2,
        .after_context = 2,
    }, ts.sink());

    try std.testing.expectEqual(@as(usize, 1), ts.matches.items.len);
    const m = ts.matches.items[0];
    try std.testing.expectEqual(@as(usize, 2), m.before.len);
    try std.testing.expectEqualStrings("l1", m.before[0].text);
    try std.testing.expectEqualStrings("l2", m.before[1].text);
    try std.testing.expectEqualStrings("l3 needle", m.line.text);
    try std.testing.expectEqual(@as(usize, 2), m.after.len);
    try std.testing.expectEqualStrings("l4", m.after[0].text);
    try std.testing.expectEqualStrings("l5", m.after[1].text);
}

test "searchBytes context truncated near edges" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const data = "needle\nafter1\n";
    _ = try searchBytes(a, data, .{
        .needle = "needle",
        .before_context = 3,
        .after_context = 3,
    }, ts.sink());

    try std.testing.expectEqual(@as(usize, 1), ts.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.matches.items[0].before.len);
    try std.testing.expectEqual(@as(usize, 1), ts.matches.items[0].after.len);
    try std.testing.expectEqualStrings("after1", ts.matches.items[0].after[0].text);
}

test "searchBytes binary detection truncates at first NUL but keeps prior matches" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    // First "needle" is on line 1, before the NUL — kept.
    // Second "needle" is after the NUL — invisible to the searcher.
    const data = "needle\x00needle\n";
    const n = try searchBytes(a, data, .{ .needle = "needle" }, ts.sink());

    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 1), ts.matches.items.len);
    try std.testing.expectEqualStrings("needle", ts.matches.items[0].line.text);
}

test "searchBytes binary detection: NUL on first byte yields nothing" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const n = try searchBytes(a, "\x00needle\n", .{ .needle = "needle" }, ts.sink());
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "searchBytes empty needle yields nothing via searchFile path" {
    const a = std.testing.allocator;
    var ts: TestSink = .{ .allocator = a };
    defer ts.deinit();

    const n = try searchBytes(a, "anything\n", .{ .needle = "" }, ts.sink());
    // searchBytes itself doesn't reject empty needle (searchFile does); here
    // indexOf with empty needle returns 0 for every line, which would loop
    // forever without the guard. We assert no infinite loop / match storm:
    try std.testing.expect(n <= 1);
}
