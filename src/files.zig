//! File system utilities for nom.

const std = @import("std");
const chunk = @import("chunklist.zig");

/// Walk the current directory and collect all file paths into a newline-separated buffer.
/// Skips .git and node_modules directories.
pub fn walk(allocator: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch |err| switch (err) {
            // Skip inaccessible/problematic directories
            error.AccessDenied, error.PermissionDenied, error.NotDir, error.FileNotFound => continue,
            else => return err,
        } orelse break; // null means done

        // Skip ignored directories
        if (shouldSkipPath(entry.path)) continue;

        if (entry.kind == .file or entry.kind == .sym_link) {
            try result.appendSlice(allocator, entry.path);
            try result.append(allocator, '\n');
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn shouldSkipPath(path: []const u8) bool {
    return shouldSkipDir(path, ".git") or shouldSkipDir(path, "node_modules");
}

fn shouldSkipDir(path: []const u8, comptime dir: []const u8) bool {
    // Exact match at start: ".git" or ".git/..."
    if (std.mem.startsWith(u8, path, dir)) {
        if (path.len == dir.len or path[dir.len] == '/') {
            return true;
        }
    }
    // Match anywhere: ".../.git/..." or ".../.git"
    if (std.mem.indexOf(u8, path, "/" ++ dir ++ "/") != null) {
        return true;
    }
    if (std.mem.endsWith(u8, path, "/" ++ dir)) {
        return true;
    }
    return false;
}

test "walk" {
    const allocator = std.testing.allocator;
    const result = try walk(allocator);
    defer allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "shouldSkipPath" {
    try std.testing.expect(shouldSkipPath(".git"));
    try std.testing.expect(shouldSkipPath(".git/config"));
    try std.testing.expect(shouldSkipPath("foo/.git/config"));
    try std.testing.expect(shouldSkipPath("foo/.git"));
    try std.testing.expect(shouldSkipPath("node_modules"));
    try std.testing.expect(shouldSkipPath("node_modules/foo"));
    try std.testing.expect(!shouldSkipPath("src/main.zig"));
    try std.testing.expect(!shouldSkipPath(".gitignore"));
    try std.testing.expect(!shouldSkipPath("foo/.gitignore"));
}

/// Background walker that streams file paths into chunks.
/// Compatible with the StreamingReader interface used by the TUI.
pub const StreamingWalker = struct {
    const CHUNK_SIZE: usize = 100; // Flush every 100 items for responsiveness

    allocator: std.mem.Allocator,

    // Thread + coordination
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayList(chunk.Chunk),
    head: usize = 0,
    done: bool = false,
    error_state: ?anyerror = null,
    next_id: usize = 0,

    pub fn init(allocator: std.mem.Allocator) StreamingWalker {
        return .{
            .allocator = allocator,
            .queue = .{},
        };
    }

    pub fn deinit(self: *StreamingWalker) void {
        if (self.thread) |t| {
            self.mutex.lock();
            self.done = true;
            self.condition.signal();
            self.mutex.unlock();
            t.join();
        }

        // Free any pending chunks that were not consumed
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

    /// Start walking in a background thread.
    pub fn start(self: *StreamingWalker) !void {
        self.thread = try std.Thread.spawn(.{}, walkerThread, .{self});
    }

    /// Returns true when the walker finished (successfully or with error).
    pub fn isDone(self: *StreamingWalker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }

    pub fn checkError(self: *StreamingWalker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_state) |err| return err;
    }

    /// Non-blocking: pop the next available chunk if any.
    pub fn pollChunk(self: *StreamingWalker) ?chunk.Chunk {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head >= self.queue.items.len) return null;

        const c = self.queue.items[self.head];
        self.head += 1;

        // Compact the queue when head grows
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
            self.mutex.lock();
            self.error_state = err;
            self.done = true;
            self.condition.signal();
            self.mutex.unlock();
        };
    }

    fn walkLoop(self: *StreamingWalker) !void {
        var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        var paths = std.ArrayList([]const u8){};
        defer paths.deinit(self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        while (true) {
            // Check if we should stop
            self.mutex.lock();
            const should_stop = self.done;
            self.mutex.unlock();
            if (should_stop) break;

            const entry = walker.next() catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied, error.NotDir, error.FileNotFound => continue,
                else => return err,
            } orelse break;

            // Skip ignored directories
            if (shouldSkipPath(entry.path)) continue;

            if (entry.kind == .file or entry.kind == .sym_link) {
                // Copy the path since walker memory is reused
                const path_copy = try arena.allocator().dupe(u8, entry.path);
                try paths.append(self.allocator, path_copy);

                // Flush periodically for responsiveness
                if (paths.items.len >= CHUNK_SIZE) {
                    try self.flushChunk(&paths, &arena);
                    arena = std.heap.ArenaAllocator.init(self.allocator);
                }
            }
        }

        // Flush remaining items
        if (paths.items.len > 0) {
            try self.flushChunk(&paths, &arena);
        } else {
            arena.deinit();
        }

        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn flushChunk(
        self: *StreamingWalker,
        paths: *std.ArrayList([]const u8),
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

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.allocator, .{
            .items = items,
            .data = &.{}, // No separate data slab needed
            .arena = arena.*,
        });
        self.condition.signal();

        paths.clearRetainingCapacity();
    }
};
