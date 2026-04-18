//! Parallel directory walker.
//!
//! Modeled on ripgrep's `ignore::WalkParallel`. N symmetric workers; each owns
//! a LIFO deque of `Work` items. Workers steal from peers when their own deque
//! is empty. Termination is driven by an atomic `active_workers` counter: a
//! worker going idle decrements; when the count hits zero, the last worker
//! broadcasts quit.
//!
//! Per-directory walk state lives in an immutable linked `DirNode` tree.
//! Every node is allocated from a shared arena and lives until the walk ends;
//! workers hold `*const DirNode` pointers and never mutate them. Each node
//! carries any ignore files loaded at that directory (as `ignore.IgnoreFile`).
//!
//! Output goes through a `Sink` callback. Entries passed to the sink borrow
//! their `path` slice from the walker's arena — valid for the duration of the
//! walk, so sinks need not copy unless they outlive `run()`.

const std = @import("std");
const deque_mod = @import("deque.zig");
const ignore = @import("ignore.zig");

pub const WalkOptions = struct {
    ignore_hidden: bool = true,
    read_gitignore: bool = true,
    require_git: bool = true,
    read_ignore: bool = true,
    read_fdignore: bool = true,
    follow_symlinks: bool = false,
    max_depth: ?usize = null,
    min_depth: ?usize = null,
    exclude_patterns: []const []const u8 = &.{},
};

/// A node in the walk tree: one per directory visited. Immutable after
/// construction. Workers chase the `parent` chain to evaluate gitignore
/// patterns from root down to the current directory.
///
/// Nodes are arena-allocated by the walker and live until the walk ends —
/// no refcounting. Many workers may hold `*const DirNode` pointers into the
/// same tree simultaneously without synchronization.
pub const DirNode = struct {
    parent: ?*const DirNode,
    /// Merged ignore patterns loaded at this directory, or `null` if it had
    /// no ignore files. Owned by the same arena as the node.
    ignore: ?ignore.IgnoreFile,
    /// Byte length of the root-relative path prefix represented by this
    /// node. Used to compute per-level-relative paths without allocating.
    path_len: usize,
    flags: std.EnumSet(Flag),

    pub const Flag = enum { git };

    /// True if this node or any ancestor is a git repository root.
    pub fn inGitRepo(self: *const DirNode) bool {
        var cur: ?*const DirNode = self;
        while (cur) |n| : (cur = n.parent) {
            if (n.flags.contains(.git)) return true;
        }
        return false;
    }
};

/// Walk `node` and its ancestors to decide whether `rel_path` is ignored.
/// Applies last-match-wins across the chain (root first), then lets the
/// global `~/.fdignore` (if any) take final priority.
pub fn isIgnored(
    node: *const DirNode,
    global_fdignore: ?ignore.IgnoreFile,
    name: []const u8,
    rel_path: []const u8,
    is_dir: bool,
) bool {
    var result: ?bool = null;
    applyIgnoreChain(node, name, rel_path, is_dir, &result);

    if (global_fdignore) |gf| {
        if (gf.check(name, rel_path, is_dir)) |r| result = r;
    }

    return result orelse false;
}

fn applyIgnoreChain(
    node: ?*const DirNode,
    name: []const u8,
    rel_path: []const u8,
    is_dir: bool,
    result: *?bool,
) void {
    const current = node orelse return;
    applyIgnoreChain(current.parent, name, rel_path, is_dir, result);

    const level_rel = levelRelative(current.path_len, name, rel_path);
    if (current.ignore) |ig| {
        if (ig.check(name, level_rel, is_dir)) |r| {
            result.* = r;
        }
    }
}

/// True if a hidden entry is explicitly un-ignored by a negation pattern
/// anywhere in the ancestor chain.
pub fn isExplicitlyIncluded(
    node: *const DirNode,
    name: []const u8,
    rel_path: []const u8,
    is_dir: bool,
) bool {
    var cur: ?*const DirNode = node;
    while (cur) |n| : (cur = n.parent) {
        if (n.ignore) |ig| {
            const level_rel = levelRelative(n.path_len, name, rel_path);
            for (ig.patterns) |p| {
                if (p.is_negation and p.matches(name, level_rel, is_dir)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn levelRelative(path_len: usize, name: []const u8, rel_path: []const u8) []const u8 {
    if (path_len == 0) return rel_path;
    if (path_len < rel_path.len) return rel_path[path_len + 1 ..];
    return name;
}

/// An entry emitted by the parallel walker.
///
/// Lifetime rules:
/// - `path` and `name` live in the walker's arena (valid until
///   `ParallelWalker.deinit`). Sinks that outlive the walker must copy.
/// - `parent_dir` is the worker's currently-open handle for this entry's
///   containing directory. It is **only valid during the sink callback**;
///   the worker closes it as soon as `emit` returns. Sinks that buffer
///   entries for later consumption must not retain `parent_dir`.
///
/// The `parent_dir` handle lets callback-side code (e.g. a filter) call
/// `statFile` / `openDir` against the entry's basename without re-walking
/// from the root.
pub const Entry = struct {
    path: []const u8,
    name: []const u8,
    depth: usize,
    kind: std.Io.File.Kind,
    parent_dir: std.Io.Dir,
};

/// Callback interface for receiving entries.
pub const Sink = struct {
    emitFn: *const fn (ctx: *anyopaque, io: std.Io, entry: Entry) anyerror!void,
    ctx: *anyopaque,

    pub fn emit(self: Sink, io: std.Io, entry: Entry) !void {
        return self.emitFn(self.ctx, io, entry);
    }
};

const MAX_IGNORE_SIZE = 1024 * 1024;

const Work = struct {
    /// Root-relative path to the directory this work item represents.
    /// Empty string means the root itself. The directory is opened fresh
    /// in `processDir` to keep the in-flight fd count bounded by the worker
    /// count rather than the queue depth.
    path: []const u8, // arena-owned
    depth: usize,
    /// Parent directory's ignore node. The node for *this* directory is
    /// built in `processDir` once the dir is open and its ignore files can
    /// be read. `null` means this is the walk root (no parent).
    parent_node: ?*const DirNode,
};

const Deque = deque_mod.Deque(Work);

pub const ParallelWalker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: WalkOptions,
    sink: Sink,

    /// Per-walk arena: IgnoreNode, IgnoreFile contents, Work.path.
    /// Must be thread-safe when accessed from workers — we front it with a mutex.
    arena: std.heap.ArenaAllocator,
    arena_mu: std.Io.Mutex = .init,

    /// Global ~/.fdignore, loaded once and shared (read-only).
    global_fdignore: ?ignore.IgnoreFile,

    /// Iterable handle for the walk root. Subdirectory work items are opened
    /// relative to this handle on demand, so at any moment we hold one fd per
    /// *active* worker rather than one per queued directory.
    root_dir: ?std.Io.Dir = null,

    deques: []Deque,

    active_workers: std.atomic.Value(usize),
    quit_now: std.atomic.Value(bool),

    /// First error encountered by any worker. We only preserve one.
    err_mu: std.Io.Mutex = .init,
    first_err: ?anyerror = null,

    /// Idle-wait coordination.
    wait_mu: std.Io.Mutex = .init,
    wait_cond: std.Io.Condition = .init,
    /// Incremented whenever a worker pushes new work, to wake stealers.
    /// Also incremented by the final-worker broadcast at termination.
    wait_epoch: std.atomic.Value(u32),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: WalkOptions,
        sink: Sink,
        num_workers: usize,
    ) !*ParallelWalker {
        std.debug.assert(num_workers >= 1);

        const self = try allocator.create(ParallelWalker);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .sink = sink,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .global_fdignore = null,
            .deques = &.{},
            .active_workers = .init(num_workers),
            .quit_now = .init(false),
            .wait_epoch = .init(0),
        };
        errdefer self.arena.deinit();

        // Load global ~/.fdignore once into the shared arena.
        if (options.read_fdignore) {
            if (homeDir()) |home| {
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrint(&path_buf, "{s}/.fdignore", .{home})) |p| {
                    self.global_fdignore = ignore.IgnoreFile.loadAbsolute(
                        self.arena.allocator(),
                        io,
                        p,
                    ) catch null;
                } else |_| {}
            }
        }

        self.deques = try allocator.alloc(Deque, num_workers);
        errdefer allocator.free(self.deques);
        for (self.deques) |*d| d.* = Deque.init(allocator);

        return self;
    }

    pub fn deinit(self: *ParallelWalker) void {
        if (self.root_dir) |*rd| rd.close(self.io);
        for (self.deques) |*d| d.deinit();
        self.allocator.free(self.deques);
        // arena frees global_fdignore + all IgnoreNodes + all Work.paths.
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn arenaAlloc(self: *ParallelWalker, comptime T: type) !*T {
        self.arena_mu.lockUncancelable(self.io);
        defer self.arena_mu.unlock(self.io);
        return self.arena.allocator().create(T);
    }

    fn arenaDupe(self: *ParallelWalker, bytes: []const u8) ![]u8 {
        self.arena_mu.lockUncancelable(self.io);
        defer self.arena_mu.unlock(self.io);
        return self.arena.allocator().dupe(u8, bytes);
    }

    fn arenaAllocSlice(self: *ParallelWalker, comptime T: type, n: usize) ![]T {
        self.arena_mu.lockUncancelable(self.io);
        defer self.arena_mu.unlock(self.io);
        return self.arena.allocator().alloc(T, n);
    }

    fn recordError(self: *ParallelWalker, err: anyerror) void {
        self.err_mu.lockUncancelable(self.io);
        defer self.err_mu.unlock(self.io);
        if (self.first_err == null) self.first_err = err;
        self.quit_now.store(true, .release);
        // Wake any parked workers so they can observe quit.
        _ = self.wait_epoch.fetchAdd(1, .release);
        self.wait_cond.broadcast(self.io);
    }

    fn notifyNewWork(self: *ParallelWalker) void {
        _ = self.wait_epoch.fetchAdd(1, .release);
        self.wait_cond.signal(self.io);
    }

    fn notifyAllDone(self: *ParallelWalker) void {
        _ = self.wait_epoch.fetchAdd(1, .release);
        self.wait_cond.broadcast(self.io);
    }

    /// Run the walk to completion. Spawns workers, seeds the root onto
    /// worker 0's deque, awaits all workers, then surfaces the first error
    /// (if any).
    ///
    /// `root` may be any directory handle (e.g. `std.Io.Dir.cwd()`); we
    /// re-open it with `.iterate = true` internally, since the caller's
    /// handle may not have been opened iterable.
    pub fn run(self: *ParallelWalker, root: std.Io.Dir) !void {
        // Open an iterable handle for the root and keep it open for the
        // duration of the walk. All subdirectory opens happen relative to
        // this handle, which lets us close per-directory fds as soon as we
        // finish enumerating them.
        self.root_dir = try root.openDir(self.io, ".", .{ .iterate = true });
        errdefer {
            var r = self.root_dir.?;
            r.close(self.io);
            self.root_dir = null;
        }

        const root_path = try self.arenaDupe("");

        // Seed worker 0 with the root. Its IgnoreNode is built inside
        // processDir like every other directory.
        try self.deques[0].pushLocal(self.io, .{
            .path = root_path,
            .depth = 0,
            .parent_node = null,
        });

        var group: std.Io.Group = .init;
        errdefer group.cancel(self.io);

        for (0..self.deques.len) |i| {
            group.async(self.io, workerMain, .{ self, i });
        }

        try group.await(self.io);

        if (self.root_dir) |*rd| {
            rd.close(self.io);
            self.root_dir = null;
        }

        if (self.first_err) |e| return e;
    }

    /// Stop the walk as soon as possible. Safe to call from any thread.
    pub fn cancel(self: *ParallelWalker) void {
        self.quit_now.store(true, .release);
        _ = self.wait_epoch.fetchAdd(1, .release);
        self.wait_cond.broadcast(self.io);
    }

    fn buildRootNode(self: *ParallelWalker, root: std.Io.Dir) !*const DirNode {
        const node = try self.arenaAlloc(DirNode);
        const git_here = detectGitFlag(self.io, root);
        const in_git = git_here.contains(.git);
        node.* = .{
            .parent = null,
            .ignore = try self.loadIgnoreAt(root, in_git),
            .path_len = 0,
            .flags = git_here,
        };
        return node;
    }

    fn buildChildNode(
        self: *ParallelWalker,
        parent: *const DirNode,
        child_dir: std.Io.Dir,
        path_len: usize,
    ) !*const DirNode {
        const node = try self.arenaAlloc(DirNode);
        const git_here = detectGitFlag(self.io, child_dir);
        const in_git = git_here.contains(.git) or parent.inGitRepo();
        node.* = .{
            .parent = parent,
            .ignore = try self.loadIgnoreAt(child_dir, in_git),
            .path_len = path_len,
            .flags = git_here,
        };
        return node;
    }

    fn loadIgnoreAt(self: *ParallelWalker, dir: std.Io.Dir, in_git: bool) !?ignore.IgnoreFile {
        self.arena_mu.lockUncancelable(self.io);
        defer self.arena_mu.unlock(self.io);
        const a = self.arena.allocator();

        var contents: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer contents.deinit(a);

        const read_gitignore = self.options.read_gitignore and
            (!self.options.require_git or in_git);

        if (read_gitignore) {
            if (ignore.readFileAlloc(a, self.io, dir, ".gitignore", MAX_IGNORE_SIZE)) |c| {
                try contents.append(a, c);
            } else |_| {}
        }
        if (self.options.read_ignore) {
            if (ignore.readFileAlloc(a, self.io, dir, ".ignore", MAX_IGNORE_SIZE)) |c| {
                try contents.append(a, c);
            } else |_| {}
        }
        if (self.options.read_fdignore) {
            if (ignore.readFileAlloc(a, self.io, dir, ".fdignore", MAX_IGNORE_SIZE)) |c| {
                try contents.append(a, c);
            } else |_| {}
        }

        if (contents.items.len == 0) {
            contents.deinit(a);
            return null;
        }

        return try ignore.IgnoreFile.fromContents(a, try contents.toOwnedSlice(a));
    }

    /// Try to pop from our own deque, then steal from any peer.
    fn tryGetWork(self: *ParallelWalker, worker_id: usize) !?Work {
        if (try self.deques[worker_id].popLocal(self.io)) |w| return w;
        // Steal scan, starting from the neighbor.
        const n = self.deques.len;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const peer = (worker_id + i) % n;
            if (try self.deques[peer].steal(self.io)) |w| return w;
        }
        return null;
    }

    fn park(self: *ParallelWalker) void {
        self.wait_mu.lockUncancelable(self.io);
        defer self.wait_mu.unlock(self.io);
        // Wait for an epoch change or quit.
        const before = self.wait_epoch.load(.acquire);
        if (self.quit_now.load(.acquire)) return;
        // Re-check work availability before parking — tryGetWork caller already
        // looked, but between then and here a peer may have pushed. We pay an
        // extra O(N) scan to avoid sleeping on ready work.
        for (self.deques) |*d| if (d.len(self.io) > 0) return;
        // Spurious wakeups are fine; the outer worker loop will re-check.
        while (self.wait_epoch.load(.acquire) == before and
            !self.quit_now.load(.acquire))
        {
            self.wait_cond.waitUncancelable(self.io, &self.wait_mu);
        }
    }

    fn workerMain(self: *ParallelWalker, worker_id: usize) std.Io.Cancelable!void {
        self.workerLoop(worker_id) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => self.recordError(err),
        };
    }

    fn workerLoop(self: *ParallelWalker, worker_id: usize) !void {
        // `active_workers` starts at N; decrement when we have no work, re-increment
        // when we find some.
        var active = true;

        while (true) {
            if (self.quit_now.load(.acquire)) return;

            const work_opt = try self.tryGetWork(worker_id);
            const work = work_opt orelse {
                if (active) {
                    active = false;
                    const prev = self.active_workers.fetchSub(1, .acq_rel);
                    if (prev == 1) {
                        // Last worker — everyone is idle and all deques empty.
                        // Set quit_now so any parked workers observe completion
                        // on wake and return rather than underflowing the counter.
                        self.quit_now.store(true, .release);
                        self.notifyAllDone();
                        return;
                    }
                }
                self.park();
                if (self.quit_now.load(.acquire)) return;
                // Re-check before becoming active again.
                if (self.anyWorkAvailable()) {
                    active = true;
                    _ = self.active_workers.fetchAdd(1, .acq_rel);
                }
                continue;
            };

            if (!active) {
                active = true;
                _ = self.active_workers.fetchAdd(1, .acq_rel);
            }

            try self.processDir(worker_id, work);
        }
    }

    fn processDir(self: *ParallelWalker, worker_id: usize, work: Work) !void {
        // Open the directory fresh for each work item. The root (empty path) is
        // handed to us already open; everything else opens via `root_dir.openDir`
        // and is closed here. This caps in-flight fds at roughly N (the worker
        // count) instead of the queue depth.
        const root = self.root_dir.?;
        const opened_here = work.path.len > 0;
        var dir = if (opened_here)
            root.openDir(self.io, work.path, .{ .iterate = true }) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied, error.FileNotFound => return,
                else => return err,
            }
        else
            root;
        defer if (opened_here) dir.close(self.io);

        // Build this directory's ignore node now that it's open. For the root,
        // its own .git flag determines `in_git`; otherwise, inherit from parent.
        const node = if (work.parent_node) |parent|
            try self.buildChildNode(parent, dir, work.path.len)
        else
            try self.buildRootNode(dir);

        var iter = dir.iterate();

        // Build a path buffer we reuse within this directory.
        var path_scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer path_scratch.deinit(self.allocator);

        while (true) {
            if (self.quit_now.load(.acquire)) return;

            const de_opt = iter.next(self.io) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => break,
                error.Canceled => return err,
                else => return err,
            };
            const de = de_opt orelse break;

            // Build rel_path = work.path + "/" + de.name.
            path_scratch.clearRetainingCapacity();
            try path_scratch.appendSlice(self.allocator, work.path);
            if (work.path.len > 0) try path_scratch.append(self.allocator, '/');
            const name_start = path_scratch.items.len;
            try path_scratch.appendSlice(self.allocator, de.name);
            const rel_path = path_scratch.items;
            const name = rel_path[name_start..];

            const is_dir = de.kind == .directory;

            if (self.options.ignore_hidden and de.name.len > 0 and de.name[0] == '.') {
                if (!isExplicitlyIncluded(node, name, rel_path, is_dir)) {
                    continue;
                }
            }

            if (self.isExcluded(name, rel_path)) continue;

            if (isIgnored(node, self.global_fdignore, name, rel_path, is_dir)) {
                continue;
            }

            // Copy path into arena for emission + any queued work.
            const owned_path = try self.arenaDupe(rel_path);
            const owned_name = owned_path[name_start..];

            // Depth check for emission.
            const emit_depth = work.depth;
            const pass_min = if (self.options.min_depth) |min| emit_depth >= min else true;

            if (is_dir) {
                // Queue the subdir for a worker to pick up. No fd is held for
                // queued work — the processor opens the dir on demand.
                const can_descend = if (self.options.max_depth) |max| emit_depth < max else true;
                if (can_descend) {
                    try self.deques[worker_id].pushLocal(self.io, .{
                        .path = owned_path,
                        .depth = emit_depth + 1,
                        .parent_node = node,
                    });
                    self.notifyNewWork();
                }

                if (pass_min) {
                    try self.sink.emit(self.io, .{
                        .path = owned_path,
                        .name = owned_name,
                        .depth = emit_depth,
                        .kind = de.kind,
                        .parent_dir = dir,
                    });
                }
            } else {
                if (pass_min) {
                    try self.sink.emit(self.io, .{
                        .path = owned_path,
                        .name = owned_name,
                        .depth = emit_depth,
                        .kind = de.kind,
                        .parent_dir = dir,
                    });
                }
            }
        }
    }

    fn anyWorkAvailable(self: *ParallelWalker) bool {
        for (self.deques) |*d| {
            if (d.len(self.io) > 0) return true;
        }
        return false;
    }

    fn isExcluded(self: *ParallelWalker, name: []const u8, rel_path: []const u8) bool {
        for (self.options.exclude_patterns) |pattern| {
            if (ignore.globMatch(pattern, name) or ignore.globMatch(pattern, rel_path)) {
                return true;
            }
        }
        return false;
    }
};

fn detectGitFlag(io: std.Io, dir: std.Io.Dir) std.EnumSet(DirNode.Flag) {
    var flags: std.EnumSet(DirNode.Flag) = .{};
    if (dir.access(io, ".git", .{})) |_| {
        flags.insert(.git);
    } else |_| {}
    return flags;
}

fn homeDir() ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    if (!builtin.link_libc) {
        for (std.os.environ) |entry| {
            const e = std.mem.span(entry);
            if (std.mem.startsWith(u8, e, "HOME=")) return e[5..];
        }
        return null;
    }
    const c_home = std.c.getenv("HOME") orelse return null;
    return std.mem.span(c_home);
}

/// Default worker count — cap at 12 like ripgrep to avoid thrashing on
/// many-core machines where directory enumeration isn't the bottleneck.
pub fn defaultWorkerCount() usize {
    const cpu = std.Thread.getCpuCount() catch 4;
    return @min(cpu, 12);
}

// Tests

test "DirNode last-match-wins across chain" {
    const gpa = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Root: ignore *.log
    const root_contents = try a.alloc([]const u8, 1);
    root_contents[0] = try a.dupe(u8, "*.log\n");
    const root_ig = (try ignore.IgnoreFile.fromContents(a, root_contents)).?;

    // Child (src/): un-ignore debug.log
    const child_contents = try a.alloc([]const u8, 1);
    child_contents[0] = try a.dupe(u8, "!debug.log\n");
    const child_ig = (try ignore.IgnoreFile.fromContents(a, child_contents)).?;

    const root_node = try a.create(DirNode);
    root_node.* = .{ .parent = null, .ignore = root_ig, .path_len = 0, .flags = .{} };

    const child_node = try a.create(DirNode);
    child_node.* = .{ .parent = root_node, .ignore = child_ig, .path_len = "src".len, .flags = .{} };

    try std.testing.expect(isIgnored(root_node, null, "other.log", "other.log", false));
    try std.testing.expect(!isIgnored(child_node, null, "debug.log", "src/debug.log", false));
    try std.testing.expect(isIgnored(child_node, null, "other.log", "src/other.log", false));
}

test "DirNode ignore inheritance survives deep trees" {
    const gpa = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root_contents = try a.alloc([]const u8, 1);
    root_contents[0] = try a.dupe(u8, "secret.txt\n");
    const root_ig = (try ignore.IgnoreFile.fromContents(a, root_contents)).?;

    const root_node = try a.create(DirNode);
    root_node.* = .{ .parent = null, .ignore = root_ig, .path_len = 0, .flags = .{} };

    var leaf: *const DirNode = root_node;
    for (0..70) |_| {
        const child = try a.create(DirNode);
        child.* = .{ .parent = leaf, .ignore = null, .path_len = 0, .flags = .{} };
        leaf = child;
    }

    try std.testing.expect(isIgnored(leaf, null, "secret.txt", "d0/d1/d2/secret.txt", false));
}

const CollectorCtx = struct {
    allocator: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn emit(ctx_opaque: *anyopaque, io: std.Io, entry: Entry) anyerror!void {
        const ctx: *CollectorCtx = @ptrCast(@alignCast(ctx_opaque));
        ctx.mu.lockUncancelable(io);
        defer ctx.mu.unlock(io);
        const copy = try ctx.allocator.dupe(u8, entry.path);
        errdefer ctx.allocator.free(copy);
        try ctx.paths.append(ctx.allocator, copy);
    }

    fn sink(self: *CollectorCtx) Sink {
        return .{ .emitFn = emit, .ctx = self };
    }

    fn deinit(self: *CollectorCtx) void {
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.deinit(self.allocator);
    }
};

test "ParallelWalker basic cwd walk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ctx: CollectorCtx = .{ .allocator = allocator };
    defer ctx.deinit();

    const root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer {
        var r = root;
        r.close(io);
    }

    const pw = try ParallelWalker.init(allocator, io, .{}, ctx.sink(), 2);
    defer pw.deinit();

    try pw.run(root);

    // The walker should have emitted at least one entry (this file's dir has many).
    try std.testing.expect(ctx.paths.items.len > 0);
}

test "ParallelWalker is deterministic across worker counts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const runWith = struct {
        fn run(a: std.mem.Allocator, i: std.Io, workers: usize) ![][]const u8 {
            var c: CollectorCtx = .{ .allocator = a };
            errdefer c.deinit();
            const root = try std.Io.Dir.cwd().openDir(i, ".", .{ .iterate = true });
            defer {
                var r = root;
                r.close(i);
            }
            const pw = try ParallelWalker.init(a, i, .{}, c.sink(), workers);
            defer pw.deinit();
            try pw.run(root);
            return try c.paths.toOwnedSlice(a);
        }
    }.run;

    const one = try runWith(allocator, io, 1);
    defer {
        for (one) |p| allocator.free(p);
        allocator.free(one);
    }
    const many = try runWith(allocator, io, 4);
    defer {
        for (many) |p| allocator.free(p);
        allocator.free(many);
    }

    const lt = struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp;
    std.mem.sort([]const u8, one, {}, lt);
    std.mem.sort([]const u8, many, {}, lt);

    try std.testing.expectEqual(one.len, many.len);
    for (one, many) |a, b| try std.testing.expectEqualStrings(a, b);
}
