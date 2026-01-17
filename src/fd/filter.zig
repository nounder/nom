//! File filtering for fd-zig.
//!
//! Provides filters for:
//! - File type (file, directory, symlink, executable, empty)
//! - File extension
//! - File size (min, max, exact)
//! - Modification time (newer than, older than)

const std = @import("std");
const builtin = @import("builtin");

/// File type filter flags.
pub const FileType = packed struct {
    file: bool = false,
    directory: bool = false,
    symlink: bool = false,
    executable: bool = false,
    empty: bool = false,
    socket: bool = false,
    pipe: bool = false,
    block_device: bool = false,
    char_device: bool = false,

    pub fn any(self: FileType) bool {
        return self.file or self.directory or self.symlink or
            self.executable or self.empty or self.socket or
            self.pipe or self.block_device or self.char_device;
    }

    /// Parse type character (fd-compatible): f, d, l, x, e, s, p, b, c
    pub fn fromChar(c: u8) ?FileType {
        return switch (c) {
            'f' => .{ .file = true },
            'd' => .{ .directory = true },
            'l' => .{ .symlink = true },
            'x' => .{ .executable = true },
            'e' => .{ .empty = true },
            's' => .{ .socket = true },
            'p' => .{ .pipe = true },
            'b' => .{ .block_device = true },
            'c' => .{ .char_device = true },
            else => null,
        };
    }

    /// Merge two FileType filters (OR semantics).
    pub fn merge(self: FileType, other: FileType) FileType {
        return .{
            .file = self.file or other.file,
            .directory = self.directory or other.directory,
            .symlink = self.symlink or other.symlink,
            .executable = self.executable or other.executable,
            .empty = self.empty or other.empty,
            .socket = self.socket or other.socket,
            .pipe = self.pipe or other.pipe,
            .block_device = self.block_device or other.block_device,
            .char_device = self.char_device or other.char_device,
        };
    }
};

/// Size filter with comparison mode.
pub const SizeFilter = struct {
    pub const Mode = enum {
        min, // >= bytes
        max, // <= bytes
        exact, // == bytes
    };

    bytes: u64,
    mode: Mode,

    /// Parse size spec like "+1k", "-10m", "100b"
    /// Units: b (bytes), k/kb (1000), m/mb, g/gb, t/tb
    ///        ki/kib (1024), mi/mib, gi/gib, ti/tib
    pub fn parse(spec: []const u8) !SizeFilter {
        if (spec.len == 0) return error.InvalidSizeSpec;

        var s = spec;
        var mode: Mode = .exact;

        // Check prefix
        if (s[0] == '+') {
            mode = .min;
            s = s[1..];
        } else if (s[0] == '-') {
            mode = .max;
            s = s[1..];
        }

        if (s.len == 0) return error.InvalidSizeSpec;

        // Find where digits end
        var num_end: usize = 0;
        while (num_end < s.len and (s[num_end] >= '0' and s[num_end] <= '9')) {
            num_end += 1;
        }

        if (num_end == 0) return error.InvalidSizeSpec;

        const num = std.fmt.parseInt(u64, s[0..num_end], 10) catch return error.InvalidSizeSpec;
        const unit = s[num_end..];

        const multiplier: u64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "b"))
            1
        else if (std.ascii.eqlIgnoreCase(unit, "k") or std.ascii.eqlIgnoreCase(unit, "kb"))
            1000
        else if (std.ascii.eqlIgnoreCase(unit, "ki") or std.ascii.eqlIgnoreCase(unit, "kib"))
            1024
        else if (std.ascii.eqlIgnoreCase(unit, "m") or std.ascii.eqlIgnoreCase(unit, "mb"))
            1000 * 1000
        else if (std.ascii.eqlIgnoreCase(unit, "mi") or std.ascii.eqlIgnoreCase(unit, "mib"))
            1024 * 1024
        else if (std.ascii.eqlIgnoreCase(unit, "g") or std.ascii.eqlIgnoreCase(unit, "gb"))
            1000 * 1000 * 1000
        else if (std.ascii.eqlIgnoreCase(unit, "gi") or std.ascii.eqlIgnoreCase(unit, "gib"))
            1024 * 1024 * 1024
        else if (std.ascii.eqlIgnoreCase(unit, "t") or std.ascii.eqlIgnoreCase(unit, "tb"))
            1000 * 1000 * 1000 * 1000
        else if (std.ascii.eqlIgnoreCase(unit, "ti") or std.ascii.eqlIgnoreCase(unit, "tib"))
            1024 * 1024 * 1024 * 1024
        else
            return error.InvalidSizeUnit;

        return .{
            .bytes = num * multiplier,
            .mode = mode,
        };
    }

    pub fn matches(self: SizeFilter, size: u64) bool {
        return switch (self.mode) {
            .min => size >= self.bytes,
            .max => size <= self.bytes,
            .exact => size == self.bytes,
        };
    }
};

/// Time filter for modification time.
pub const TimeFilter = struct {
    pub const Mode = enum {
        newer, // modified after timestamp
        older, // modified before timestamp
    };

    /// Unix timestamp in seconds
    timestamp: i64,
    mode: Mode,

    /// Parse duration string like "1d", "2h", "30min", "1week"
    /// Returns a TimeFilter relative to now.
    pub fn parseDuration(spec: []const u8, mode: Mode) !TimeFilter {
        const now = std.time.timestamp();
        const seconds = try parseDurationSeconds(spec);
        return .{
            .timestamp = now - seconds,
            .mode = mode,
        };
    }

    /// Create from absolute timestamp.
    pub fn fromTimestamp(ts: i64, mode: Mode) TimeFilter {
        return .{
            .timestamp = ts,
            .mode = mode,
        };
    }

    pub fn matches(self: TimeFilter, mtime: i64) bool {
        return switch (self.mode) {
            .newer => mtime >= self.timestamp,
            .older => mtime < self.timestamp,
        };
    }
};

fn parseDurationSeconds(spec: []const u8) !i64 {
    if (spec.len == 0) return error.InvalidDuration;

    // Find where digits end
    var num_end: usize = 0;
    while (num_end < spec.len and (spec[num_end] >= '0' and spec[num_end] <= '9')) {
        num_end += 1;
    }

    if (num_end == 0) return error.InvalidDuration;

    const num = std.fmt.parseInt(i64, spec[0..num_end], 10) catch return error.InvalidDuration;
    const unit = spec[num_end..];

    const multiplier: i64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "s") or std.ascii.eqlIgnoreCase(unit, "sec") or std.ascii.eqlIgnoreCase(unit, "second") or std.ascii.eqlIgnoreCase(unit, "seconds"))
        1
    else if (std.ascii.eqlIgnoreCase(unit, "m") or std.ascii.eqlIgnoreCase(unit, "min") or std.ascii.eqlIgnoreCase(unit, "minute") or std.ascii.eqlIgnoreCase(unit, "minutes"))
        60
    else if (std.ascii.eqlIgnoreCase(unit, "h") or std.ascii.eqlIgnoreCase(unit, "hour") or std.ascii.eqlIgnoreCase(unit, "hours"))
        60 * 60
    else if (std.ascii.eqlIgnoreCase(unit, "d") or std.ascii.eqlIgnoreCase(unit, "day") or std.ascii.eqlIgnoreCase(unit, "days"))
        60 * 60 * 24
    else if (std.ascii.eqlIgnoreCase(unit, "w") or std.ascii.eqlIgnoreCase(unit, "week") or std.ascii.eqlIgnoreCase(unit, "weeks"))
        60 * 60 * 24 * 7
    else if (std.ascii.eqlIgnoreCase(unit, "M") or std.ascii.eqlIgnoreCase(unit, "month") or std.ascii.eqlIgnoreCase(unit, "months"))
        60 * 60 * 24 * 30
    else if (std.ascii.eqlIgnoreCase(unit, "y") or std.ascii.eqlIgnoreCase(unit, "year") or std.ascii.eqlIgnoreCase(unit, "years"))
        60 * 60 * 24 * 365
    else
        return error.InvalidDurationUnit;

    return num * multiplier;
}

/// Combined filter that checks all constraints.
pub const Filter = struct {
    file_types: ?FileType = null,
    extensions: []const []const u8 = &.{},
    size_filters: []const SizeFilter = &.{},
    time_filters: []const TimeFilter = &.{},
    min_depth: ?usize = null,
    max_depth: ?usize = null,

    /// Check if an entry matches all filter criteria.
    pub fn matches(self: Filter, entry: anytype) !bool {
        // Depth check
        if (self.min_depth) |min| {
            if (entry.depth < min) return false;
        }
        if (self.max_depth) |max| {
            if (entry.depth > max) return false;
        }

        // File type check
        if (self.file_types) |ft| {
            if (!matchesFileType(ft, entry)) return false;
        }

        // Extension check
        if (self.extensions.len > 0) {
            if (!matchesExtension(self.extensions, entry.name)) return false;
        }

        // Size and time checks require metadata
        if (self.size_filters.len > 0 or self.time_filters.len > 0) {
            const stat = entry.stat() catch return false;

            // Size check (only applies to files, fd excludes directories)
            if (self.size_filters.len > 0 and entry.kind == .file) {
                for (self.size_filters) |sf| {
                    if (!sf.matches(stat.size)) return false;
                }
            } else if (self.size_filters.len > 0 and entry.kind != .file) {
                // Non-files don't match size filters (fd behavior)
                return false;
            }

            // Time check
            for (self.time_filters) |tf| {
                const mtime_sec: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
                if (!tf.matches(mtime_sec)) return false;
            }
        }

        return true;
    }
};

fn matchesFileType(ft: FileType, entry: anytype) bool {
    const kind = entry.kind;

    // Check basic types
    if (ft.file and kind == .file) return true;
    if (ft.directory and kind == .directory) return true;
    if (ft.symlink and kind == .sym_link) return true;

    // Platform-specific types
    if (builtin.os.tag != .windows) {
        if (ft.socket and kind == .unix_domain_socket) return true;
        if (ft.pipe and kind == .named_pipe) return true;
        if (ft.block_device and kind == .block_device) return true;
        if (ft.char_device and kind == .character_device) return true;
    }

    // Executable check (requires stat)
    if (ft.executable and kind == .file) {
        if (builtin.os.tag != .windows) {
            const stat = entry.stat() catch return false;
            // Check if any execute bit is set
            if (stat.mode & 0o111 != 0) return true;
        }
    }

    // Empty check
    if (ft.empty) {
        if (kind == .directory) {
            // Check if directory is empty
            return entry.isEmpty() catch false;
        } else if (kind == .file) {
            const stat = entry.stat() catch return false;
            return stat.size == 0;
        }
    }

    return false;
}

fn matchesExtension(extensions: []const []const u8, name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len == 0) return false;

    // Skip the leading dot
    const ext_no_dot = if (ext[0] == '.') ext[1..] else ext;

    for (extensions) |allowed| {
        if (std.ascii.eqlIgnoreCase(ext_no_dot, allowed)) return true;
    }
    return false;
}

// Tests

test "SizeFilter.parse" {
    // Basic bytes
    const s1 = try SizeFilter.parse("100");
    try std.testing.expectEqual(@as(u64, 100), s1.bytes);
    try std.testing.expectEqual(SizeFilter.Mode.exact, s1.mode);

    // With prefix
    const s2 = try SizeFilter.parse("+1k");
    try std.testing.expectEqual(@as(u64, 1000), s2.bytes);
    try std.testing.expectEqual(SizeFilter.Mode.min, s2.mode);

    const s3 = try SizeFilter.parse("-10m");
    try std.testing.expectEqual(@as(u64, 10_000_000), s3.bytes);
    try std.testing.expectEqual(SizeFilter.Mode.max, s3.mode);

    // Binary units
    const s4 = try SizeFilter.parse("1ki");
    try std.testing.expectEqual(@as(u64, 1024), s4.bytes);

    const s5 = try SizeFilter.parse("1mib");
    try std.testing.expectEqual(@as(u64, 1024 * 1024), s5.bytes);
}

test "SizeFilter.matches" {
    const min = SizeFilter{ .bytes = 100, .mode = .min };
    try std.testing.expect(min.matches(100));
    try std.testing.expect(min.matches(200));
    try std.testing.expect(!min.matches(50));

    const max = SizeFilter{ .bytes = 100, .mode = .max };
    try std.testing.expect(max.matches(100));
    try std.testing.expect(max.matches(50));
    try std.testing.expect(!max.matches(200));

    const exact = SizeFilter{ .bytes = 100, .mode = .exact };
    try std.testing.expect(exact.matches(100));
    try std.testing.expect(!exact.matches(99));
    try std.testing.expect(!exact.matches(101));
}

test "FileType.fromChar" {
    const f = FileType.fromChar('f').?;
    try std.testing.expect(f.file);
    try std.testing.expect(!f.directory);

    const d = FileType.fromChar('d').?;
    try std.testing.expect(d.directory);
    try std.testing.expect(!d.file);

    try std.testing.expect(FileType.fromChar('z') == null);
}

test "FileType.merge" {
    const f = FileType{ .file = true };
    const d = FileType{ .directory = true };
    const merged = f.merge(d);
    try std.testing.expect(merged.file);
    try std.testing.expect(merged.directory);
}

test "matchesExtension" {
    const exts = &[_][]const u8{ "zig", "rs", "go" };
    try std.testing.expect(matchesExtension(exts, "main.zig"));
    try std.testing.expect(matchesExtension(exts, "main.ZIG")); // case insensitive
    try std.testing.expect(matchesExtension(exts, "lib.rs"));
    try std.testing.expect(!matchesExtension(exts, "main.c"));
    try std.testing.expect(!matchesExtension(exts, "README"));
}
