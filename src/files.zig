//! File system utilities for nom.

const std = @import("std");
const chunk = @import("chunklist.zig");
const fd = @import("fd/fd.zig");
const parallel_walker = @import("fd/parallel_walker.zig");

/// Default walker options for fzf-mode traversal (mirrors `nom fd` defaults).
fn defaultWalkOptions() fd.WalkOptions {
    return .{
        .ignore_hidden = true,
        .read_gitignore = true,
        .require_git = true,
        .read_ignore = true,
        .read_fdignore = true,
    };
}

/// Walk a directory and collect all file paths into a newline-separated buffer.
/// Behaves like fd: skips hidden files and respects .gitignore / .ignore / .fdignore.
pub fn walk(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]const u8 {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        mu: std.Io.Mutex = .init,
        buf: std.ArrayListUnmanaged(u8) = .empty,

        fn emit(ctx_opaque: *anyopaque, cb_io: std.Io, entry: parallel_walker.Entry) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx_opaque));
            c.mu.lockUncancelable(cb_io);
            defer c.mu.unlock(cb_io);
            try c.buf.appendSlice(c.allocator, entry.path);
            if (entry.kind == .directory) try c.buf.append(c.allocator, '/');
            try c.buf.append(c.allocator, '\n');
        }
    };

    var ctx: Ctx = .{ .allocator = allocator };
    errdefer ctx.buf.deinit(allocator);

    const pw = try parallel_walker.ParallelWalker.init(
        allocator,
        io,
        defaultWalkOptions(),
        .{ .emitFn = Ctx.emit, .ctx = &ctx },
        parallel_walker.defaultWorkerCount(),
    );
    defer pw.deinit();

    try pw.run(dir);

    return try ctx.buf.toOwnedSlice(allocator);
}

test "walk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const result = try walk(allocator, io, std.Io.Dir.cwd());
    defer allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "StreamingWalker end-to-end" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    var sw = StreamingWalker.init(allocator, io, dir);
    defer sw.deinit();

    try sw.start();

    // Busy-wait for done. 5s cap.
    var spins: usize = 0;
    while (!sw.isDone() and spins < 500) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try sw.checkError();
    try std.testing.expect(sw.isDone());

    var total: usize = 0;
    while (sw.pollChunk()) |c| {
        total += c.items.len;
        c.arena.deinit();
        allocator.free(c.items);
    }
    try std.testing.expect(total > 0);
}

/// Background walker that streams file paths into chunks.
/// Compatible with the StreamingReader interface used by the TUI.
/// Behaves like fd: skips hidden files and respects .gitignore / .ignore / .fdignore.
///
/// Implementation: drives a `ParallelWalker` on its own thread. The walker's
/// Sink appends into a per-chunk arena guarded by a mutex; once a chunk hits
/// CHUNK_SIZE, it's handed off to the output queue.
pub const StreamingWalker = struct {
    const CHUNK_SIZE: usize = 100;

    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: std.ArrayListUnmanaged(chunk.Chunk),
    head: usize = 0,
    done: bool = false,
    error_state: ?anyerror = null,
    next_id: usize = 0,

    // Chunk-building state, guarded by `mutex`.
    pending: std.ArrayListUnmanaged([]const u8) = .empty,
    pending_arena: std.heap.ArenaAllocator,

    // Parallel walker owns its own cancelation; we call it on deinit.
    pw: ?*parallel_walker.ParallelWalker = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) StreamingWalker {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .queue = .empty,
            .pending_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *StreamingWalker) void {
        if (self.thread) |t| {
            // Signal stop; both our local flag and the parallel walker.
            self.mutex.lockUncancelable(self.io);
            self.done = true;
            self.condition.signal(self.io);
            self.mutex.unlock(self.io);
            if (self.pw) |pw| pw.cancel();
            t.join();
        }

        if (self.pw) |pw| pw.deinit();

        while (self.head < self.queue.items.len) : (self.head += 1) {
            const c = self.queue.items[self.head];
            c.arena.deinit();
            self.allocator.free(c.items);
            if (c.data.len > 0) {
                self.allocator.free(c.data);
            }
        }
        self.queue.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_arena.deinit();
    }

    pub fn start(self: *StreamingWalker) !void {
        self.thread = try std.Thread.spawn(.{}, walkerThread, .{self});
    }

    pub fn isDone(self: *StreamingWalker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.done;
    }

    pub fn checkError(self: *StreamingWalker) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.error_state) |err| return err;
    }

    pub fn pollChunk(self: *StreamingWalker) ?chunk.Chunk {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.head >= self.queue.items.len) return null;

        const c = self.queue.items[self.head];
        self.head += 1;

        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head > 64 and self.head * 2 > self.queue.items.len) {
            const remaining = self.queue.items.len - self.head;
            std.mem.copyForwards(chunk.Chunk, self.queue.items[0..remaining], self.queue.items[self.head..self.queue.items.len]);
            self.queue.items.len = remaining;
            self.head = 0;
        }

        return c;
    }

    fn walkerThread(self: *StreamingWalker) void {
        self.walkLoop() catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.error_state = err;
            self.done = true;
            self.condition.signal(self.io);
            self.mutex.unlock(self.io);
        };
    }

    fn emitSink(ctx_opaque: *anyopaque, io: std.Io, entry: parallel_walker.Entry) anyerror!void {
        const self: *StreamingWalker = @ptrCast(@alignCast(ctx_opaque));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.done) return; // consumer told us to stop

        const a = self.pending_arena.allocator();
        const path_copy = if (entry.kind == .directory)
            try std.fmt.allocPrint(a, "{s}/", .{entry.path})
        else
            try a.dupe(u8, entry.path);
        try self.pending.append(self.allocator, path_copy);

        if (self.pending.items.len >= CHUNK_SIZE) {
            try self.flushLocked();
        }
    }

    fn walkLoop(self: *StreamingWalker) !void {
        const sink: parallel_walker.Sink = .{ .emitFn = emitSink, .ctx = self };
        const pw = try parallel_walker.ParallelWalker.init(
            self.allocator,
            self.io,
            defaultWalkOptions(),
            sink,
            parallel_walker.defaultWorkerCount(),
        );
        self.pw = pw;

        pw.run(self.dir) catch |err| switch (err) {
            error.Canceled => {},
            else => return err,
        };

        // Final flush of any buffered entries.
        self.mutex.lockUncancelable(self.io);
        if (self.pending.items.len > 0) {
            try self.flushLocked();
        }
        self.done = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }

    /// Must be called with `self.mutex` held. Hands the current pending buffer
    /// + arena off to the output queue as a Chunk, then resets them.
    fn flushLocked(self: *StreamingWalker) !void {
        const items = try self.allocator.alloc(chunk.ChunkItem, self.pending.items.len);
        for (self.pending.items, 0..) |path, i| {
            items[i] = .{
                .id = self.next_id,
                .display = path,
                .match_text = path,
                .original = path,
            };
            self.next_id += 1;
        }

        try self.queue.append(self.allocator, .{
            .items = items,
            .data = &.{},
            .arena = self.pending_arena,
        });

        self.pending.clearRetainingCapacity();
        self.pending_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.condition.signal(self.io);
    }
};
