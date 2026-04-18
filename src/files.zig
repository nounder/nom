//! File system utilities for nom.

const std = @import("std");
const chunk = @import("chunklist.zig");
const fd = @import("fd/fd.zig");

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
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var walker = fd.Walker.init(allocator, io, ".", defaultWalkOptions());
    defer walker.deinit();
    try walker.start(dir);

    while (try walker.next()) |entry| {
        try result.appendSlice(allocator, entry.path);
        if (entry.kind == .directory) try result.append(allocator, '/');
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

test "walk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const result = try walk(allocator, io, std.Io.Dir.cwd());
    defer allocator.free(result);
    try std.testing.expect(result.len > 0);
}

/// Background walker that streams file paths into chunks.
/// Compatible with the StreamingReader interface used by the TUI.
/// Behaves like fd: skips hidden files and respects .gitignore / .ignore / .fdignore.
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) StreamingWalker {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .queue = .empty,
        };
    }

    pub fn deinit(self: *StreamingWalker) void {
        if (self.thread) |t| {
            self.mutex.lockUncancelable(self.io);
            self.done = true;
            self.condition.signal(self.io);
            self.mutex.unlock(self.io);
            t.join();
        }

        while (self.head < self.queue.items.len) : (self.head += 1) {
            const c = self.queue.items[self.head];
            c.arena.deinit();
            self.allocator.free(c.items);
            if (c.data.len > 0) {
                self.allocator.free(c.data);
            }
        }
        self.queue.deinit(self.allocator);
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

    fn walkLoop(self: *StreamingWalker) !void {
        var walker = fd.Walker.init(self.allocator, self.io, ".", defaultWalkOptions());
        defer walker.deinit();
        try walker.start(self.dir);

        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        while (true) {
            self.mutex.lockUncancelable(self.io);
            const should_stop = self.done;
            self.mutex.unlock(self.io);
            if (should_stop) break;

            const entry = try walker.next() orelse break;

            const path_copy = if (entry.kind == .directory)
                try std.fmt.allocPrint(arena.allocator(), "{s}/", .{entry.path})
            else
                try arena.allocator().dupe(u8, entry.path);
            try paths.append(self.allocator, path_copy);

            if (paths.items.len >= CHUNK_SIZE) {
                try self.flushChunk(&paths, &arena);
                arena = std.heap.ArenaAllocator.init(self.allocator);
            }
        }

        if (paths.items.len > 0) {
            try self.flushChunk(&paths, &arena);
        } else {
            arena.deinit();
        }

        self.mutex.lockUncancelable(self.io);
        self.done = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn flushChunk(
        self: *StreamingWalker,
        paths: *std.ArrayListUnmanaged([]const u8),
        arena: *std.heap.ArenaAllocator,
    ) !void {
        const items = try self.allocator.alloc(chunk.ChunkItem, paths.items.len);

        for (paths.items, 0..) |path, i| {
            items[i] = .{
                .id = self.next_id,
                .display = path,
                .match_text = path,
                .original = path,
            };
            self.next_id += 1;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.queue.append(self.allocator, .{
            .items = items,
            .data = &.{},
            .arena = arena.*,
        });
        self.condition.signal(self.io);

        paths.clearRetainingCapacity();
    }
};
