const std = @import("std");
const ignore = @import("ignore.zig");
const IgnoreFile = ignore.IgnoreFile;
const IgnoreStack = ignore.IgnoreStack;

pub const WalkOptions = struct {
    ignore_hidden: bool = true,
    read_gitignore: bool = true,
    require_git: bool = true,
    read_ignore: bool = true,
    read_fdignore: bool = true,
    follow_symlinks: bool = false,
    max_depth: ?usize = null,
    min_depth: ?usize = null,
    exclude_patterns: []const []const u8 = &.{},
};

pub const Entry = struct {
    path: []const u8,
    /// Basename points into `path`
    name: []const u8,
    depth: usize,
    kind: std.fs.Dir.Entry.Kind,
    dir: std.fs.Dir,
    cached_stat: ?std.fs.File.Stat = null,

    pub fn stat(self: *Entry) !std.fs.File.Stat {
        if (self.cached_stat) |s| return s;

        const s = try self.dir.statFile(self.name);
        self.cached_stat = s;
        return s;
    }

    pub fn isEmpty(self: *Entry) !bool {
        if (self.kind != .directory) return false;

        var subdir = try self.dir.openDir(self.name, .{ .iterate = true });
        defer subdir.close();

        var iter = subdir.iterate();
        return (try iter.next()) == null;
    }
};

pub const LevelFlag = enum {
    git,
};

const WalkLevel = struct {
    iter: std.fs.Dir.Iterator,
    dir: std.fs.Dir,
    path_len: usize,
    depth: usize,
    flags: std.EnumSet(LevelFlag),
};

pub const Walker = struct {
    allocator: std.mem.Allocator,
    options: WalkOptions,
    stack: std.ArrayListUnmanaged(WalkLevel),
    path_buf: std.ArrayListUnmanaged(u8),
    ignore_stack: IgnoreStack,
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
                .read_ignore = options.read_ignore,
                .read_fdignore = options.read_fdignore,
            }),
        };
    }

    const MAX_IGNORE_SIZE = 1024 * 1024;

    fn inGitRepo(self: *Walker) bool {
        for (self.stack.items) |level| {
            if (level.flags.contains(.git)) return true;
        }
        return false;
    }

    fn loadIgnoreFiles(self: *Walker, dir: std.fs.Dir, in_git: bool) !?IgnoreFile {
        var contents: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (contents.items) |c| self.allocator.free(c);
            contents.deinit(self.allocator);
        }

        const read_gitignore = self.options.read_gitignore and
            (!self.options.require_git or in_git);

        if (read_gitignore) {
            if (dir.readFileAlloc(self.allocator, ".gitignore", MAX_IGNORE_SIZE)) |c| {
                try contents.append(self.allocator, c);
            } else |_| {}
        }
        if (self.options.read_ignore) {
            if (dir.readFileAlloc(self.allocator, ".ignore", MAX_IGNORE_SIZE)) |c| {
                try contents.append(self.allocator, c);
            } else |_| {}
        }
        if (self.options.read_fdignore) {
            if (dir.readFileAlloc(self.allocator, ".fdignore", MAX_IGNORE_SIZE)) |c| {
                try contents.append(self.allocator, c);
            } else |_| {}
        }

        if (contents.items.len == 0) {
            contents.deinit(self.allocator);
            return null;
        }

        return try IgnoreFile.fromContents(
            self.allocator,
            try contents.toOwnedSlice(self.allocator),
        );
    }

    fn pushDirIgnore(self: *Walker, dir: std.fs.Dir, path_len: usize) !std.EnumSet(LevelFlag) {
        var flags = std.EnumSet(LevelFlag){};

        if (dir.access(".git", .{})) |_| {
            flags.insert(.git);
        } else |_| {}

        const in_git = flags.contains(.git) or self.inGitRepo();

        const ig = try self.loadIgnoreFiles(dir, in_git);

        try self.ignore_stack.pushLevel(ig, path_len);

        return flags;
    }

    pub fn deinit(self: *Walker) void {
        for (self.stack.items) |*level| {
            level.dir.close();
        }
        self.stack.deinit(self.allocator);
        self.path_buf.deinit(self.allocator);
        self.ignore_stack.deinit();
    }

    pub fn start(self: *Walker) !void {
        try self.startAt(std.fs.cwd(), ".");
    }

    pub fn startAt(self: *Walker, dir: std.fs.Dir, path: []const u8) !void {
        _ = path;
        if (self.started) return error.AlreadyStarted;
        self.started = true;

        var root_dir = try dir.openDir(".", .{ .iterate = true });
        errdefer root_dir.close();

        // Load ignore files for root (path_len = 0)
        const flags = try self.pushDirIgnore(root_dir, 0);

        try self.stack.append(self.allocator, .{
            .iter = root_dir.iterateAssumeFirstIteration(),
            .dir = root_dir,
            .path_len = 0,
            .depth = 0,
            .flags = flags,
        });
    }

    /// Get the next matching entry.
    pub fn next(self: *Walker) !?Entry {
        while (self.stack.items.len > 0) {
            // Note: We use indices rather than pointers since stack may reallocate
            const level_idx = self.stack.items.len - 1;

            // Reset path buffer to this directory's prefix
            self.path_buf.items.len = self.stack.items[level_idx].path_len;

            const entry = self.stack.items[level_idx].iter.next() catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            } orelse {
                // Directory exhausted, pop level
                self.stack.items[level_idx].dir.close();
                self.ignore_stack.popLevel();
                _ = self.stack.pop();
                continue;
            };

            // Build relative path (need this first for ignore checks)
            if (self.stack.items[level_idx].path_len > 0) {
                try self.path_buf.append(self.allocator, '/');
            }
            const name_start = self.path_buf.items.len;
            try self.path_buf.appendSlice(self.allocator, entry.name);
            const rel_path = self.path_buf.items[0..];
            const name = self.path_buf.items[name_start..];

            const is_dir = entry.kind == .directory;

            // Skip hidden entries if configured, but allow explicitly included ones
            if (self.options.ignore_hidden) {
                if (entry.name.len > 0 and entry.name[0] == '.') {
                    // Check if this hidden entry is explicitly included via negation pattern
                    if (!self.ignore_stack.isExplicitlyIncluded(name, rel_path, is_dir)) {
                        continue;
                    }
                }
            }

            const depth = self.stack.items[level_idx].depth;
            const parent_dir = self.stack.items[level_idx].dir;  // Capture before potential realloc

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
                    // Open and push subdirectory
                    // Note: Even if we can't open the dir, we still return it as a result
                    if (parent_dir.openDir(entry.name, .{ .iterate = true })) |subdir_opened| {
                        var subdir = subdir_opened;
                        errdefer subdir.close();

                        const new_path_len = self.path_buf.items.len;
                        const subdir_flags = try self.pushDirIgnore(subdir, new_path_len);

                        // This append may reallocate - don't use level_idx after this
                        try self.stack.append(self.allocator, .{
                            .iter = subdir.iterateAssumeFirstIteration(),
                            .dir = subdir,
                            .path_len = new_path_len,
                            .depth = depth + 1,
                            .flags = subdir_flags,
                        });
                    } else |err| switch (err) {
                        error.AccessDenied, error.PermissionDenied, error.FileNotFound => {
                            // Can't descend, but still return the directory entry below
                        },
                        else => return err,
                    }
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
