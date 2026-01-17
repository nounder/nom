//! File system utilities for nom.
//! Implements fd-like behavior: skips hidden files and respects .gitignore.

const std = @import("std");
const chunk = @import("chunklist.zig");

/// A compiled gitignore pattern.
const GitignorePattern = struct {
    pattern: []const u8,
    is_negation: bool,
    is_dir_only: bool,
    anchored: bool, // Pattern should only match from the gitignore location

    /// Match a path against this pattern.
    /// `is_dir` indicates if the path is a directory.
    /// `name` is just the filename/dirname component.
    /// `rel_path` is the path relative to the gitignore file location.
    fn matches(self: GitignorePattern, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
        if (self.is_dir_only and !is_dir) return false;

        if (self.anchored) {
            return globMatch(self.pattern, rel_path);
        } else {
            // Non-anchored: match against basename only
            return globMatch(self.pattern, name);
        }
    }
};

/// Glob matching optimized for gitignore patterns.
/// Supports: * (any non-slash), ** (any including slashes), ? (single non-slash), [...] (char class)
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;

    // For backtracking on * matches
    var star_pi: usize = 0;
    var star_ti: usize = 0;
    var has_star = false;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];

            // Check for **
            if (pc == '*' and pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                // ** matches everything including /
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                if (pi >= pattern.len) return true; // ** at end matches all

                // Try matching rest at every position
                while (ti <= text.len) {
                    if (globMatch(pattern[pi..], text[ti..])) return true;
                    if (ti < text.len) ti += 1 else break;
                }
                return false;
            }

            // Single *
            if (pc == '*') {
                star_pi = pi;
                star_ti = ti;
                has_star = true;
                pi += 1;
                continue;
            }

            // ?
            if (pc == '?') {
                if (ti < text.len and text[ti] != '/') {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            } else if (pc == '[') {
                // Character class
                if (ti < text.len) {
                    const tc = text[ti];
                    if (std.mem.indexOfScalarPos(u8, pattern, pi + 1, ']')) |end| {
                        const class = pattern[pi + 1 .. end];
                        if (matchCharClass(class, tc)) {
                            pi = end + 1;
                            ti += 1;
                            continue;
                        }
                    }
                }
            } else if (ti < text.len and pc == text[ti]) {
                // Literal match
                pi += 1;
                ti += 1;
                continue;
            }
        }

        // No match - backtrack if we had a *
        if (has_star and star_ti < text.len and text[star_ti] != '/') {
            star_ti += 1;
            ti = star_ti;
            pi = star_pi + 1;
            continue;
        }

        return false;
    }

    return true;
}

fn matchCharClass(class: []const u8, c: u8) bool {
    var i: usize = 0;
    var negated = false;

    if (i < class.len and (class[i] == '!' or class[i] == '^')) {
        negated = true;
        i += 1;
    }

    var matched = false;
    while (i < class.len) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (c >= class[i] and c <= class[i + 2]) matched = true;
            i += 3;
        } else {
            if (c == class[i]) matched = true;
            i += 1;
        }
    }

    return if (negated) !matched else matched;
}

/// Manages gitignore patterns for a single directory level.
const Gitignore = struct {
    patterns: []GitignorePattern,
    content: []const u8, // Owns the pattern string memory

    fn deinit(self: Gitignore, allocator: std.mem.Allocator) void {
        allocator.free(self.patterns);
        allocator.free(self.content);
    }

    fn load(allocator: std.mem.Allocator, dir: std.fs.Dir) !?Gitignore {
        const content = dir.readFileAlloc(allocator, ".gitignore", 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer allocator.free(content);

        var patterns: std.ArrayListUnmanaged(GitignorePattern) = .{};
        errdefer patterns.deinit(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var pattern = trimmed;
            var is_negation = false;
            var is_dir_only = false;
            var anchored = false;

            if (pattern[0] == '!') {
                is_negation = true;
                pattern = pattern[1..];
                if (pattern.len == 0) continue;
            }

            if (pattern[pattern.len - 1] == '/') {
                is_dir_only = true;
                pattern = pattern[0 .. pattern.len - 1];
                if (pattern.len == 0) continue;
            }

            // Anchored if starts with / or contains /
            if (pattern[0] == '/') {
                anchored = true;
                pattern = pattern[1..];
            } else if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
                anchored = true;
            }

            try patterns.append(allocator, .{
                .pattern = pattern,
                .is_negation = is_negation,
                .is_dir_only = is_dir_only,
                .anchored = anchored,
            });
        }

        if (patterns.items.len == 0) {
            allocator.free(content);
            return null;
        }

        return .{
            .patterns = try patterns.toOwnedSlice(allocator),
            .content = content,
        };
    }

    /// Check if a path should be ignored. Returns null if no pattern matches.
    fn check(self: Gitignore, name: []const u8, rel_path: []const u8, is_dir: bool) ?bool {
        var result: ?bool = null;
        for (self.patterns) |p| {
            if (p.matches(name, rel_path, is_dir)) {
                result = !p.is_negation;
            }
        }
        return result;
    }
};

/// Stack frame for recursive directory walking.
const WalkFrame = struct {
    iter: std.fs.Dir.Iterator,
    dir: std.fs.Dir,
    gitignore: ?Gitignore,
    path_len: usize, // Length of path prefix for this directory
};

/// Recursive directory walker that properly prunes ignored directories.
/// This is more efficient than std.fs.Dir.walk because it skips entire
/// directory subtrees when they match gitignore patterns.
pub const RecursiveWalker = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(WalkFrame),
    path_buf: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) RecursiveWalker {
        return .{
            .allocator = allocator,
            .stack = .{},
            .path_buf = .{},
        };
    }

    pub fn deinit(self: *RecursiveWalker) void {
        // Close all open directories and free gitignores
        for (self.stack.items) |*frame| {
            if (frame.gitignore) |gi| gi.deinit(self.allocator);
            frame.dir.close();
        }
        self.stack.deinit(self.allocator);
        self.path_buf.deinit(self.allocator);
    }

    pub fn start(self: *RecursiveWalker, dir: std.fs.Dir) !void {
        const gitignore = try Gitignore.load(self.allocator, dir);
        try self.stack.append(self.allocator, .{
            .iter = dir.iterateAssumeFirstIteration(),
            .dir = dir,
            .gitignore = gitignore,
            .path_len = 0,
        });
    }

    pub const Entry = struct {
        name: []const u8,
        path: []const u8,
        kind: std.fs.Dir.Entry.Kind,
    };

    /// Get next non-ignored file entry.
    pub fn next(self: *RecursiveWalker) !?Entry {
        while (self.stack.items.len > 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];

            // Reset path buffer to this directory's prefix before each entry
            self.path_buf.items.len = frame.path_len;

            const entry = frame.iter.next() catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            } orelse {
                // Directory exhausted, pop frame
                if (frame.gitignore) |gi| gi.deinit(self.allocator);
                frame.dir.close();
                _ = self.stack.pop();
                continue;
            };

            // Skip hidden entries (fd default)
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            // Build relative path
            if (frame.path_len > 0) {
                try self.path_buf.append(self.allocator, '/');
            }
            try self.path_buf.appendSlice(self.allocator, entry.name);
            const rel_path = self.path_buf.items[0..];

            const is_dir = entry.kind == .directory;

            // Check gitignore from all levels (bottom-up, last match wins)
            var ignored: ?bool = null;
            for (self.stack.items) |f| {
                if (f.gitignore) |gi| {
                    // Get path relative to this gitignore's location
                    const gi_rel = if (f.path_len == 0)
                        rel_path
                    else if (f.path_len < rel_path.len)
                        rel_path[f.path_len + 1 ..]
                    else
                        entry.name;

                    if (gi.check(entry.name, gi_rel, is_dir)) |result| {
                        ignored = result;
                    }
                }
            }

            if (ignored == true) continue;

            if (is_dir) {
                // Descend into directory
                var subdir = frame.dir.openDir(entry.name, .{ .iterate = true }) catch |err| switch (err) {
                    error.AccessDenied, error.PermissionDenied, error.FileNotFound => continue,
                    else => return err,
                };
                errdefer subdir.close();

                const sub_gitignore = try Gitignore.load(self.allocator, subdir);
                try self.stack.append(self.allocator, .{
                    .iter = subdir.iterateAssumeFirstIteration(),
                    .dir = subdir,
                    .gitignore = sub_gitignore,
                    .path_len = self.path_buf.items.len,
                });
                continue;
            }

            if (entry.kind == .file or entry.kind == .sym_link) {
                // Return the file - caller must copy path before next() call
                return Entry{
                    .name = entry.name,
                    .path = rel_path,
                    .kind = entry.kind,
                };
            }
            // Not a file or directory (special file, etc.) - will reset on next iteration
        }

        return null;
    }
};

/// Walk the current directory and collect all file paths into a newline-separated buffer.
/// Behaves like fd: skips hidden files and respects .gitignore.
pub fn walk(allocator: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    const dir = try std.fs.cwd().openDir(".", .{ .iterate = true });

    var walker = RecursiveWalker.init(allocator);
    defer walker.deinit();
    try walker.start(dir);

    while (try walker.next()) |entry| {
        try result.appendSlice(allocator, entry.path);
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

test "walk" {
    const allocator = std.testing.allocator;
    const result = try walk(allocator);
    defer allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "globMatch" {
    // Basic literal matching
    try std.testing.expect(globMatch("foo", "foo"));
    try std.testing.expect(!globMatch("foo", "bar"));
    try std.testing.expect(!globMatch("foo", "foobar"));

    // Single * wildcard
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("foo*", "foobar"));
    try std.testing.expect(globMatch("*bar", "foobar"));

    // ** wildcard
    try std.testing.expect(globMatch("**/*.txt", "file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "a/b/c/file.txt"));
    try std.testing.expect(globMatch("src/**", "src/main.zig"));
    try std.testing.expect(globMatch("src/**", "src/foo/bar.zig"));

    // ? wildcard
    try std.testing.expect(globMatch("?.txt", "a.txt"));
    try std.testing.expect(!globMatch("?.txt", "ab.txt"));

    // Directory patterns
    try std.testing.expect(globMatch("node_modules", "node_modules"));
    try std.testing.expect(globMatch("build", "build"));
}

test "GitignorePattern.matches" {
    // Simple non-anchored pattern (matches basename)
    const p1 = GitignorePattern{
        .pattern = "*.log",
        .is_negation = false,
        .is_dir_only = false,
        .anchored = false,
    };
    try std.testing.expect(p1.matches("debug.log", "debug.log", false));
    try std.testing.expect(p1.matches("debug.log", "foo/debug.log", false));

    // Anchored pattern
    const p2 = GitignorePattern{
        .pattern = "build",
        .is_negation = false,
        .is_dir_only = false,
        .anchored = true,
    };
    try std.testing.expect(p2.matches("build", "build", true));
    try std.testing.expect(!p2.matches("build", "src/build", true));

    // Directory-only pattern
    const p3 = GitignorePattern{
        .pattern = "logs",
        .is_negation = false,
        .is_dir_only = true,
        .anchored = false,
    };
    try std.testing.expect(p3.matches("logs", "logs", true));
    try std.testing.expect(!p3.matches("logs", "logs", false));
}

/// Background walker that streams file paths into chunks.
/// Compatible with the StreamingReader interface used by the TUI.
/// Behaves like fd: skips hidden files and respects .gitignore.
pub const StreamingWalker = struct {
    const CHUNK_SIZE: usize = 100;

    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged(chunk.Chunk),
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
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }

    pub fn checkError(self: *StreamingWalker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_state) |err| return err;
    }

    pub fn pollChunk(self: *StreamingWalker) ?chunk.Chunk {
        self.mutex.lock();
        defer self.mutex.unlock();

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
            self.mutex.lock();
            self.error_state = err;
            self.done = true;
            self.condition.signal();
            self.mutex.unlock();
        };
    }

    fn walkLoop(self: *StreamingWalker) !void {
        const dir = try std.fs.cwd().openDir(".", .{ .iterate = true });

        var walker = RecursiveWalker.init(self.allocator);
        defer walker.deinit();
        try walker.start(dir);

        var paths: std.ArrayListUnmanaged([]const u8) = .{};
        defer paths.deinit(self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        while (true) {
            self.mutex.lock();
            const should_stop = self.done;
            self.mutex.unlock();
            if (should_stop) break;

            const entry = try walker.next() orelse break;

            const path_copy = try arena.allocator().dupe(u8, entry.path);
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

        self.mutex.lock();
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
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

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.allocator, .{
            .items = items,
            .data = &.{},
            .arena = arena.*,
        });
        self.condition.signal();

        paths.clearRetainingCapacity();
    }
};
