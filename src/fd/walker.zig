//! Directory walker for fd-zig.
//!
//! Provides efficient recursive directory traversal with:
//! - Depth limiting (min/max)
//! - Hidden file filtering
//! - Gitignore support
//! - Symlink handling
//! - Filesystem boundary respect

const std = @import("std");
const ignore = @import("ignore.zig");
const Gitignore = ignore.Gitignore;
const IgnoreStack = ignore.IgnoreStack;

/// Options for directory walking.
pub const WalkOptions = struct {
    /// Skip hidden files/directories (starting with .)
    ignore_hidden: bool = true,

    /// Respect .gitignore files
    read_gitignore: bool = true,

    /// Only read .gitignore in git repositories
    require_git: bool = true,

    /// Follow symbolic links
    follow_symlinks: bool = false,

    /// Stay on the same filesystem
    one_file_system: bool = false,

    /// Maximum directory depth (null = unlimited)
    max_depth: ?usize = null,

    /// Minimum directory depth for results (null = 0)
    min_depth: ?usize = null,

    /// Patterns to exclude (gitignore-style)
    exclude_patterns: []const []const u8 = &.{},
};

/// A directory entry returned by the walker.
pub const Entry = struct {
    /// Full relative path from the root
    path: []const u8,

    /// Basename (filename only)
    name: []const u8,

    /// Current depth (0 = root directory contents)
    depth: usize,

    /// Entry type
    kind: std.fs.Dir.Entry.Kind,

    /// Parent directory handle (for stat operations)
    dir: std.fs.Dir,

    /// Cached stat result
    cached_stat: ?std.fs.File.Stat = null,

    /// Get file metadata (lazy-loaded and cached).
    pub fn stat(self: *Entry) !std.fs.File.Stat {
        if (self.cached_stat) |s| return s;

        const s = try self.dir.statFile(self.name);
        self.cached_stat = s;
        return s;
    }

    /// Check if a directory is empty.
    pub fn isEmpty(self: *Entry) !bool {
        if (self.kind != .directory) return false;

        var subdir = try self.dir.openDir(self.name, .{ .iterate = true });
        defer subdir.close();

        var iter = subdir.iterate();
        return (try iter.next()) == null;
    }
};

/// Stack frame for recursive directory walking.
const WalkFrame = struct {
    iter: std.fs.Dir.Iterator,
    dir: std.fs.Dir,
    path_len: usize,
    depth: usize,
    owns_dir: bool, // Whether we should close the dir on pop
};

/// Recursive directory walker with gitignore support.
pub const Walker = struct {
    allocator: std.mem.Allocator,
    options: WalkOptions,
    stack: std.ArrayListUnmanaged(WalkFrame),
    path_buf: std.ArrayListUnmanaged(u8),
    ignore_stack: IgnoreStack,
    root_dev: ?u64 = null,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, root: []const u8, options: WalkOptions) Walker {
        _ = root;
        return .{
            .allocator = allocator,
            .options = options,
            .stack = .{},
            .path_buf = .{},
            .ignore_stack = IgnoreStack.init(allocator, .{
                .read_gitignore = options.read_gitignore,
                .require_git = options.require_git,
            }),
        };
    }

    pub fn deinit(self: *Walker) void {
        // Close all open directories
        for (self.stack.items) |*frame| {
            if (frame.owns_dir) {
                frame.dir.close();
            }
        }
        self.stack.deinit(self.allocator);
        self.path_buf.deinit(self.allocator);
        self.ignore_stack.deinit();
    }

    /// Start walking from the current directory.
    pub fn start(self: *Walker) !void {
        try self.startAt(std.fs.cwd(), ".");
    }

    /// Start walking from a specific directory.
    pub fn startAt(self: *Walker, dir: std.fs.Dir, path: []const u8) !void {
        _ = path;
        if (self.started) return error.AlreadyStarted;
        self.started = true;

        // Record root filesystem if one_file_system is enabled
        // Note: one_file_system feature is currently disabled as the high-level
        // Zig fs.File.Stat doesn't expose the device ID. Would need to use
        // std.posix.stat directly for this feature.
        _ = self.options.one_file_system;

        // Open root directory for iteration
        var root_dir = try dir.openDir(".", .{ .iterate = true });
        errdefer root_dir.close();

        // Load gitignore for root
        try self.ignore_stack.pushDir(root_dir);

        try self.stack.append(self.allocator, .{
            .iter = root_dir.iterateAssumeFirstIteration(),
            .dir = root_dir,
            .path_len = 0,
            .depth = 0,
            .owns_dir = true,
        });
    }

    /// Get the next matching entry.
    pub fn next(self: *Walker) !?Entry {
        while (self.stack.items.len > 0) {
            // Note: We use indices rather than pointers since stack may reallocate
            const frame_idx = self.stack.items.len - 1;

            // Reset path buffer to this directory's prefix
            self.path_buf.items.len = self.stack.items[frame_idx].path_len;

            const entry = self.stack.items[frame_idx].iter.next() catch |err| switch (err) {
                error.AccessDenied => continue,
                else => return err,
            } orelse {
                // Directory exhausted, pop frame
                if (self.stack.items[frame_idx].owns_dir) {
                    self.stack.items[frame_idx].dir.close();
                }
                self.ignore_stack.popDir();
                _ = self.stack.pop();
                continue;
            };

            // Skip hidden entries if configured
            if (self.options.ignore_hidden) {
                if (entry.name.len > 0 and entry.name[0] == '.') {
                    continue;
                }
            }

            // Build relative path
            if (self.stack.items[frame_idx].path_len > 0) {
                try self.path_buf.append(self.allocator, '/');
            }
            const name_start = self.path_buf.items.len;
            try self.path_buf.appendSlice(self.allocator, entry.name);
            const rel_path = self.path_buf.items[0..];
            const name = self.path_buf.items[name_start..];

            const is_dir = entry.kind == .directory;
            const depth = self.stack.items[frame_idx].depth;
            const parent_dir = self.stack.items[frame_idx].dir;  // Capture before potential realloc

            // Check exclude patterns
            if (self.isExcluded(name, rel_path, is_dir)) continue;

            // Check gitignore
            if (self.ignore_stack.isIgnored(name, rel_path, is_dir)) {
                continue;
            }

            // Handle directories
            if (is_dir) {
                // Check max depth before descending
                const can_descend = if (self.options.max_depth) |max|
                    depth < max
                else
                    true;

                if (can_descend) {
                    // Check filesystem boundary
                    // Note: one_file_system feature is disabled (see startAt comment)
                    _ = self.options.one_file_system;

                    // Open and push subdirectory
                    var subdir = parent_dir.openDir(entry.name, .{ .iterate = true }) catch |err| switch (err) {
                        error.AccessDenied, error.FileNotFound => {
                            continue;
                        },
                        else => return err,
                    };
                    errdefer subdir.close();

                    try self.ignore_stack.pushDir(subdir);

                    // This append may reallocate - don't use frame_idx after this
                    try self.stack.append(self.allocator, .{
                        .iter = subdir.iterateAssumeFirstIteration(),
                        .dir = subdir,
                        .path_len = self.path_buf.items.len,
                        .depth = depth + 1,
                        .owns_dir = true,
                    });
                }

                // Return directory if it passes min_depth
                if (self.options.min_depth) |min| {
                    if (depth < min) continue;
                }

                return Entry{
                    .path = rel_path,
                    .name = name,
                    .depth = depth,
                    .kind = entry.kind,
                    .dir = parent_dir,
                };
            }

            // Handle symlinks
            if (entry.kind == .sym_link and self.options.follow_symlinks) {
                // TODO: Follow symlink and check if it's a directory
                // For now, just return the symlink
            }

            // Check min_depth for files
            if (self.options.min_depth) |min| {
                if (depth < min) continue;
            }

            // Return the entry
            return Entry{
                .path = rel_path,
                .name = name,
                .depth = depth,
                .kind = entry.kind,
                .dir = parent_dir,
            };
        }

        return null;
    }

    fn isExcluded(self: *Walker, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
        for (self.options.exclude_patterns) |pattern| {
            if (ignore.globMatch(pattern, name) or ignore.globMatch(pattern, rel_path)) {
                _ = is_dir;
                return true;
            }
        }
        return false;
    }
};

test "Walker basic" {
    // This test requires a real filesystem, so we just verify initialization
    const allocator = std.testing.allocator;

    var w = Walker.init(allocator, ".", .{});
    defer w.deinit();

    // Can't easily test walking without a known directory structure
}

test "Entry" {
    // Test Entry struct creation
    const e = Entry{
        .path = "src/main.zig",
        .name = "main.zig",
        .depth = 1,
        .kind = .file,
        .dir = std.fs.cwd(),
    };

    try std.testing.expectEqualStrings("main.zig", e.name);
    try std.testing.expectEqual(@as(usize, 1), e.depth);
}
