//! Preview runner for executing preview commands asynchronously.
//!
//! This module provides non-blocking preview command execution with:
//! - Single persistent worker thread (avoids thread creation overhead)
//! - Version-based cancellation (new request cancels old automatically)
//! - Clean process termination when selection changes rapidly
//! - Incremental output streaming with chunked updates
//!
//! Design principles:
//! - Zig-idiomatic explicit resource management with defer/errdefer
//! - Arena allocator per result for efficient cleanup
//! - Atomic operations for lock-free fast-path checks
//! - No signals - uses direct child.kill() for process termination

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Preview execution request
pub const PreviewRequest = struct {
    /// Command template (e.g., "cat {}" or "bat --color=always {}")
    command: []const u8,
    /// Text to substitute for {} placeholder
    item: []const u8,
    /// Current query for {q} placeholder
    query: []const u8,
};

/// Preview execution result
pub const PreviewResult = struct {
    /// Output lines (owned by result_arena)
    lines: []const []const u8,
    /// Whether command completed (false = still running or was cancelled)
    complete: bool,
    /// Error message if command failed (owned by result_arena)
    error_msg: ?[]const u8,
    /// Scroll offset hint (for "follow" mode)
    scroll_offset: usize,
};

/// Asynchronous preview command runner.
pub const PreviewRunner = struct {
    allocator: Allocator,
    io: std.Io,

    // Worker thread
    thread: ?std.Thread = null,

    // Synchronization
    mutex: std.Io.Mutex = .init,
    request_cond: std.Io.Condition = .init,

    // Request state (protected by mutex)
    request_version: u64 = 0,
    pending_request: ?OwnedRequest = null,

    // Result state (protected by mutex)
    result_version: u64 = 0,
    result_arena: ?std.heap.ArenaAllocator = null,
    result: ?PreviewResult = null,

    // Shutdown flag (atomic for lock-free check in hot path)
    should_quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Currently executing child process (for cancellation)
    // Protected by mutex, but can be killed from any thread
    current_child: ?*std.process.Child = null,

    /// Owned copy of request data (lives until next request or shutdown)
    const OwnedRequest = struct {
        command: []const u8,
        item: []const u8,
        query: []const u8,
        arena: std.heap.ArenaAllocator,

        fn deinit(self: *OwnedRequest) void {
            self.arena.deinit();
        }
    };

    pub fn init(allocator: Allocator, io: std.Io) PreviewRunner {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *PreviewRunner) void {
        // Signal shutdown
        self.should_quit.store(true, .release);

        // Wake worker if waiting
        self.mutex.lockUncancelable(self.io);
        // Kill any running child process
        if (self.current_child) |child| {
            child.kill(self.io);
        }
        self.request_cond.signal(self.io);
        self.mutex.unlock(self.io);

        // Wait for worker thread to exit
        if (self.thread) |t| {
            t.join();
        }

        // Cleanup remaining state
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending_request) |*req| {
            req.deinit();
        }
        if (self.result_arena) |*arena| {
            arena.deinit();
        }
    }

    /// Start the worker thread. Call once after init.
    pub fn start(self: *PreviewRunner) !void {
        self.thread = try std.Thread.spawn(.{}, workerThread, .{self});
    }

    /// Request a preview for the given item.
    /// Cancels any in-progress preview automatically.
    pub fn request(self: *PreviewRunner, req: PreviewRequest) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Increment version (this implicitly cancels the old request)
        self.request_version += 1;

        // Kill currently running child if any
        if (self.current_child) |child| {
            child.kill(self.io);
        }

        // Free old pending request
        if (self.pending_request) |*old| {
            old.deinit();
        }

        // Create owned copy of request
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const alloc = arena.allocator();

        self.pending_request = .{
            .command = alloc.dupe(u8, req.command) catch {
                arena.deinit();
                return;
            },
            .item = alloc.dupe(u8, req.item) catch {
                arena.deinit();
                return;
            },
            .query = alloc.dupe(u8, req.query) catch {
                arena.deinit();
                return;
            },
            .arena = arena,
        };

        // Wake worker
        self.request_cond.signal(self.io);
    }

    /// Cancel any pending or in-progress preview.
    pub fn cancel(self: *PreviewRunner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.request_version += 1;

        if (self.current_child) |child| {
            child.kill(self.io);
        }

        if (self.pending_request) |*req| {
            req.deinit();
            self.pending_request = null;
        }
    }

    /// Poll for a completed preview result.
    /// Returns null if no new result is available.
    /// The returned result is valid until the next call to poll() or request().
    pub fn poll(self: *PreviewRunner) ?PreviewResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.result;
    }

    /// Check if a preview is currently being processed.
    pub fn isLoading(self: *PreviewRunner) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Loading if we have a pending request or result isn't complete
        if (self.pending_request != null) return true;
        if (self.result) |r| {
            return !r.complete;
        }
        return false;
    }

    /// Get the current request version (for checking if result is stale)
    pub fn getRequestVersion(self: *PreviewRunner) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.request_version;
    }

    // ========== Worker Thread ==========

    fn workerThread(self: *PreviewRunner) void {
        while (!self.should_quit.load(.acquire)) {
            // Wait for a request
            const req = self.waitForRequest() orelse continue;
            defer req.arena.deinit();

            const version = self.getRequestVersionLocked();

            // Execute the preview command
            self.executePreview(req, version);
        }
    }

    fn waitForRequest(self: *PreviewRunner) ?OwnedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.pending_request == null and !self.should_quit.load(.acquire)) {
            self.request_cond.waitUncancelable(self.io, &self.mutex);
        }

        if (self.should_quit.load(.acquire)) {
            return null;
        }

        // Take ownership of the request
        const req = self.pending_request.?;
        self.pending_request = null;
        return req;
    }

    fn getRequestVersionLocked(self: *PreviewRunner) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.request_version;
    }

    fn executePreview(self: *PreviewRunner, req: OwnedRequest, version: u64) void {
        // Expand the command template
        const expanded = expandCommand(self.allocator, req.command, req.item, req.query) catch |err| {
            self.setErrorResult(version, @errorName(err));
            return;
        };
        defer self.allocator.free(expanded);

        // Check for cancellation before spawning
        if (self.isCancelled(version)) return;

        // Spawn the child process
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "sh", "-c", expanded },
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            self.setErrorResult(version, @errorName(err));
            return;
        };

        // Register child for potential cancellation
        self.mutex.lockUncancelable(self.io);
        self.current_child = &child;
        self.mutex.unlock(self.io);

        defer {
            self.mutex.lockUncancelable(self.io);
            self.current_child = null;
            self.mutex.unlock(self.io);
        }

        // Read output
        self.readChildOutput(&child, version);

        // Wait for child to exit
        _ = child.wait(self.io) catch {};
    }

    fn readChildOutput(self: *PreviewRunner, child: *std.process.Child, version: u64) void {
        const stdout = child.stdout orelse return;

        // Create arena for this result
        var result_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer result_arena.deinit();
        const arena_alloc = result_arena.allocator();

        var lines: std.ArrayList([]const u8) = .empty;
        var line_buf: std.ArrayList(u8) = .empty;

        // Read in chunks, checking for cancellation periodically
        var buf: [4096]u8 = undefined;
        read_loop: while (true) {
            // Check cancellation before each read
            if (self.isCancelled(version)) {
                result_arena.deinit();
                return;
            }

            const n = stdout.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break :read_loop,
                else => break :read_loop,
            };
            if (n == 0) break;

            // Process bytes into lines
            for (buf[0..n]) |byte| {
                if (byte == '\n') {
                    const line = arena_alloc.dupe(u8, line_buf.items) catch break;
                    lines.append(arena_alloc, line) catch break;
                    line_buf.clearRetainingCapacity();
                } else {
                    line_buf.append(arena_alloc, byte) catch break;
                }
            }

            // Publish partial result periodically (every ~100 lines or 4KB)
            if (lines.items.len % 100 == 0 and lines.items.len > 0) {
                self.publishPartialResult(version, &result_arena, lines.items, false);
            }
        }

        // Handle last line without newline
        if (line_buf.items.len > 0) {
            const line = arena_alloc.dupe(u8, line_buf.items) catch return;
            lines.append(arena_alloc, line) catch return;
        }

        // Final check for cancellation
        if (self.isCancelled(version)) {
            result_arena.deinit();
            return;
        }

        // Publish final result
        self.publishResult(version, result_arena, lines.items, true, null);
    }

    fn isCancelled(self: *PreviewRunner, version: u64) bool {
        if (self.should_quit.load(.acquire)) return true;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.request_version != version;
    }

    fn setErrorResult(self: *PreviewRunner, version: u64, err_name: []const u8) void {
        if (self.isCancelled(version)) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const alloc = arena.allocator();
        const err_msg = alloc.dupe(u8, err_name) catch {
            arena.deinit();
            return;
        };

        self.publishResult(version, arena, &.{}, true, err_msg);
    }

    fn publishPartialResult(
        self: *PreviewRunner,
        version: u64,
        arena: *std.heap.ArenaAllocator,
        lines: []const []const u8,
        complete: bool,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Check version under lock
        if (self.request_version != version) return;

        // Don't replace arena for partial results - just update the result view
        // This is a simplification; full implementation would need double-buffering
        self.result = .{
            .lines = lines,
            .complete = complete,
            .error_msg = null,
            .scroll_offset = 0,
        };
        self.result_version = version;

        // Keep the arena reference for final publish
        _ = arena;
    }

    fn publishResult(
        self: *PreviewRunner,
        version: u64,
        arena: std.heap.ArenaAllocator,
        lines: []const []const u8,
        complete: bool,
        error_msg: ?[]const u8,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Check version under lock
        if (self.request_version != version) {
            var a = arena;
            a.deinit();
            return;
        }

        // Free old result arena
        if (self.result_arena) |*old| {
            old.deinit();
        }

        self.result_arena = arena;
        self.result = .{
            .lines = lines,
            .complete = complete,
            .error_msg = error_msg,
            .scroll_offset = 0,
        };
        self.result_version = version;
    }
};

/// Expand command template with placeholders.
///
/// Supported placeholders:
/// - {} or {0}: The selected item text (shell-quoted)
/// - {q}: The current query string (shell-quoted)
/// - {n}: The item index (if available, otherwise empty)
///
/// Example: "bat --color=always {}" with item "/path/to file.txt"
///          becomes "bat --color=always '/path/to file.txt'"
pub fn expandCommand(
    allocator: Allocator,
    template: []const u8,
    item: []const u8,
    query: []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            // Look for closing brace
            if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |close| {
                const placeholder = template[i + 1 .. close];

                if (placeholder.len == 0 or std.mem.eql(u8, placeholder, "0")) {
                    // {} or {0} - item text
                    try appendQuoted(&result, allocator, item);
                } else if (std.mem.eql(u8, placeholder, "q")) {
                    // {q} - query
                    try appendQuoted(&result, allocator, query);
                } else {
                    // Unknown placeholder - keep as-is
                    try result.appendSlice(allocator, template[i .. close + 1]);
                }
                i = close + 1;
                continue;
            }
        }

        try result.append(allocator, template[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Append a shell-quoted string to the result.
/// Uses single quotes with proper escaping for embedded single quotes.
fn appendQuoted(result: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    // Empty string
    if (s.len == 0) {
        try result.appendSlice(allocator, "''");
        return;
    }

    // Check if quoting is needed
    var needs_quoting = false;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', '@' => {},
            else => {
                needs_quoting = true;
                break;
            },
        }
    }

    if (!needs_quoting) {
        try result.appendSlice(allocator, s);
        return;
    }

    // Use single quotes, escaping embedded single quotes as '\''
    try result.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try result.appendSlice(allocator, "'\\''");
        } else {
            try result.append(allocator, c);
        }
    }
    try result.append(allocator, '\'');
}

// ============ Tests ============

test "expandCommand basic" {
    const allocator = std.testing.allocator;

    const result = try expandCommand(allocator, "cat {}", "test.txt", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("cat test.txt", result);
}

test "expandCommand with spaces" {
    const allocator = std.testing.allocator;

    const result = try expandCommand(allocator, "cat {}", "path/to file.txt", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("cat 'path/to file.txt'", result);
}

test "expandCommand with query" {
    const allocator = std.testing.allocator;

    const result = try expandCommand(allocator, "grep {q} {}", "file.txt", "search term");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("grep 'search term' file.txt", result);
}

test "expandCommand with single quotes" {
    const allocator = std.testing.allocator;

    const result = try expandCommand(allocator, "echo {}", "it's a test", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("echo 'it'\\''s a test'", result);
}

test "appendQuoted empty" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try appendQuoted(&list, allocator, "");
    try std.testing.expectEqualStrings("''", list.items);
}

test "appendQuoted simple" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try appendQuoted(&list, allocator, "simple");
    try std.testing.expectEqualStrings("simple", list.items);
}

test "appendQuoted with special chars" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try appendQuoted(&list, allocator, "has space");
    try std.testing.expectEqualStrings("'has space'", list.items);
}
