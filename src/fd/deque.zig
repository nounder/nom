//! Mutex-guarded work-stealing deque.
//!
//! Each worker owns one `Deque(T)`. Its owner pushes and pops from the "top"
//! (LIFO — keeps the worker depth-first, which bounds the number of
//! simultaneously-open gitignore stacks). Other workers steal from the
//! "bottom" (FIFO relative to the stealer). `readdir` dominates the cost of
//! each work item, so mutex contention is not a concern in practice; a
//! Chase-Lev deque is an optimization for later if profiling demands it.

const std = @import("std");

pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: std.Io.Mutex = .init,
        items: std.ArrayListUnmanaged(T) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Push an item onto the top of the deque (owner side).
        pub fn pushLocal(self: *Self, io: std.Io, item: T) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            try self.items.append(self.allocator, item);
        }

        /// Pop an item from the top of the deque (owner side, LIFO).
        /// Returns `null` if the deque is empty.
        pub fn popLocal(self: *Self, io: std.Io) !?T {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            return self.items.pop();
        }

        /// Steal an item from the bottom of the deque (other workers).
        /// Returns `null` if the deque is empty.
        pub fn steal(self: *Self, io: std.Io) !?T {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        /// Return the current length under the deque mutex.
        pub fn len(self: *Self, io: std.Io) usize {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            return self.items.items.len;
        }
    };
}

test "Deque basic LIFO owner" {
    const io = std.testing.io;
    var d = Deque(u32).init(std.testing.allocator);
    defer d.deinit();

    try d.pushLocal(io, 1);
    try d.pushLocal(io, 2);
    try d.pushLocal(io, 3);

    try std.testing.expectEqual(@as(?u32, 3), try d.popLocal(io));
    try std.testing.expectEqual(@as(?u32, 2), try d.popLocal(io));
    try std.testing.expectEqual(@as(?u32, 1), try d.popLocal(io));
    try std.testing.expectEqual(@as(?u32, null), try d.popLocal(io));
}

test "Deque steal is FIFO" {
    const io = std.testing.io;
    var d = Deque(u32).init(std.testing.allocator);
    defer d.deinit();

    try d.pushLocal(io, 1);
    try d.pushLocal(io, 2);
    try d.pushLocal(io, 3);

    try std.testing.expectEqual(@as(?u32, 1), try d.steal(io));
    try std.testing.expectEqual(@as(?u32, 2), try d.steal(io));
    // Owner pops the remaining top.
    try std.testing.expectEqual(@as(?u32, 3), try d.popLocal(io));
    try std.testing.expectEqual(@as(?u32, null), try d.steal(io));
}

test "Deque interleaved push/pop/steal" {
    const io = std.testing.io;
    var d = Deque(u32).init(std.testing.allocator);
    defer d.deinit();

    try d.pushLocal(io, 10);
    try d.pushLocal(io, 20);
    try std.testing.expectEqual(@as(?u32, 10), try d.steal(io)); // FIFO bottom
    try d.pushLocal(io, 30);
    try std.testing.expectEqual(@as(?u32, 30), try d.popLocal(io)); // LIFO top
    try std.testing.expectEqual(@as(?u32, 20), try d.popLocal(io));
    try std.testing.expectEqual(@as(?u32, null), try d.popLocal(io));
}
