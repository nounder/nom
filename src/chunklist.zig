const std = @import("std");

/// A single item read from the input stream.
pub const ChunkItem = struct {
    /// Stable, monotonically increasing id assigned as lines are read.
    id: usize,
    /// Text shown in the list (after with-nth transform).
    display: []const u8,
    /// Text used for matching (after nth transform).
    match_text: []const u8,
    /// The original line that should be printed on accept.
    original: []const u8,
};

/// A chunk owns a slab of memory and the parsed items that live on it.
pub const Chunk = struct {
    items: []ChunkItem,
    data: []u8,
    arena: std.heap.ArenaAllocator,
};

/// Stores chunks of items and tracks total count.
pub const ChunkList = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(Chunk),
    total_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ChunkList {
        return .{
            .allocator = allocator,
            .chunks = .{},
        };
    }

    pub fn deinit(self: *ChunkList) void {
        for (self.chunks.items) |chunk| {
            chunk.arena.deinit();
            self.allocator.free(chunk.items);
            if (chunk.data.len > 0) {
                self.allocator.free(chunk.data);
            }
        }
        self.chunks.deinit(self.allocator);
    }

    /// Append a fully built chunk and update total count.
    pub fn appendChunk(self: *ChunkList, chunk: Chunk) !void {
        self.total_count += chunk.items.len;
        try self.chunks.append(self.allocator, chunk);
    }

    /// Snapshot current chunks (read-only).
    pub fn snapshot(self: *ChunkList) struct { chunks: []Chunk, count: usize } {
        return .{ .chunks = self.chunks.items, .count = self.total_count };
    }
};
