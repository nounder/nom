//! fd-zig: A fast file finder library inspired by fd.
//!
//! Layered on top of `parallel_walker` (shared N-worker walker). Filters and
//! pattern matching run *inside* the walker's sink callback, where the
//! parent directory handle is still open — so `stat()` / `isEmpty()` checks
//! work without reopening anything.
//!
//! ## Example
//!
//! ```zig
//! try fd.find(gpa, io, dir, .{
//!     .search_pattern = "*.zig",
//!     .pattern_kind = .glob,
//! }, {}, struct {
//!     fn emit(_: void, entry: fd.Entry) !void {
//!         std.debug.print("{s}\n", .{entry.path});
//!     }
//! }.emit);
//! ```

const std = @import("std");
pub const pattern = @import("pattern.zig");
pub const filter = @import("filter.zig");
pub const parallel_walker = @import("parallel_walker.zig");
pub const ignore = @import("ignore.zig");
pub const output = @import("output.zig");

// Re-exports for convenience
pub const Pattern = pattern.Pattern;
pub const PatternKind = pattern.PatternKind;
pub const PatternOptions = pattern.PatternOptions;
pub const Filter = filter.Filter;
pub const FileType = filter.FileType;
pub const SizeFilter = filter.SizeFilter;
pub const TimeFilter = filter.TimeFilter;
pub const WalkOptions = parallel_walker.WalkOptions;
pub const Entry = parallel_walker.Entry;
pub const OutputFormat = output.OutputFormat;
pub const ColorMode = output.ColorMode;
pub const FormatTemplate = output.FormatTemplate;

/// Configuration for the Finder.
pub const FinderOptions = struct {
    // Pattern matching
    search_pattern: ?[]const u8 = null,
    pattern_kind: PatternKind = .glob,
    case_sensitive: ?bool = null, // null = smart case (sensitive if has uppercase)
    full_path: bool = false,

    // File filtering
    file_types: ?FileType = null,
    extensions: []const []const u8 = &.{},
    size_filters: []const SizeFilter = &.{},
    time_filters: []const TimeFilter = &.{},
    min_depth: ?usize = null,
    max_depth: ?usize = null,

    // Directory walking
    ignore_hidden: bool = true,
    read_gitignore: bool = true,
    require_git: bool = true,
    follow_symlinks: bool = false,
    exclude_patterns: []const []const u8 = &.{},

    // Parallelism
    threads: ?usize = null,

    // Result limiting
    max_results: ?usize = null,
};

/// Entry adapter used *during* sink callbacks. Wraps a `parallel_walker.Entry`
/// and provides `stat()` / `isEmpty()` for the filter. The `parent_dir`
/// handle is only valid for the duration of the callback.
const FilterEntry = struct {
    path: []const u8,
    name: []const u8,
    depth: usize,
    kind: std.Io.File.Kind,
    dir: std.Io.Dir,
    io: std.Io,
    cached_stat: ?std.Io.File.Stat = null,

    pub fn stat(self: *FilterEntry) !std.Io.File.Stat {
        if (self.cached_stat) |s| return s;
        const s = try self.dir.statFile(self.io, self.name, .{});
        self.cached_stat = s;
        return s;
    }

    pub fn isEmpty(self: *FilterEntry) !bool {
        if (self.kind != .directory) return false;
        var subdir = try self.dir.openDir(self.io, self.name, .{ .iterate = true });
        defer subdir.close(self.io);
        var it = subdir.iterate();
        return (try it.next(self.io)) == null;
    }
};

/// Run a search: walk `dir` in parallel, apply pattern + filters, invoke
/// `callback` for each matching entry. The callback runs on worker threads;
/// the entry's `path`, `name`, and `parent_dir` are live only during the call
/// and may be reused or closed afterwards, so any retention or `stat`-like
/// work must happen synchronously or via copies made by the callback.
///
/// Stops (cleanly) when `callback` returns `false` or when `max_results` is
/// reached.
/// Callback: `(ctx, entry) -> keep_going`. Return `false` to stop the walk.
pub const FindCallback = *const fn (ctx: *anyopaque, entry: Entry) anyerror!bool;

pub fn find(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    options: FinderOptions,
    ctx: *anyopaque,
    callback: FindCallback,
) !usize {
    // Compile pattern (once, outside the walker).
    var compiled: ?Pattern = null;
    if (options.search_pattern) |pat| {
        const case_sensitive = options.case_sensitive orelse !hasUppercase(pat);
        compiled = try Pattern.init(allocator, pat, options.pattern_kind, .{
            .case_sensitive = case_sensitive,
            .full_path = options.full_path,
        });
    }
    defer if (compiled) |*p| p.deinit(allocator);

    const file_filter: Filter = .{
        .file_types = options.file_types,
        .extensions = options.extensions,
        .size_filters = options.size_filters,
        .time_filters = options.time_filters,
        .min_depth = options.min_depth,
        .max_depth = options.max_depth,
    };

    const walk_opts: WalkOptions = .{
        .ignore_hidden = options.ignore_hidden,
        .read_gitignore = options.read_gitignore,
        .require_git = options.require_git,
        .follow_symlinks = options.follow_symlinks,
        .max_depth = options.max_depth,
        .min_depth = options.min_depth,
        .exclude_patterns = options.exclude_patterns,
    };

    const Ctx = struct {
        // Passed from outer scope via pointer.
        pattern: ?*const Pattern,
        filter: Filter,
        options: *const FinderOptions,
        user_ctx: *anyopaque,
        user_cb: FindCallback,
        walker: ?*parallel_walker.ParallelWalker = null,

        // Mutable — guarded by mu.
        mu: std.Io.Mutex = .init,
        count: usize = 0,
        /// Set by the sink to tell the walker "stop". The walker has a
        /// `cancel()` method but we don't have access to `*ParallelWalker`
        /// from inside the sink, so we check a flag and drop subsequent
        /// emits on the floor. (Workers will still enumerate a bit more
        /// before noticing, but it's bounded.)
        stop: bool = false,

        fn emit(opaque_self: *anyopaque, cb_io: std.Io, entry: Entry) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(opaque_self));

            // Fast path: short-circuit on stop.
            {
                self.mu.lockUncancelable(cb_io);
                const stopped = self.stop;
                self.mu.unlock(cb_io);
                if (stopped) return;
            }

            // Pattern match.
            if (self.pattern) |p| {
                const match_text = if (self.options.full_path) entry.path else entry.name;
                if (!p.matches(match_text)) return;
            }

            // Filter — construct an adapter with access to parent_dir.
            var fe: FilterEntry = .{
                .path = entry.path,
                .name = entry.name,
                .depth = entry.depth,
                .kind = entry.kind,
                .dir = entry.parent_dir,
                .io = cb_io,
            };
            if (!try self.filter.matches(&fe)) return;

            // Past the gauntlet: count + user callback + max_results check.
            var reached_limit = false;
            self.mu.lockUncancelable(cb_io);
            if (self.stop) {
                self.mu.unlock(cb_io);
                return;
            }
            if (self.options.max_results) |max| {
                if (self.count >= max) {
                    self.stop = true;
                    if (self.walker) |walker| walker.cancel();
                    self.mu.unlock(cb_io);
                    return;
                }
            }
            self.count += 1;
            if (self.options.max_results) |max| {
                reached_limit = self.count >= max;
            }
            self.mu.unlock(cb_io);

            const keep_going = try self.user_cb(self.user_ctx, entry);
            if (!keep_going or reached_limit) {
                self.mu.lockUncancelable(cb_io);
                self.stop = true;
                if (self.walker) |walker| walker.cancel();
                self.mu.unlock(cb_io);
            }
        }
    };

    var c: Ctx = .{
        .pattern = if (compiled) |*p| p else null,
        .filter = file_filter,
        .options = &options,
        .user_ctx = ctx,
        .user_cb = callback,
    };

    const workers = options.threads orelse parallel_walker.defaultWorkerCount();
    const pw = try parallel_walker.ParallelWalker.init(
        allocator,
        io,
        walk_opts,
        .{ .emitFn = Ctx.emit, .ctx = &c },
        workers,
    );
    defer pw.deinit();
    c.walker = pw;

    try pw.run(dir);

    return c.count;
}

/// Check if a string contains uppercase ASCII characters.
/// Used for smart case detection.
pub fn hasUppercase(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

// Tests

test "hasUppercase" {
    try std.testing.expect(!hasUppercase("foo"));
    try std.testing.expect(!hasUppercase("foo123"));
    try std.testing.expect(!hasUppercase("foo_bar"));
    try std.testing.expect(hasUppercase("Foo"));
    try std.testing.expect(hasUppercase("FOO"));
    try std.testing.expect(hasUppercase("fooBar"));
    try std.testing.expect(hasUppercase("foo.Zig"));
}

test "find basic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var counter: usize = 0;
    const total = try find(allocator, io, std.Io.Dir.cwd(), .{
        .search_pattern = "*.zig",
        .pattern_kind = .glob,
    }, &counter, struct {
        fn emit(ctx: *anyopaque, _: Entry) anyerror!bool {
            const c: *usize = @ptrCast(@alignCast(ctx));
            _ = @atomicRmw(usize, c, .Add, 1, .monotonic);
            return true;
        }
    }.emit);

    try std.testing.expect(total > 0);
    try std.testing.expectEqual(total, counter);
}

test "find max_results cancels traversal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var first = try tmp.dir.createDirPathOpen(io, "first", .{ .open_options = .{ .iterate = true } });
    first.close(io);

    const oversized = try allocator.alloc(u8, 1024 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, '#');
    try tmp.dir.writeFile(io, .{
        .sub_path = "first/.gitignore",
        .data = oversized,
    });

    var counter: usize = 0;
    const total = try find(allocator, io, tmp.dir, .{
        .max_results = 1,
        .threads = 1,
    }, &counter, struct {
        fn emit(ctx: *anyopaque, _: Entry) anyerror!bool {
            const c: *usize = @ptrCast(@alignCast(ctx));
            c.* += 1;
            return true;
        }
    }.emit);

    try std.testing.expectEqual(@as(usize, 1), total);
    try std.testing.expectEqual(@as(usize, 1), counter);
}
