//! fd-zig: A fast file finder library inspired by fd.
//!
//! This module provides fd-like functionality for finding files:
//! - Pattern matching (glob, fixed string)
//! - File type filtering (file, directory, symlink, executable, empty)
//! - Size and time constraints
//! - Respects .gitignore
//! - Output formatting with templates
//!
//! ## Example Usage
//!
//! ```zig
//! const fd = @import("fd/fd.zig");
//!
//! // Simple search
//! var finder = try fd.Finder.init(allocator, .{
//!     .pattern = "*.zig",
//!     .pattern_kind = .glob,
//! });
//! defer finder.deinit();
//!
//! while (try finder.next()) |entry| {
//!     std.debug.print("{s}\n", .{entry.path});
//! }
//! ```

const std = @import("std");
pub const pattern = @import("pattern.zig");
pub const filter = @import("filter.zig");
pub const walker = @import("walker.zig");
pub const ignore = @import("ignore.zig");
pub const output = @import("output.zig");

// Re-exports for convenience
pub const Pattern = pattern.Pattern;
pub const PatternKind = pattern.PatternKind;
pub const PatternOptions = pattern.PatternOptions;
pub const Filter = filter.Filter;
pub const FileType = filter.FileType;
pub const SizeFilter = filter.SizeFilter;
pub const TimeFilter = filter.TimeFilter;
pub const Walker = walker.Walker;
pub const WalkOptions = walker.WalkOptions;
pub const Entry = walker.Entry;
pub const IgnoreStack = ignore.IgnoreStack;
pub const Gitignore = ignore.Gitignore;
pub const OutputFormat = output.OutputFormat;
pub const ColorMode = output.ColorMode;
pub const FormatTemplate = output.FormatTemplate;

/// Configuration for the Finder.
pub const FinderOptions = struct {
    // Pattern matching
    search_pattern: ?[]const u8 = null,
    pattern_kind: PatternKind = .glob,
    case_sensitive: ?bool = null, // null = smart case (sensitive if has uppercase)
    full_path: bool = false,

    // File filtering
    file_types: ?FileType = null,
    extensions: []const []const u8 = &.{},
    size_filters: []const SizeFilter = &.{},
    time_filters: []const TimeFilter = &.{},
    min_depth: ?usize = null,
    max_depth: ?usize = null,

    // Directory walking
    ignore_hidden: bool = true,
    read_gitignore: bool = true,
    require_git: bool = true,
    follow_symlinks: bool = false,
    one_file_system: bool = false,
    exclude_patterns: []const []const u8 = &.{},

    // Result limiting
    max_results: ?usize = null,
};

/// A file finder with fd-like semantics.
/// Combines pattern matching, filtering, and directory walking into a single interface.
pub const Finder = struct {
    allocator: std.mem.Allocator,
    options: FinderOptions,
    compiled_pattern: ?Pattern,
    file_filter: Filter,
    inner_walker: Walker,
    result_count: usize,
    started: bool,

    pub fn init(allocator: std.mem.Allocator, options: FinderOptions) !Finder {
        // Compile pattern if provided
        var compiled: ?Pattern = null;
        if (options.search_pattern) |pat| {
            const case_sensitive = options.case_sensitive orelse !hasUppercase(pat);
            compiled = try Pattern.init(allocator, pat, options.pattern_kind, .{
                .case_sensitive = case_sensitive,
                .full_path = options.full_path,
            });
        }
        errdefer if (compiled) |*p| p.deinit(allocator);

        // Build filter
        const file_filter = Filter{
            .file_types = options.file_types,
            .extensions = options.extensions,
            .size_filters = options.size_filters,
            .time_filters = options.time_filters,
            .min_depth = options.min_depth,
            .max_depth = options.max_depth,
        };

        // Build walker
        const walk_opts = WalkOptions{
            .ignore_hidden = options.ignore_hidden,
            .read_gitignore = options.read_gitignore,
            .require_git = options.require_git,
            .follow_symlinks = options.follow_symlinks,
            .one_file_system = options.one_file_system,
            .max_depth = options.max_depth,
            .min_depth = options.min_depth,
            .exclude_patterns = options.exclude_patterns,
        };

        return .{
            .allocator = allocator,
            .options = options,
            .compiled_pattern = compiled,
            .file_filter = file_filter,
            .inner_walker = Walker.init(allocator, ".", walk_opts),
            .result_count = 0,
            .started = false,
        };
    }

    pub fn deinit(self: *Finder) void {
        if (self.compiled_pattern) |*p| p.deinit(self.allocator);
        self.inner_walker.deinit();
    }

    /// Start the finder from the current working directory.
    pub fn start(self: *Finder) !void {
        try self.startAt(std.fs.cwd());
    }

    /// Start the finder from a specific directory.
    pub fn startAt(self: *Finder, dir: std.fs.Dir) !void {
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        try self.inner_walker.startAt(dir, ".");
    }

    /// Get the next matching entry.
    pub fn next(self: *Finder) !?Entry {
        // Check max results
        if (self.options.max_results) |max| {
            if (self.result_count >= max) return null;
        }

        while (try self.inner_walker.next()) |entry| {
            // Apply pattern matching
            if (self.compiled_pattern) |*p| {
                const match_text = if (self.options.full_path) entry.path else entry.name;
                if (!p.matches(match_text)) continue;
            }

            // Apply filters
            var mutable_entry = entry;
            if (!try self.file_filter.matches(&mutable_entry)) continue;

            self.result_count += 1;
            return entry;
        }

        return null;
    }

    /// Collect all matching entries into a slice.
    pub fn collect(self: *Finder, allocator: std.mem.Allocator) ![]Entry {
        var results: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer results.deinit(allocator);

        while (try self.next()) |entry| {
            try results.append(allocator, entry);
        }

        return results.toOwnedSlice(allocator);
    }
};

/// Check if a string contains uppercase ASCII characters.
/// Used for smart case detection.
pub fn hasUppercase(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

/// Helper to create a finder and iterate in one go.
/// Useful for simple one-off searches.
pub fn find(
    allocator: std.mem.Allocator,
    options: FinderOptions,
    callback: fn (Entry) anyerror!bool, // Return false to stop
) !usize {
    var finder = try Finder.init(allocator, options);
    defer finder.deinit();
    try finder.start();

    var count: usize = 0;
    while (try finder.next()) |entry| {
        count += 1;
        if (!try callback(entry)) break;
    }
    return count;
}

// Tests

test "hasUppercase" {
    try std.testing.expect(!hasUppercase("foo"));
    try std.testing.expect(!hasUppercase("foo123"));
    try std.testing.expect(!hasUppercase("foo_bar"));
    try std.testing.expect(hasUppercase("Foo"));
    try std.testing.expect(hasUppercase("FOO"));
    try std.testing.expect(hasUppercase("fooBar"));
    try std.testing.expect(hasUppercase("foo.Zig"));
}

test "Finder init" {
    const allocator = std.testing.allocator;

    var finder = try Finder.init(allocator, .{
        .search_pattern = "*.zig",
        .pattern_kind = .glob,
    });
    defer finder.deinit();

    try std.testing.expect(finder.compiled_pattern != null);
}

test "Finder with file types" {
    const allocator = std.testing.allocator;

    var finder = try Finder.init(allocator, .{
        .file_types = .{ .file = true },
        .extensions = &[_][]const u8{"zig"},
    });
    defer finder.deinit();

    try std.testing.expect(finder.options.file_types.?.file);
}
