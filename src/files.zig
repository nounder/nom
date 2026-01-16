//! File system utilities for nom.

const std = @import("std");

/// Walk the current directory and collect all file paths into a newline-separated buffer.
/// Skips .git and node_modules directories.
pub fn walk(allocator: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        // Skip ignored directories
        if (shouldSkipPath(entry.path)) continue;

        if (entry.kind == .file or entry.kind == .sym_link) {
            try result.appendSlice(allocator, entry.path);
            try result.append(allocator, '\n');
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn shouldSkipPath(path: []const u8) bool {
    return shouldSkipDir(path, ".git") or shouldSkipDir(path, "node_modules");
}

fn shouldSkipDir(path: []const u8, comptime dir: []const u8) bool {
    // Exact match at start: ".git" or ".git/..."
    if (std.mem.startsWith(u8, path, dir)) {
        if (path.len == dir.len or path[dir.len] == '/') {
            return true;
        }
    }
    // Match anywhere: ".../.git/..." or ".../.git"
    if (std.mem.indexOf(u8, path, "/" ++ dir ++ "/") != null) {
        return true;
    }
    if (std.mem.endsWith(u8, path, "/" ++ dir)) {
        return true;
    }
    return false;
}

test "walk" {
    const allocator = std.testing.allocator;
    const result = try walk(allocator);
    defer allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "shouldSkipPath" {
    try std.testing.expect(shouldSkipPath(".git"));
    try std.testing.expect(shouldSkipPath(".git/config"));
    try std.testing.expect(shouldSkipPath("foo/.git/config"));
    try std.testing.expect(shouldSkipPath("foo/.git"));
    try std.testing.expect(shouldSkipPath("node_modules"));
    try std.testing.expect(shouldSkipPath("node_modules/foo"));
    try std.testing.expect(!shouldSkipPath("src/main.zig"));
    try std.testing.expect(!shouldSkipPath(".gitignore"));
    try std.testing.expect(!shouldSkipPath("foo/.gitignore"));
}
