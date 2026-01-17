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

/// A compiled gitignore pattern.
pub const GitignorePattern = struct {
    pattern: []const u8,
    is_negation: bool,
    is_dir_only: bool,
    anchored: bool,

    /// Match a path against this pattern.
    pub fn matches(self: GitignorePattern, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
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

/// Manages gitignore patterns for a single directory level.
pub const Gitignore = struct {
    patterns: []GitignorePattern,
    content: []const u8,

    pub fn deinit(self: Gitignore, allocator: std.mem.Allocator) void {
        allocator.free(self.patterns);
        allocator.free(self.content);
    }

    pub fn load(allocator: std.mem.Allocator, dir: std.fs.Dir) !?Gitignore {
        return loadFile(allocator, dir, ".gitignore");
    }

    /// Load ignore patterns from a specific file in a directory.
    pub fn loadFile(allocator: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !?Gitignore {
        const content = dir.readFileAlloc(allocator, filename, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => return null,
            else => return err,
        };
        return parseContent(allocator, content);
    }

    /// Load ignore patterns from an absolute path.
    pub fn loadAbsolute(allocator: std.mem.Allocator, path: []const u8) !?Gitignore {
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => return null,
            else => return err,
        };
        return parseContent(allocator, content);
    }

    /// Parse ignore content into a Gitignore struct.
    fn parseContent(allocator: std.mem.Allocator, content: []u8) !?Gitignore {
        errdefer allocator.free(content);

        var patterns: std.ArrayListUnmanaged(GitignorePattern) = .{};
        errdefer patterns.deinit(allocator);

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

            try patterns.append(allocator, .{
                .pattern = pat,
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
    pub fn check(self: Gitignore, name: []const u8, rel_path: []const u8, is_dir: bool) ?bool {
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
    gitignore: ?Gitignore,
    fdignore: ?Gitignore,
    ignore: ?Gitignore,
    path_len: usize,
    has_git: bool, // This directory contains .git
};

/// Stack of gitignore files from root to current directory.
/// Implements proper gitignore hierarchy with last-match-wins semantics.
pub const IgnoreStack = struct {
    allocator: std.mem.Allocator,
    options: IgnoreOptions,
    levels: std.ArrayListUnmanaged(IgnoreLevel),
    global_fdignore: ?Gitignore,

    pub fn init(allocator: std.mem.Allocator, options: IgnoreOptions) IgnoreStack {
        // Load global ~/.fdignore
        var global_fdignore: ?Gitignore = null;
        if (options.read_global_fdignore) {
            if (std.posix.getenv("HOME")) |home| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/.fdignore", .{home}) catch null;
                if (path) |p| {
                    global_fdignore = Gitignore.loadAbsolute(allocator, p) catch null;
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
            if (level.gitignore) |gi| gi.deinit(self.allocator);
            if (level.fdignore) |fi| fi.deinit(self.allocator);
            if (level.ignore) |ii| ii.deinit(self.allocator);
        }
        self.levels.deinit(self.allocator);
        if (self.global_fdignore) |gf| gf.deinit(self.allocator);
    }

    /// Check if we're currently in a git repository subtree.
    /// A subtree is a git repo if any level from root to current has .git.
    fn inGitRepo(self: *IgnoreStack) bool {
        for (self.levels.items) |level| {
            if (level.has_git) return true;
        }
        return false;
    }

    /// Push a directory onto the stack, loading its ignore files if present.
    /// path_len is the length of the relative path to this directory (0 for root).
    pub fn pushDir(self: *IgnoreStack, dir: std.fs.Dir, path_len: usize) !void {
        // Check for .git directory at this level
        // .git can be a directory (normal repo) or a file (worktree/submodule)
        // Use access() which works for both
        const has_git = if (dir.access(".git", .{})) |_| true else |_| false;

        var gitignore: ?Gitignore = null;
        var fdignore: ?Gitignore = null;
        var dot_ignore: ?Gitignore = null;

        // Load .gitignore (only in git repos if require_git is set)
        if (self.options.read_gitignore) {
            // Check if this subtree is a git repo (current level or any parent has .git)
            const in_git = has_git or self.inGitRepo();
            const should_read = !self.options.require_git or in_git;
            if (should_read) {
                gitignore = try Gitignore.load(self.allocator, dir);
            }
        }

        // Load .fdignore (always, if enabled)
        if (self.options.read_fdignore) {
            fdignore = try Gitignore.loadFile(self.allocator, dir, ".fdignore");
        }

        // Load .ignore (always, if enabled)
        if (self.options.read_ignore) {
            dot_ignore = try Gitignore.loadFile(self.allocator, dir, ".ignore");
        }

        try self.levels.append(self.allocator, .{
            .gitignore = gitignore,
            .fdignore = fdignore,
            .ignore = dot_ignore,
            .path_len = path_len,
            .has_git = has_git,
        });
    }

    /// Pop the current directory from the stack.
    pub fn popDir(self: *IgnoreStack) void {
        if (self.levels.items.len > 0) {
            if (self.levels.pop()) |level| {
                if (level.gitignore) |gi| gi.deinit(self.allocator);
                if (level.fdignore) |fi| fi.deinit(self.allocator);
                if (level.ignore) |ii| ii.deinit(self.allocator);
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

            // Check each ignore source
            const sources = [_]?Gitignore{ level.gitignore, level.ignore, level.fdignore };
            for (sources) |maybe_gi| {
                if (maybe_gi) |gi| {
                    // Look for negation patterns that explicitly include this path
                    for (gi.patterns) |p| {
                        if (p.is_negation and p.matches(name, level_rel, is_dir)) {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    /// Check if a path should be ignored.
    /// Priority (highest wins):
    /// 1. Global ~/.fdignore (always wins - user's personal preferences)
    /// 2. Per-level .fdignore
    /// 3. Per-level .ignore
    /// 4. Per-level .gitignore
    pub fn isIgnored(self: *IgnoreStack, name: []const u8, rel_path: []const u8, is_dir: bool) bool {
        var result: ?bool = null;

        // Check each directory level (gitignore -> .ignore -> .fdignore)
        for (self.levels.items) |level| {
            // Compute path relative to this level's location
            const level_rel = if (level.path_len == 0)
                rel_path
            else if (level.path_len < rel_path.len)
                rel_path[level.path_len + 1 ..]
            else
                name;

            // Check .gitignore
            if (level.gitignore) |gi| {
                if (gi.check(name, level_rel, is_dir)) |r| {
                    result = r;
                }
            }

            // Check .ignore (overrides .gitignore)
            if (level.ignore) |ii| {
                if (ii.check(name, level_rel, is_dir)) |r| {
                    result = r;
                }
            }

            // Check .fdignore (overrides .ignore and .gitignore)
            if (level.fdignore) |fi| {
                if (fi.check(name, level_rel, is_dir)) |r| {
                    result = r;
                }
            }
        }

        // Global ~/.fdignore has highest priority - cannot be overridden by local patterns
        // This matches fd's behavior where global fdignore represents user preferences
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

test "GitignorePattern.matches" {
    const p1 = GitignorePattern{
        .pattern = "*.log",
        .is_negation = false,
        .is_dir_only = false,
        .anchored = false,
    };
    try std.testing.expect(p1.matches("debug.log", "debug.log", false));
    try std.testing.expect(p1.matches("debug.log", "foo/debug.log", false));

    const p2 = GitignorePattern{
        .pattern = "build",
        .is_negation = false,
        .is_dir_only = false,
        .anchored = true,
    };
    try std.testing.expect(p2.matches("build", "build", true));
    try std.testing.expect(!p2.matches("build", "src/build", true));

    const p3 = GitignorePattern{
        .pattern = "logs",
        .is_negation = false,
        .is_dir_only = true,
        .anchored = false,
    };
    try std.testing.expect(p3.matches("logs", "logs", true));
    try std.testing.expect(!p3.matches("logs", "logs", false));
}
