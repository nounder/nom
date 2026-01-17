//! Output formatting for fd-zig.
//!
//! Provides:
//! - Colorized output (using LS_COLORS)
//! - Custom format templates ({}, {/}, {//}, {.}, {/.})
//! - Null-separated output
//! - Absolute/relative path handling

const std = @import("std");
const builtin = @import("builtin");

pub const ColorMode = enum {
    auto,
    always,
    never,
};

/// Output format configuration.
pub const OutputFormat = struct {
    color: ColorMode = .auto,
    null_separator: bool = false,
    absolute_path: bool = false,
    template: ?FormatTemplate = null,

    /// Format and write an entry to the writer.
    pub fn format(self: OutputFormat, entry: anytype, writer: anytype) !void {
        const path = entry.path;

        if (self.template) |tmpl| {
            try tmpl.apply(path, writer);
        } else if (self.absolute_path) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs = try std.fs.cwd().realpath(path, &buf);
            try writer.writeAll(abs);
        } else {
            try writer.writeAll(path);
        }

        if (self.null_separator) {
            try writer.writeByte(0);
        } else {
            try writer.writeByte('\n');
        }
    }
};

/// Parsed format template with tokens.
pub const FormatTemplate = struct {
    pub const Token = union(enum) {
        literal: []const u8,
        full_path, // {}
        basename, // {/}
        parent, // {//}
        no_extension, // {.}
        basename_no_ext, // {/.}
    };

    tokens: []const Token,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, template: []const u8) !FormatTemplate {
        var tokens: std.ArrayListUnmanaged(Token) = .empty;
        errdefer tokens.deinit(allocator);

        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < template.len) {
            if (template[i] == '{') {
                // Flush literal
                if (i > literal_start) {
                    try tokens.append(allocator, .{ .literal = template[literal_start..i] });
                }

                // Check for escaped brace
                if (i + 1 < template.len and template[i + 1] == '{') {
                    try tokens.append(allocator, .{ .literal = "{" });
                    i += 2;
                    literal_start = i;
                    continue;
                }

                // Find closing brace
                const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse
                    return error.UnmatchedBrace;

                const placeholder = template[i + 1 .. close];

                if (placeholder.len == 0) {
                    try tokens.append(allocator, .full_path);
                } else if (std.mem.eql(u8, placeholder, "/")) {
                    try tokens.append(allocator, .basename);
                } else if (std.mem.eql(u8, placeholder, "//")) {
                    try tokens.append(allocator, .parent);
                } else if (std.mem.eql(u8, placeholder, ".")) {
                    try tokens.append(allocator, .no_extension);
                } else if (std.mem.eql(u8, placeholder, "/.")) {
                    try tokens.append(allocator, .basename_no_ext);
                } else {
                    return error.InvalidPlaceholder;
                }

                i = close + 1;
                literal_start = i;
            } else if (template[i] == '}') {
                if (i + 1 < template.len and template[i + 1] == '}') {
                    // Flush literal including first }
                    if (i > literal_start) {
                        try tokens.append(allocator, .{ .literal = template[literal_start..i] });
                    }
                    try tokens.append(allocator, .{ .literal = "}" });
                    i += 2;
                    literal_start = i;
                } else {
                    return error.UnmatchedBrace;
                }
            } else {
                i += 1;
            }
        }

        // Flush remaining literal
        if (literal_start < template.len) {
            try tokens.append(allocator, .{ .literal = template[literal_start..] });
        }

        return .{
            .tokens = try tokens.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FormatTemplate) void {
        self.allocator.free(self.tokens);
    }

    pub fn apply(self: FormatTemplate, path: []const u8, writer: anytype) !void {
        for (self.tokens) |token| {
            switch (token) {
                .literal => |lit| try writer.writeAll(lit),
                .full_path => try writer.writeAll(path),
                .basename => try writer.writeAll(std.fs.path.basename(path)),
                .parent => {
                    if (std.fs.path.dirname(path)) |dir| {
                        try writer.writeAll(dir);
                    }
                },
                .no_extension => {
                    const ext = std.fs.path.extension(path);
                    if (ext.len > 0 and path.len > ext.len) {
                        try writer.writeAll(path[0 .. path.len - ext.len]);
                    } else {
                        try writer.writeAll(path);
                    }
                },
                .basename_no_ext => {
                    const base = std.fs.path.basename(path);
                    const ext = std.fs.path.extension(base);
                    if (ext.len > 0 and base.len > ext.len) {
                        try writer.writeAll(base[0 .. base.len - ext.len]);
                    } else {
                        try writer.writeAll(base);
                    }
                },
            }
        }
    }
};

// Tests

test "FormatTemplate.parse basic" {
    const allocator = std.testing.allocator;

    var t = try FormatTemplate.parse(allocator, "prefix {} suffix");
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 3), t.tokens.len);
    try std.testing.expectEqualStrings("prefix ", t.tokens[0].literal);
    try std.testing.expectEqual(FormatTemplate.Token.full_path, t.tokens[1]);
    try std.testing.expectEqualStrings(" suffix", t.tokens[2].literal);
}

test "FormatTemplate.parse all placeholders" {
    const allocator = std.testing.allocator;

    var t = try FormatTemplate.parse(allocator, "{} {/} {//} {.} {/.}");
    defer t.deinit();

    try std.testing.expectEqual(FormatTemplate.Token.full_path, t.tokens[0]);
    try std.testing.expectEqual(FormatTemplate.Token.basename, t.tokens[2]);
    try std.testing.expectEqual(FormatTemplate.Token.parent, t.tokens[4]);
    try std.testing.expectEqual(FormatTemplate.Token.no_extension, t.tokens[6]);
    try std.testing.expectEqual(FormatTemplate.Token.basename_no_ext, t.tokens[8]);
}

test "FormatTemplate.apply" {
    const allocator = std.testing.allocator;

    var t = try FormatTemplate.parse(allocator, "mv {} {//}/backup/{/.}.bak");
    defer t.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try t.apply("src/main.zig", fbs.writer());

    try std.testing.expectEqualStrings("mv src/main.zig src/backup/main.bak", fbs.getWritten());
}

test "FormatTemplate escaped braces" {
    const allocator = std.testing.allocator;

    var t = try FormatTemplate.parse(allocator, "{{}} is {}");
    defer t.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try t.apply("test.txt", fbs.writer());

    try std.testing.expectEqualStrings("{} is test.txt", fbs.getWritten());
}

test "OutputFormat basic" {
    const fmt = OutputFormat{};

    const Entry = struct {
        path: []const u8,
    };
    const entry = Entry{ .path = "src/main.zig" };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try fmt.format(entry, fbs.writer());

    try std.testing.expectEqualStrings("src/main.zig\n", fbs.getWritten());
}

test "OutputFormat null separator" {
    const fmt = OutputFormat{ .null_separator = true };

    const Entry = struct {
        path: []const u8,
    };
    const entry = Entry{ .path = "test.txt" };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try fmt.format(entry, fbs.writer());

    try std.testing.expectEqualStrings("test.txt\x00", fbs.getWritten());
}
