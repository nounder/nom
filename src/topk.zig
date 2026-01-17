const std = @import("std");

/// Min-heap that keeps only the top K items by `score` field.
pub fn TopKHeap(comptime T: type, comptime K: usize) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .items = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        /// Push an item. Returns the evicted item if the heap was full and the new
        /// entry replaced the minimum.
        pub fn push(self: *Self, item: T) !?T {
            if (self.items.items.len < K) {
                try self.items.append(self.allocator, item);
                self.siftUp(self.items.items.len - 1);
                return null;
            }

            if (self.items.items.len == 0) return null;

            if (item.score > self.items.items[0].score) {
                const replaced = self.items.items[0];
                self.items.items[0] = item;
                self.siftDown(0);
                return replaced;
            }
            return null;
        }

        pub fn pop(self: *Self) ?T {
            if (self.items.items.len == 0) return null;

            const result = self.items.items[0];
            const last = self.items.pop().?;
            if (self.items.items.len > 0) {
                self.items.items[0] = last;
                self.siftDown(0);
            }
            return result;
        }

        fn siftUp(self: *Self, idx: usize) void {
            var i = idx;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (self.items.items[i].score >= self.items.items[parent].score) break;
                std.mem.swap(T, &self.items.items[i], &self.items.items[parent]);
                i = parent;
            }
        }

        fn siftDown(self: *Self, idx: usize) void {
            var i = idx;
            const heap_len = self.items.items.len;
            while (true) {
                var smallest = i;
                const left = 2 * i + 1;
                const right = 2 * i + 2;

                if (left < heap_len and self.items.items[left].score < self.items.items[smallest].score) {
                    smallest = left;
                }
                if (right < heap_len and self.items.items[right].score < self.items.items[smallest].score) {
                    smallest = right;
                }

                if (smallest == i) break;
                std.mem.swap(T, &self.items.items[i], &self.items.items[smallest]);
                i = smallest;
            }
        }
    };
}
