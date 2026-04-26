//! grep-zig: parallel literal grep on top of the fd parallel walker.
//!
//! For each file the walker emits we open it, mmap it, and run the searcher.
//! Matches are buffered per file (so we can group output by filename) and
//! flushed under a shared writer mutex, so concurrent workers don't
//! interleave each other's blocks. Within a file matches are emitted in
//! source order; across files, the order is whatever the walker delivers.

const std = @import("std");
const parallel_walker = @import("../fd/parallel_walker.zig");
const searcher = @import("searcher.zig");
const printer = @import("printer.zig");

pub const Options = struct {
    needle: []const u8,
    case_insensitive: bool = false,
    /// Lowercase, dot-stripped extensions to include (e.g. "zig", "rs").
    /// Empty means "all files".
    extensions: []const []const u8 = &.{},
    before_context: usize = 0,
    after_context: usize = 0,

    // Walker knobs (mirror fd's defaults so users get the same behavior).
    ignore_hidden: bool = true,
    read_gitignore: bool = true,
    require_git: bool = true,
    follow_symlinks: bool = false,
    max_depth: ?usize = null,
    threads: ?usize = null,
    home_dir: ?[]const u8 = null,
    exclude_patterns: []const []const u8 = &.{},

    // Output.
    use_color: bool = false,
};

/// Search a single regular file at `path` (relative to `dir`). No walker,
/// no extension filter. Returns the number of matches printed.
pub fn runSingleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    display_path: []const u8,
    options: Options,
    writer: *std.Io.Writer,
) !usize {
    var file = dir.openFile(io, path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("error: cannot open '{s}': {}\n", .{ path, err });
        return 0;
    };
    defer file.close(io);

    const length = file.length(io) catch return 0;
    if (length == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var collected: std.ArrayListUnmanaged(searcher.Match) = .empty;

    const FileSink = struct {
        arena: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(searcher.Match),

        fn push(opaque_fs: *anyopaque, m: searcher.Match) anyerror!bool {
            const fs: *@This() = @ptrCast(@alignCast(opaque_fs));
            const before = try fs.arena.alloc(searcher.LineSlice, m.before.len);
            for (m.before, 0..) |b, i| {
                before[i] = .{ .line_no = b.line_no, .text = try fs.arena.dupe(u8, b.text) };
            }
            const after = try fs.arena.alloc(searcher.LineSlice, m.after.len);
            for (m.after, 0..) |b, i| {
                after[i] = .{ .line_no = b.line_no, .text = try fs.arena.dupe(u8, b.text) };
            }
            const line: searcher.LineSlice = .{
                .line_no = m.line.line_no,
                .text = try fs.arena.dupe(u8, m.line.text),
            };
            const cols = try fs.arena.dupe(u32, m.cols);
            try fs.list.append(fs.arena, .{
                .before = before,
                .line = line,
                .cols = cols,
                .after = after,
            });
            return true;
        }
    };

    var fs: FileSink = .{ .arena = a, .list = &collected };

    _ = try searcher.searchFile(allocator, io, file, length, .{
        .needle = options.needle,
        .case_insensitive = options.case_insensitive,
        .before_context = options.before_context,
        .after_context = options.after_context,
    }, .{ .ctx = &fs, .onMatchFn = FileSink.push });

    if (collected.items.len == 0) return 0;

    var fp = printer.FilePrinter.init(writer, .{
        .use_color = options.use_color,
        .needle_len = options.needle.len,
    }, display_path);
    for (collected.items) |m| try fp.printMatch(m);
    return collected.items.len;
}

/// Run grep over `dir` and write matches to `writer`. The walker may run on
/// many threads; output is serialized through `writer_mu`. If `display_root`
/// is non-empty (e.g. "src/"), it's prepended to each match's path so output
/// is meaningful when searching a directory other than cwd.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    display_root: []const u8,
    options: Options,
    writer: *std.Io.Writer,
) !usize {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        opts: *const Options,
        writer: *std.Io.Writer,
        display_root: []const u8,
        writer_mu: std.Io.Mutex = .init,
        match_total: std.atomic.Value(usize) = .init(0),

        fn emit(opaque_self: *anyopaque, cb_io: std.Io, entry: parallel_walker.Entry) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(opaque_self));
            if (entry.kind != .file) return;
            if (!extensionAllowed(entry.name, self.opts.extensions)) return;

            // Open + stat + mmap + search. All scratch is local; matches
            // are buffered into a per-file arena that we drain under the
            // writer mutex.
            var per_file_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer per_file_arena.deinit();
            const a = per_file_arena.allocator();

            var file = entry.parent_dir.openFile(cb_io, entry.name, .{ .mode = .read_only }) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied, error.FileNotFound => return,
                else => return,
            };
            defer file.close(cb_io);

            const length = file.length(cb_io) catch return;
            if (length == 0) return;

            // Buffer matches with arena-owned copies of every borrowed
            // string, so we can release the mmap before holding the writer
            // lock.
            var collected: std.ArrayListUnmanaged(searcher.Match) = .empty;

            const FileSink = struct {
                arena: std.mem.Allocator,
                list: *std.ArrayListUnmanaged(searcher.Match),

                fn push(opaque_fs: *anyopaque, m: searcher.Match) anyerror!bool {
                    const fs: *@This() = @ptrCast(@alignCast(opaque_fs));
                    const before = try fs.arena.alloc(searcher.LineSlice, m.before.len);
                    for (m.before, 0..) |b, i| {
                        before[i] = .{ .line_no = b.line_no, .text = try fs.arena.dupe(u8, b.text) };
                    }
                    const after = try fs.arena.alloc(searcher.LineSlice, m.after.len);
                    for (m.after, 0..) |b, i| {
                        after[i] = .{ .line_no = b.line_no, .text = try fs.arena.dupe(u8, b.text) };
                    }
                    const line: searcher.LineSlice = .{
                        .line_no = m.line.line_no,
                        .text = try fs.arena.dupe(u8, m.line.text),
                    };
                    const cols = try fs.arena.dupe(u32, m.cols);
                    try fs.list.append(fs.arena, .{
                        .before = before,
                        .line = line,
                        .cols = cols,
                        .after = after,
                    });
                    return true;
                }
            };

            var fs: FileSink = .{ .arena = a, .list = &collected };

            _ = searcher.searchFile(self.allocator, cb_io, file, length, .{
                .needle = self.opts.needle,
                .case_insensitive = self.opts.case_insensitive,
                .before_context = self.opts.before_context,
                .after_context = self.opts.after_context,
            }, .{ .ctx = &fs, .onMatchFn = FileSink.push }) catch return;

            if (collected.items.len == 0) return;

            // Drain to writer under the lock. The path slice is borrowed
            // from the walker's arena and lives for the whole walk, so we
            // don't need to copy it.
            // Build display path under the same arena. If display_root is
            // empty or ".", the walker's relative path is fine as-is.
            const display_path = if (self.display_root.len == 0 or std.mem.eql(u8, self.display_root, "."))
                entry.path
            else blk: {
                const buf = try a.alloc(u8, self.display_root.len + 1 + entry.path.len);
                @memcpy(buf[0..self.display_root.len], self.display_root);
                buf[self.display_root.len] = '/';
                @memcpy(buf[self.display_root.len + 1 ..], entry.path);
                break :blk buf;
            };

            self.writer_mu.lockUncancelable(cb_io);
            defer self.writer_mu.unlock(cb_io);

            var fp = printer.FilePrinter.init(self.writer, .{
                .use_color = self.opts.use_color,
                .needle_len = self.opts.needle.len,
            }, display_path);
            for (collected.items) |m| {
                fp.printMatch(m) catch return;
            }
            _ = self.match_total.fetchAdd(collected.items.len, .monotonic);
        }
    };

    var ctx: Ctx = .{
        .allocator = allocator,
        .opts = &options,
        .writer = writer,
        .display_root = display_root,
    };

    const walk_opts: parallel_walker.WalkOptions = .{
        .ignore_hidden = options.ignore_hidden,
        .read_gitignore = options.read_gitignore,
        .require_git = options.require_git,
        .follow_symlinks = options.follow_symlinks,
        .max_depth = options.max_depth,
        .exclude_patterns = options.exclude_patterns,
        .home_dir = options.home_dir,
    };

    const workers = options.threads orelse parallel_walker.defaultWorkerCount();
    const pw = try parallel_walker.ParallelWalker.init(
        allocator,
        io,
        walk_opts,
        .{ .emitFn = Ctx.emit, .ctx = &ctx },
        workers,
    );
    defer pw.deinit();

    try pw.run(dir);

    return ctx.match_total.load(.monotonic);
}

/// Return true if `name`'s extension is one of `allowed` (or `allowed` is
/// empty). Comparison is ASCII case-insensitive; leading dots in `allowed`
/// entries are stripped (so users can pass either "zig" or ".zig").
fn extensionAllowed(name: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0 or dot + 1 >= name.len) return false;
    const ext = name[dot + 1 ..];
    for (allowed) |a| {
        const want = if (a.len > 0 and a[0] == '.') a[1..] else a;
        if (std.ascii.eqlIgnoreCase(ext, want)) return true;
    }
    return false;
}

// ---------- tests ----------

test "extensionAllowed basic" {
    try std.testing.expect(extensionAllowed("foo.zig", &.{"zig"}));
    try std.testing.expect(extensionAllowed("foo.ZIG", &.{"zig"}));
    try std.testing.expect(extensionAllowed("foo.zig", &.{".zig"}));
    try std.testing.expect(!extensionAllowed("foo.rs", &.{"zig"}));
    try std.testing.expect(!extensionAllowed("noext", &.{"zig"}));
    try std.testing.expect(!extensionAllowed(".hidden", &.{"zig"}));
    try std.testing.expect(extensionAllowed("anything", &.{}));
}

test "run finds matches in temp dir" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "foo bar\nbaz needle here\nqux\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "no hit\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "needle\n" });

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    const total = try run(a, io, tmp.dir, ".", .{
        .needle = "needle",
        .require_git = false, // tmpdir isn't a git repo
    }, &aw.writer);

    try std.testing.expectEqual(@as(usize, 2), total);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "needle") != null);
}

test "run filters by extension" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "needle\n" });

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    const total = try run(a, io, tmp.dir, ".", .{
        .needle = "needle",
        .extensions = &.{"zig"},
        .require_git = false,
    }, &aw.writer);

    try std.testing.expectEqual(@as(usize, 1), total);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "b.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "a.txt") == null);
}
