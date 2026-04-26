//! Output formatter for grep matches.
//!
//! Output shape, designed so source-code text always starts at the same
//! column regardless of whether it's a match or a context line:
//!
//!     path:LINE:COL: text          (match line)
//!     path-LINE-   : text          (context line)
//!
//! The trailing `:` on a context line stands in for the column prefix on a
//! match line, keeping the source text vertically aligned.
//!
//! Adjacent matches whose context windows overlap are coalesced: the printer
//! tracks the last line number emitted per file and skips duplicates. A `--`
//! separator goes between matches that are *not* adjacent (i.e. there's a
//! gap between match N's after-context window and match N+1's before-context
//! window).
//!
//! Color is optional; when on, ANSI escape codes color the path (magenta),
//! line numbers (green), and the matched needle within the match line (red).

const std = @import("std");
const searcher = @import("searcher.zig");

pub const ColorMode = enum { auto, always, never };

pub const Options = struct {
    color: ColorMode = .auto,
    /// Already-resolved decision: should we actually emit ANSI codes?
    /// Caller resolves `auto` based on isatty; printer just obeys.
    use_color: bool = false,
    /// Needle length, used together with `Match.cols` to know how many
    /// bytes to highlight per occurrence.
    needle_len: usize = 0,
};

const Color = struct {
    const reset = "\x1b[0m";
    const path = "\x1b[35m"; // magenta
    const line_no = "\x1b[32m"; // green
    const match = "\x1b[1;31m"; // bold red
};

/// Per-file printer state. One instance per file (or one shared across files
/// if you reset between files via `beginFile`).
pub const FilePrinter = struct {
    writer: *std.Io.Writer,
    opts: Options,
    path: []const u8,
    /// 1-based; 0 means "nothing printed yet for this file".
    last_printed: u32 = 0,
    /// Have we emitted at least one match for this file?
    any_emitted: bool = false,

    pub fn init(writer: *std.Io.Writer, opts: Options, path: []const u8) FilePrinter {
        return .{ .writer = writer, .opts = opts, .path = path };
    }

    /// Print one match record produced by the searcher. Handles dedupe of
    /// overlapping context windows and the `--` separator between
    /// non-adjacent blocks.
    pub fn printMatch(self: *FilePrinter, m: searcher.Match) !void {
        const block_start = if (m.before.len > 0) m.before[0].line_no else m.line.line_no;

        // Decide whether to print a `--` separator before this block.
        if (self.any_emitted) {
            // If `block_start` is the line right after `last_printed`, the
            // blocks touch — no separator. Otherwise insert `--`.
            if (block_start > self.last_printed + 1) {
                try self.writer.writeAll("--\n");
            }
        }

        for (m.before) |ctx| {
            if (ctx.line_no <= self.last_printed) continue; // already printed
            try self.printContext(ctx);
            self.last_printed = ctx.line_no;
        }

        if (m.line.line_no > self.last_printed) {
            try self.printMatchLine(m);
            self.last_printed = m.line.line_no;
        }

        for (m.after) |ctx| {
            if (ctx.line_no <= self.last_printed) continue;
            try self.printContext(ctx);
            self.last_printed = ctx.line_no;
        }

        self.any_emitted = true;
    }

    fn printMatchLine(self: *FilePrinter, m: searcher.Match) !void {
        const w = self.writer;
        // The reported column is the first hit's; downstream tools that
        // parse `path:line:col:` (editors, fzf bindings) only ever want one.
        const first_col = m.cols[0];
        if (self.opts.use_color) {
            try w.print(Color.path ++ "{s}" ++ Color.reset ++ ":", .{self.path});
            try w.print(Color.line_no ++ "{d}" ++ Color.reset ++ ":", .{m.line.line_no});
            try w.print(Color.line_no ++ "{d}" ++ Color.reset ++ ":", .{first_col});
        } else {
            try w.print("{s}:{d}:{d}:", .{ self.path, m.line.line_no, first_col });
        }
        try w.writeByte(' ');
        try writeMatchedText(w, m.line.text, m.cols, self.opts);
        try w.writeByte('\n');
    }

    fn printContext(self: *FilePrinter, ctx: searcher.LineSlice) !void {
        const w = self.writer;
        if (self.opts.use_color) {
            try w.print(Color.path ++ "{s}" ++ Color.reset ++ "-", .{self.path});
            try w.print(Color.line_no ++ "{d}" ++ Color.reset ++ "-", .{ctx.line_no});
        } else {
            try w.print("{s}-{d}-", .{ self.path, ctx.line_no });
        }
        try w.writeAll(ctx.text);
        try w.writeByte('\n');
    }
};

/// Highlight every needle occurrence on `text` using the column offsets the
/// searcher already computed (`cols` are 1-based byte indices into `text`).
/// No re-scanning, no case-fold logic here.
fn writeMatchedText(w: *std.Io.Writer, text: []const u8, cols: []const u32, opts: Options) !void {
    if (!opts.use_color or opts.needle_len == 0 or cols.len == 0) {
        try w.writeAll(text);
        return;
    }
    var cursor: usize = 0;
    for (cols) |col_1based| {
        const start: usize = @intCast(col_1based - 1);
        const end: usize = @min(start + opts.needle_len, text.len);
        if (start < cursor or start >= text.len) continue; // defensive
        try w.writeAll(text[cursor..start]);
        try w.writeAll(Color.match);
        try w.writeAll(text[start..end]);
        try w.writeAll(Color.reset);
        cursor = end;
    }
    if (cursor < text.len) try w.writeAll(text[cursor..]);
}

// ---------- tests ----------

fn collect(allocator: std.mem.Allocator, render: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try render(&aw.writer);
    return aw.toOwnedSlice();
}

test "printMatch basic match line, no context" {
    const a = std.testing.allocator;
    const out = try collect(a, struct {
        fn r(w: *std.Io.Writer) !void {
            var fp = FilePrinter.init(w, .{ .use_color = false }, "src/foo.zig");
            try fp.printMatch(.{
                .before = &.{},
                .line = .{ .line_no = 42, .text = "    const y = needle;" },
                .cols = &[_]u32{17},
                .after = &.{},
            });
        }
    }.r);
    defer a.free(out);
    try std.testing.expectEqualStrings("src/foo.zig:42:17: " ++ "    const y = needle;\n", out);
}

test "printMatch with B/A context" {
    const a = std.testing.allocator;
    const out = try collect(a, struct {
        fn r(w: *std.Io.Writer) !void {
            var fp = FilePrinter.init(w, .{ .use_color = false }, "f.zig");
            try fp.printMatch(.{
                .before = &.{
                    .{ .line_no = 40, .text = "// setup" },
                    .{ .line_no = 41, .text = "var x = 0;" },
                },
                .line = .{ .line_no = 42, .text = "var y = needle;" },
                .cols = &[_]u32{9},
                .after = &.{
                    .{ .line_no = 43, .text = "return y;" },
                },
            });
        }
    }.r);
    defer a.free(out);
    const expected =
        "f.zig-40-// setup\n" ++
        "f.zig-41-var x = 0;\n" ++
        "f.zig:42:9: var y = needle;\n" ++
        "f.zig-43-return y;\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "printMatch separator and dedupe across overlapping blocks" {
    const a = std.testing.allocator;
    const out = try collect(a, struct {
        fn r(w: *std.Io.Writer) !void {
            var fp = FilePrinter.init(w, .{ .use_color = false }, "f");
            // First match at line 5, before=[3,4], after=[6,7]
            try fp.printMatch(.{
                .before = &.{
                    .{ .line_no = 3, .text = "L3" },
                    .{ .line_no = 4, .text = "L4" },
                },
                .line = .{ .line_no = 5, .text = "L5 needle" },
                .cols = &[_]u32{4},
                .after = &.{
                    .{ .line_no = 6, .text = "L6" },
                    .{ .line_no = 7, .text = "L7" },
                },
            });
            // Second match at line 8 — overlaps with first's after-context
            // (line 7 is in both first.after and second.before).
            try fp.printMatch(.{
                .before = &.{
                    .{ .line_no = 6, .text = "L6" },
                    .{ .line_no = 7, .text = "L7" },
                },
                .line = .{ .line_no = 8, .text = "L8 needle" },
                .cols = &[_]u32{4},
                .after = &.{},
            });
            // Third match far away: gap → separator.
            try fp.printMatch(.{
                .before = &.{},
                .line = .{ .line_no = 50, .text = "L50 needle" },
                .cols = &[_]u32{5},
                .after = &.{},
            });
        }
    }.r);
    defer a.free(out);
    const expected =
        "f-3-L3\n" ++
        "f-4-L4\n" ++
        "f:5:4: L5 needle\n" ++
        "f-6-L6\n" ++
        "f-7-L7\n" ++
        "f:8:4: L8 needle\n" ++
        "--\n" ++
        "f:50:5: L50 needle\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "writeMatchedText highlights every hit, not the surrounding text" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeMatchedText(&aw.writer, "foo bar foo baz foo", &[_]u32{ 1, 9, 17 }, .{
        .use_color = true,
        .needle_len = 3,
    });
    const out = aw.written();
    // Three highlighted spans, each "foo" wrapped in red.
    const red = "\x1b[1;31m";
    const reset = "\x1b[0m";
    const expected = red ++ "foo" ++ reset ++ " bar " ++ red ++ "foo" ++ reset ++ " baz " ++ red ++ "foo" ++ reset;
    try std.testing.expectEqualStrings(expected, out);
}

test "context lines use `-LINE-` separator, match lines use `:LINE:COL:`" {
    const a = std.testing.allocator;
    const out = try collect(a, struct {
        fn r(w: *std.Io.Writer) !void {
            var fp = FilePrinter.init(w, .{ .use_color = false }, "x");
            try fp.printMatch(.{
                .before = &.{.{ .line_no = 1, .text = "ctx" }},
                .line = .{ .line_no = 2, .text = "match" },
                .cols = &[_]u32{1},
                .after = &.{},
            });
        }
    }.r);
    defer a.free(out);
    try std.testing.expectEqualStrings("x-1-ctx\nx:2:1: match\n", out);
}
