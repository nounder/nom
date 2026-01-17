const std = @import("std");
const chunk = @import("chunklist.zig");

/// Background reader that streams lines from a file into owned chunks.
pub const StreamingReader = struct {
    const BUFFER_SIZE: usize = 64 * 1024; // 64KB
    const SLAB_SIZE: usize = 128 * 1024; // 128KB

    allocator: std.mem.Allocator,
    delimiter: u8,
    header_lines: usize,
    nth: ?[]const u8,
    with_nth: ?[]const u8,

    // Thread + coordination
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayList(chunk.Chunk),
    head: usize = 0,
    done: bool = false,
    error_state: ?anyerror = null,
    next_id: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        delimiter: u8,
        header_lines: usize,
        nth: ?[]const u8,
        with_nth: ?[]const u8,
    ) StreamingReader {
        return .{
            .allocator = allocator,
            .delimiter = delimiter,
            .header_lines = header_lines,
            .nth = nth,
            .with_nth = with_nth,
            .queue = .{},
        };
    }

    pub fn deinit(self: *StreamingReader) void {
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
            self.allocator.free(c.data);
        }
        self.queue.deinit(self.allocator);
    }

    /// Start reading from the given file handle in a background thread.
    pub fn start(self: *StreamingReader, file: std.fs.File) !void {
        self.thread = try std.Thread.spawn(.{}, readerThread, .{ self, file });
    }

    /// Returns true when the reader finished (successfully or with error).
    pub fn isDone(self: *StreamingReader) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }

    pub fn checkError(self: *StreamingReader) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_state) |err| return err;
    }

    /// Non-blocking: pop the next available chunk if any.
    pub fn pollChunk(self: *StreamingReader) ?chunk.Chunk {
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

    fn readerThread(self: *StreamingReader, file: std.fs.File) void {
        self.readLoop(file) catch |err| {
            self.mutex.lock();
            self.error_state = err;
            self.done = true;
            self.condition.signal();
            self.mutex.unlock();
        };
    }

    fn readLoop(self: *StreamingReader, file: std.fs.File) !void {
        var slab = try self.allocator.alloc(u8, SLAB_SIZE);
        var lines_buf = std.ArrayList([]const u8){};
        defer lines_buf.deinit(self.allocator);

        var leftover: []u8 = &.{};

        // Pre-parse nth/with-nth ranges so we don't reparse per line
        var nth_ranges = try ParsedNth.init(self.allocator, self.nth);
        defer nth_ranges.deinit();
        var with_nth_ranges = try ParsedNth.init(self.allocator, self.with_nth);
        defer with_nth_ranges.deinit();

        while (true) {
            // Stop early if signaled
            self.mutex.lock();
            const should_stop = self.done;
            self.mutex.unlock();
            if (should_stop) break;

            // Ensure we have space to read more into slab
            const available = @min(BUFFER_SIZE, SLAB_SIZE - leftover.len);
            if (available == 0) {
                // Two cases: slab fully packed with completed lines (flush) or slab only
                // holds an unfinished line (grow slab so the tail can complete).
                if (lines_buf.items.len > 0) {
                    try self.flushChunk(&lines_buf, slab, nth_ranges, with_nth_ranges);
                    slab = try self.allocator.alloc(u8, SLAB_SIZE);
                    if (leftover.len > 0) {
                        std.mem.copyForwards(u8, slab[0..leftover.len], leftover);
                        leftover = slab[0..leftover.len];
                    } else {
                        leftover = &.{};
                    }
                } else if (leftover.len > 0) {
                    const new_size = slab.len + SLAB_SIZE;
                    var new_slab = try self.allocator.alloc(u8, new_size);
                    std.mem.copyForwards(u8, new_slab[0..leftover.len], leftover);
                    self.allocator.free(slab);
                    slab = new_slab;
                    leftover = slab[0..leftover.len];
                }
                continue;
            }

            // Copy leftover to front of slab
            if (leftover.len > 0 and leftover.ptr != slab.ptr) {
                std.mem.copyForwards(u8, slab[0..leftover.len], leftover);
            }

            const n = file.read(slab[leftover.len .. leftover.len + available]) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            if (n == 0) break;

            const data = slab[0 .. leftover.len + n];

            // Split into lines on delimiter
            var line_start: usize = 0;
            for (data, 0..) |b, i| {
                if (b == self.delimiter) {
                    const len = i - line_start;
                    if (len > 0) {
                        try lines_buf.append(self.allocator, data[line_start..i]);
                    }
                    line_start = i + 1;
                }
            }

            leftover = data[line_start..];

            // Flush periodically to avoid huge buffers
            if (lines_buf.items.len >= 1000) {
                try self.flushChunk(&lines_buf, slab, nth_ranges, with_nth_ranges);
                slab = try self.allocator.alloc(u8, SLAB_SIZE);
                leftover = &.{};
            }
        }

        if (leftover.len > 0) {
            try lines_buf.append(self.allocator, leftover);
            leftover = &.{};
        }

        if (lines_buf.items.len > 0) {
            try self.flushChunk(&lines_buf, slab, nth_ranges, with_nth_ranges);
        } else {
            self.allocator.free(slab);
        }

        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn flushChunk(
        self: *StreamingReader,
        lines_buf: *std.ArrayList([]const u8),
        slab: []u8,
        nth_ranges: ParsedNth,
        with_nth_ranges: ParsedNth,
    ) !void {
        const originals = try lines_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(originals);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        var items = try self.allocator.alloc(chunk.ChunkItem, originals.len);

        for (originals, 0..) |line, i| {
            const match_text = try nth_ranges.apply(arena.allocator(), line);
            const display_text = try with_nth_ranges.apply(arena.allocator(), line);

            items[i] = .{
                .id = self.next_id,
                .display = display_text,
                .match_text = match_text,
                .original = line,
            };
            self.next_id += 1;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.allocator, .{
            .items = items,
            .data = slab,
            .arena = arena,
        });
        self.condition.signal();
    }
};

/// Pre-parsed nth/with-nth specification.
pub const ParsedNth = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(FieldRange),

    pub fn init(allocator: std.mem.Allocator, spec: ?[]const u8) !ParsedNth {
        var self = ParsedNth{
            .allocator = allocator,
            .ranges = .{},
        };

        if (spec) |s| {
            var it = std.mem.splitScalar(u8, s, ',');
            while (it.next()) |range_str| {
                if (FieldRange.parse(range_str)) |range| {
                    try self.ranges.append(allocator, range);
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *ParsedNth) void {
        self.ranges.deinit(self.allocator);
    }

    pub fn apply(self: ParsedNth, allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
        if (self.ranges.items.len == 0) {
            return line;
        }

        var fields = std.ArrayList([]const u8){};
        defer fields.deinit(self.allocator);

        // Split by spaces/tabs to mirror existing extractNthFields
        var start: usize = 0;
        var in_field = false;
        for (line, 0..) |c, i| {
            const is_delim = (c == ' ' or c == '\t');
            if (!in_field and !is_delim) {
                start = i;
                in_field = true;
            } else if (in_field and is_delim) {
                try fields.append(self.allocator, line[start..i]);
                in_field = false;
            }
        }
        if (in_field) {
            try fields.append(self.allocator, line[start..]);
        }

        if (fields.items.len == 0) {
            return line;
        }

        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        var first = true;
        for (fields.items, 0..) |field, idx| {
            var matches_any = false;
            for (self.ranges.items) |range| {
                if (range.matches(idx, fields.items.len)) {
                    matches_any = true;
                    break;
                }
            }
            if (!matches_any) continue;

            if (!first) {
                try result.append(allocator, ' ');
            }
            try result.appendSlice(allocator, field);
            first = false;
        }

        if (result.items.len == 0) {
            return line;
        }

        return try allocator.dupe(u8, result.items);
    }
};

/// Field range for nth specs.
pub const FieldRange = struct {
    start: ?i32 = null,
    end: ?i32 = null,

    fn parse(s: []const u8) ?FieldRange {
        if (s.len == 0) return null;

        if (std.mem.indexOf(u8, s, "..")) |dotdot| {
            const start_str = s[0..dotdot];
            const end_str = s[dotdot + 2 ..];

            var range = FieldRange{};
            if (start_str.len > 0) {
                range.start = std.fmt.parseInt(i32, start_str, 10) catch return null;
            }
            if (end_str.len > 0) {
                range.end = std.fmt.parseInt(i32, end_str, 10) catch return null;
            }
            return range;
        }

        const n = std.fmt.parseInt(i32, s, 10) catch return null;
        return FieldRange{ .start = n, .end = n };
    }

    fn matches(self: FieldRange, idx: usize, total: usize) bool {
        const i: i32 = @intCast(idx + 1);
        const t: i32 = @intCast(total);

        const start = if (self.start) |s| (if (s < 0) t + s + 1 else s) else 1;
        const end = if (self.end) |e| (if (e < 0) t + e + 1 else e) else t;

        return i >= start and i <= end;
    }
};
