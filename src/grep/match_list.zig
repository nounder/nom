//! Thread-safe append-only list of grep matches feeding the interactive TUI.
//!
//! The walker pushes records from many worker threads; the TUI polls
//! `snapshotLen()` once per frame and reads `items[0..len]` without locking
//! (the slice elements are immutable once appended). New appends grow the
//! backing array under a mutex but never touch existing elements, so the
//! TUI's read snapshot is always consistent.

const std = @import("std");

/// One match. `path` and `line_text` are owned by `arena` (passed at init).
/// `cols` are 1-based byte offsets into `line_text` for every needle hit.
pub const Item = struct {
    path: []const u8,
    line_no: u32,
    cols: []const u32,
    line_text: []const u8,
    /// Pre-built searchable string (`path + " " + line_text`) for the
    /// fuzzy matcher. Allocated on first push.
    match_text: []const u8,
};

pub const MatchList = struct {
    allocator: std.mem.Allocator,
    /// All `Item` data — paths, line text, cols arrays, match_text — is
    /// allocated from this arena. Frees in one shot at deinit.
    arena: std.heap.ArenaAllocator,
    /// Mutex guards `items` (the slice header) and `arena_mu` writes.
    /// Reads of `items[0..len]` for `len <= snapshot_len` are lock-free.
    mu: std.Io.Mutex = .init,
    items: std.ArrayListUnmanaged(Item) = .empty,
    /// Atomic snapshot length: the number of items definitely visible to
    /// readers. Incremented after the slice has been fully populated.
    snapshot_len: std.atomic.Value(usize) = .init(0),
    /// Set when the producer (walker) has finished; the TUI uses this to
    /// distinguish "no results yet" from "no results, ever."
    done: std.atomic.Value(bool) = .init(false),
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MatchList {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *MatchList) void {
        self.items.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Append a match, copying `path`, `line_text`, and `cols` into the
    /// arena. Caller may reuse the input buffers immediately on return.
    pub fn push(
        self: *MatchList,
        path: []const u8,
        line_no: u32,
        cols: []const u32,
        line_text: []const u8,
    ) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const a = self.arena.allocator();
        const path_copy = try a.dupe(u8, path);
        const line_copy = try a.dupe(u8, line_text);
        const cols_copy = try a.dupe(u32, cols);

        // Pre-build "path line_text" — one buffer that the matcher scores
        // against, so we don't reformat per keystroke.
        const match_text = try a.alloc(u8, path_copy.len + 1 + line_copy.len);
        @memcpy(match_text[0..path_copy.len], path_copy);
        match_text[path_copy.len] = ' ';
        @memcpy(match_text[path_copy.len + 1 ..], line_copy);

        try self.items.append(self.allocator, .{
            .path = path_copy,
            .line_no = line_no,
            .cols = cols_copy,
            .line_text = line_copy,
            .match_text = match_text,
        });
        // Publish only after the slot is fully populated.
        self.snapshot_len.store(self.items.items.len, .release);
    }

    /// Number of items currently visible to readers. Lock-free.
    pub fn snapshotLen(self: *const MatchList) usize {
        return self.snapshot_len.load(.acquire);
    }

    /// Borrowed slice of the first `len` items. Stable until `deinit`.
    /// Caller must use a `len` returned by `snapshotLen`.
    pub fn snapshotItems(self: *const MatchList, len: usize) []const Item {
        return self.items.items[0..len];
    }

    pub fn markDone(self: *MatchList) void {
        self.done.store(true, .release);
    }

    pub fn isDone(self: *const MatchList) bool {
        return self.done.load(.acquire);
    }
};

// ---------- tests ----------

test "MatchList push/snapshot" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var list = MatchList.init(a, io);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 0), list.snapshotLen());
    try list.push("foo.zig", 42, &[_]u32{ 5, 17 }, "var x = needle; needle();");
    try list.push("bar.zig", 7, &[_]u32{1}, "needle()");

    const len = list.snapshotLen();
    try std.testing.expectEqual(@as(usize, 2), len);
    const items = list.snapshotItems(len);
    try std.testing.expectEqualStrings("foo.zig", items[0].path);
    try std.testing.expectEqual(@as(u32, 42), items[0].line_no);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 5, 17 }, items[0].cols);
    try std.testing.expectEqualStrings("foo.zig var x = needle; needle();", items[0].match_text);
}
