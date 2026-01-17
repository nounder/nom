//! Gitignore handling for fd-zig.
//!
//! Implements proper gitignore semantics:
//! - Pattern matching with *, **, ?, [...]
//! - Negation patterns (!)
//! - Directory-only patterns (trailing /)
//! - Anchored patterns (leading / or containing /)
//! - Hierarchical stacking (child .gitignore overrides parent)
//! - Last-match-wins semantics

const std = @import("std");

/// A compiled ignore pattern.
pub const IgnorePattern = struct {
    pattern: []const u8,
    is_negation: bool,
    is_dir_only: bool,
    anchored: bool,

    /// Match a path against this pattern.
    pub fn matches(self: IgnorePattern, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
        if (self.is_dir_only and !is_dir) return false;

        if (self.anchored) {
            return globMatch(self.pattern, rel_path);
        } else {
            return globMatch(self.pattern, name);
        }
    }
};

/// Glob matching for gitignore patterns.
/// Supports: * (any non-slash), ** (any including slashes), ? (single non-slash), [...] (char class)
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;

    var star_pi: usize = 0;
    var star_ti: usize = 0;
    var has_star = false;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];

            // Check for **
            if (pc == '*' and pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                if (pi >= pattern.len) return true;

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
                pi += 1;
                ti += 1;
                continue;
            }
        }

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

/// Manages ignore patterns for a single directory level.
/// Can hold merged patterns from multiple sources (.gitignore, .ignore, .fdignore).
pub const IgnoreFile = struct {
    patterns: []IgnorePattern,
    /// Owned content buffers (one per source file that was merged)
    contents: [][]const u8,

    pub fn deinit(self: IgnoreFile, allocator: std.mem.Allocator) void {
        allocator.free(self.patterns);
        for (self.contents) |c| {
            allocator.free(c);
        }
        allocator.free(self.contents);
    }

    /// Load ignore patterns from an absolute path.
    pub fn loadAbsolute(allocator: std.mem.Allocator, path: []const u8) !?IgnoreFile {
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => return null,
            else => return err,
        };
        errdefer allocator.free(content);

        var patterns: std.ArrayListUnmanaged(IgnorePattern) = .{};
        errdefer patterns.deinit(allocator);

        parseInto(allocator, content, &patterns);

        if (patterns.items.len == 0) {
            allocator.free(content);
            return null;
        }

        // Create a single-element contents array
        const contents = try allocator.alloc([]const u8, 1);
        contents[0] = content;

        return .{
            .patterns = try patterns.toOwnedSlice(allocator),
            .contents = contents,
        };
    }

    /// Create IgnoreFile from pre-read content buffers.
    /// Contents should be in precedence order (lowest first for last-match-wins).
    /// Takes ownership of the content slices.
    pub fn fromContents(allocator: std.mem.Allocator, contents: [][]const u8) !?IgnoreFile {
        if (contents.len == 0) {
            allocator.free(contents);
            return null;
        }

        var patterns: std.ArrayListUnmanaged(IgnorePattern) = .{};
        errdefer patterns.deinit(allocator);

        for (contents) |content| {
            parseInto(allocator, content, &patterns);
        }

        if (patterns.items.len == 0) {
            for (contents) |c| allocator.free(c);
            allocator.free(contents);
            return null;
        }

        return .{
            .patterns = try patterns.toOwnedSlice(allocator),
            .contents = contents,
        };
    }

    /// Parse ignore file content and append patterns to the list.
    fn parseInto(allocator: std.mem.Allocator, content: []const u8, patterns: *std.ArrayListUnmanaged(IgnorePattern)) void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var pat = trimmed;
            var is_negation = false;
            var is_dir_only = false;
            var anchored = false;

            if (pat[0] == '!') {
                is_negation = true;
                pat = pat[1..];
                if (pat.len == 0) continue;
            }

            if (pat[pat.len - 1] == '/') {
                is_dir_only = true;
                pat = pat[0 .. pat.len - 1];
                if (pat.len == 0) continue;
            }

            if (pat[0] == '/') {
                anchored = true;
                pat = pat[1..];
            } else if (std.mem.indexOfScalar(u8, pat, '/') != null) {
                anchored = true;
            }

            patterns.append(allocator, .{
                .pattern = pat,
                .is_negation = is_negation,
                .is_dir_only = is_dir_only,
                .anchored = anchored,
            }) catch {};
        }
    }

    /// Check if a path should be ignored. Returns null if no pattern matches.
    pub fn check(self: IgnoreFile, name: []const u8, rel_path: []const u8, is_dir: bool) ?bool {
        var result: ?bool = null;
        for (self.patterns) |p| {
            if (p.matches(name, rel_path, is_dir)) {
                result = !p.is_negation;
            }
        }
        return result;
    }
};

/// Options for IgnoreStack.
pub const IgnoreOptions = struct {
    /// Respect .gitignore files
    read_gitignore: bool = true,
    /// Only read .gitignore in git repositories
    require_git: bool = true,
    /// Respect .fdignore files
    read_fdignore: bool = true,
    /// Respect .ignore files
    read_ignore: bool = true,
    /// Respect global ~/.fdignore
    read_global_fdignore: bool = true,
};

/// A level in the ignore stack.
const IgnoreLevel = struct {
    /// Merged ignore patterns from all sources at this level
    ignore: ?IgnoreFile,
    path_len: usize,
    has_git: bool, // This directory contains .git
};

/// Stack of ignore files from root to current directory.
/// Implements proper gitignore hierarchy with last-match-wins semantics.
pub const IgnoreStack = struct {
    allocator: std.mem.Allocator,
    options: IgnoreOptions,
    levels: std.ArrayListUnmanaged(IgnoreLevel),
    global_fdignore: ?IgnoreFile,

    pub fn init(allocator: std.mem.Allocator, options: IgnoreOptions) IgnoreStack {
        // Load global ~/.fdignore
        var global_fdignore: ?IgnoreFile = null;
        if (options.read_global_fdignore) {
            if (std.posix.getenv("HOME")) |home| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/.fdignore", .{home}) catch null;
                if (path) |p| {
                    global_fdignore = IgnoreFile.loadAbsolute(allocator, p) catch null;
                }
            }
        }

        return .{
            .allocator = allocator,
            .options = options,
            .levels = .{},
            .global_fdignore = global_fdignore,
        };
    }

    pub fn deinit(self: *IgnoreStack) void {
        for (self.levels.items) |level| {
            if (level.ignore) |ig| ig.deinit(self.allocator);
        }
        self.levels.deinit(self.allocator);
        if (self.global_fdignore) |gf| gf.deinit(self.allocator);
    }

    /// Check if we're currently in a git repository subtree.
    /// A subtree is a git repo if any level from root to current has .git.
    pub fn inGitRepo(self: *IgnoreStack) bool {
        for (self.levels.items) |level| {
            if (level.has_git) return true;
        }
        return false;
    }

    /// Push a level with pre-loaded ignore patterns onto the stack.
    pub fn pushLevel(self: *IgnoreStack, ig: ?IgnoreFile, path_len: usize, has_git: bool) !void {
        try self.levels.append(self.allocator, .{
            .ignore = ig,
            .path_len = path_len,
            .has_git = has_git,
        });
    }

    /// Pop the current directory from the stack.
    pub fn popDir(self: *IgnoreStack) void {
        if (self.levels.items.len > 0) {
            if (self.levels.pop()) |level| {
                if (level.ignore) |ig| ig.deinit(self.allocator);
            }
        }
    }

    /// Check if a hidden file/dir is explicitly included via negation pattern.
    /// This allows patterns like `!.claude/` to un-ignore hidden files.
    pub fn isExplicitlyIncluded(self: *IgnoreStack, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
        // Check each directory level for negation patterns that match this path
        for (self.levels.items) |level| {
            const level_rel = if (level.path_len == 0)
                rel_path
            else if (level.path_len < rel_path.len)
                rel_path[level.path_len + 1 ..]
            else
                name;

            if (level.ignore) |ig| {
                for (ig.patterns) |p| {
                    if (p.is_negation and p.matches(name, level_rel, is_dir)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Check if a path should be ignored.
    /// Patterns are checked in order with last-match-wins semantics.
    /// Global ~/.fdignore has highest priority.
    pub fn isIgnored(self: *IgnoreStack, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
        var result: ?bool = null;

        // Check each directory level
        for (self.levels.items) |level| {
            // Compute path relative to this level's location
            const level_rel = if (level.path_len == 0)
                rel_path
            else if (level.path_len < rel_path.len)
                rel_path[level.path_len + 1 ..]
            else
                name;

            if (level.ignore) |ig| {
                if (ig.check(name, level_rel, is_dir)) |r| {
                    result = r;
                }
            }
        }

        // Global ~/.fdignore has highest priority - cannot be overridden by local patterns
        if (self.global_fdignore) |gf| {
            if (gf.check(name, rel_path, is_dir)) |r| {
                result = r;
            }
        }

        return result orelse false;
    }
};

// Tests

test "globMatch basic" {
    try std.testing.expect(globMatch("foo", "foo"));
    try std.testing.expect(!globMatch("foo", "bar"));
    try std.testing.expect(!globMatch("foo", "foobar"));
}

test "globMatch wildcards" {
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("foo*", "foobar"));
    try std.testing.expect(globMatch("*bar", "foobar"));

    try std.testing.expect(globMatch("**/*.txt", "file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "a/b/c/file.txt"));
}

test "globMatch question mark" {
    try std.testing.expect(globMatch("?.txt", "a.txt"));
    try std.testing.expect(!globMatch("?.txt", "ab.txt"));
}

test "globMatch character class" {
    try std.testing.expect(globMatch("[abc]", "a"));
    try std.testing.expect(globMatch("[abc]", "b"));
    try std.testing.expect(!globMatch("[abc]", "d"));
    try std.testing.expect(globMatch("[a-z]", "m"));
    try std.testing.expect(!globMatch("[a-z]", "A"));
    try std.testing.expect(globMatch("[!a-z]", "A"));
}

test "IgnorePattern.matches" {
    const p1 = IgnorePattern{
        .pattern = "*.log",
        .is_negation = false,
        .is_dir_only = false,
        .anchored = false,
    };
    try std.testing.expect(p1.matches("debug.log", "debug.log", false));
    try std.testing.expect(p1.matches("debug.log", "foo/debug.log", false));

    const p2 = IgnorePattern{
        .pattern = "build",
        .is_negation = false,
        .is_dir_only = false,
        .anchored = true,
    };
    try std.testing.expect(p2.matches("build", "build", true));
    try std.testing.expect(!p2.matches("build", "src/build", true));

    const p3 = IgnorePattern{
        .pattern = "logs",
        .is_negation = false,
        .is_dir_only = true,
        .anchored = false,
    };
    try std.testing.expect(p3.matches("logs", "logs", true));
    try std.testing.expect(!p3.matches("logs", "logs", false));
}
