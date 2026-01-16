//! fzf-compatible argument parsing and utilities.
//!
//! This module provides a comptime-generated argument parser that supports
//! fzf's CLI conventions including:
//! - Short flags: `-x`, `-e`, `-i`
//! - Toggle variants: `+x`, `+i` (disable flags)
//! - Combined short options: `-qfoo` (value without space)
//! - Long options: `--query=value` or `--query value`

const std = @import("std");
const nom = @import("root.zig");

const CaseMatching = nom.CaseMatching;
const Normalization = nom.Normalization;

/// CLI arguments compatible with fzf
pub const Args = struct {
    // Search mode
    extended: bool = true,
    exact: bool = false,
    case_sensitive: bool = false,
    smart_case: bool = true,

    // Interface
    multi: bool = false,
    no_mouse: bool = false,
    reverse: bool = false,
    height: ?[]const u8 = null,
    min_height: usize = 10,
    layout: Layout = .default,

    // Layout
    prompt: []const u8 = "> ",
    pointer: []const u8 = ">",
    marker: []const u8 = ">",
    header: ?[]const u8 = null,
    header_lines: usize = 0,

    // Display
    ansi: bool = true,
    tabstop: usize = 8,
    no_bold: bool = false,

    // History
    history: ?[]const u8 = null,
    history_size: usize = 1000,

    // Preview
    preview: ?[]const u8 = null,
    preview_window: ?[]const u8 = null,

    // Scripting
    query: ?[]const u8 = null,
    select_1: bool = false,
    exit_0: bool = false,
    filter: ?[]const u8 = null,
    print_query: bool = false,
    expect: ?[]const u8 = null,
    read0: bool = false,
    print0: bool = false,

    // Other
    sync: bool = false,
    version: bool = false,
    help: bool = false,

    // Internal
    delimiter: u8 = '\n',
    nth: ?[]const u8 = null,
    with_nth: ?[]const u8 = null,

    pub const Layout = enum {
        default,
        reverse_layout,
        reverse_list,
    };

    /// Argument metadata for comptime parsing
    const Opt = struct {
        short: ?[]const u8 = null,
        long: ?[]const u8 = null,
        neg_short: ?[]const u8 = null,
        neg_long: ?[]const u8 = null,
        takes_value: bool = false,
        default_int: ?usize = null,
    };

    /// Metadata for all arguments - drives the comptime parser generation
    const meta = .{
        .help = .{ .short = "-h", .long = "--help" },
        .version = .{ .long = "--version" },
        .extended = .{ .short = "-x", .long = "--extended", .neg_short = "+x", .neg_long = "--no-extended" },
        .exact = .{ .short = "-e", .long = "--exact", .neg_short = "+e", .neg_long = "--no-exact" },
        .case_sensitive = .{ .short = "+i" }, // +i enables, -i handled specially for smart_case
        .multi = .{ .short = "-m", .long = "--multi", .neg_short = "+m", .neg_long = "--no-multi" },
        .no_mouse = .{ .long = "--no-mouse" },
        .reverse = .{ .long = "--reverse", .neg_long = "--no-reverse" },
        .ansi = .{ .long = "--ansi", .neg_long = "--no-ansi" },
        .read0 = .{ .short = "-0", .long = "--read0" },
        .print0 = .{ .long = "--print0" },
        .select_1 = .{ .short = "-1", .long = "--select-1" },
        .exit_0 = .{ .long = "--exit-0" },
        .print_query = .{ .long = "--print-query" },
        .sync = .{ .long = "--sync" },
        .query = .{ .short = "-q", .long = "--query", .takes_value = true },
        .filter = .{ .short = "-f", .long = "--filter", .takes_value = true },
        .prompt = .{ .long = "--prompt", .takes_value = true },
        .pointer = .{ .long = "--pointer", .takes_value = true },
        .marker = .{ .long = "--marker", .takes_value = true },
        .header = .{ .long = "--header", .takes_value = true },
        .header_lines = .{ .long = "--header-lines", .takes_value = true, .default_int = 0 },
        .height = .{ .long = "--height", .takes_value = true },
        .min_height = .{ .long = "--min-height", .takes_value = true, .default_int = 10 },
        .layout = .{ .long = "--layout", .takes_value = true },
        .preview = .{ .long = "--preview", .takes_value = true },
        .preview_window = .{ .long = "--preview-window", .takes_value = true },
        .tabstop = .{ .long = "--tabstop", .takes_value = true, .default_int = 8 },
        .expect = .{ .long = "--expect", .takes_value = true },
        .history = .{ .long = "--history", .takes_value = true },
        .history_size = .{ .long = "--history-size", .takes_value = true, .default_int = 1000 },
        .nth = .{ .short = "-n", .long = "--nth", .takes_value = true },
        .with_nth = .{ .long = "--with-nth", .takes_value = true },
    };

    /// Parse result containing args and argv (which must stay alive while args is in use)
    pub const ParseResult = struct {
        args: Args,
        argv: [][:0]u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ParseResult) void {
            std.process.argsFree(self.allocator, self.argv);
        }
    };

    /// Parse command line arguments
    pub fn parse(allocator: std.mem.Allocator) !ParseResult {
        var args = Args{};
        const argv = try std.process.argsAlloc(allocator);
        errdefer std.process.argsFree(allocator, argv);

        var i: usize = 1; // Skip program name
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];

            // Special case: -i sets case_sensitive=false, smart_case=false
            if (std.mem.eql(u8, arg, "-i")) {
                args.case_sensitive = false;
                args.smart_case = false;
                continue;
            }

            // Special case: read0 also sets delimiter
            if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--read0")) {
                args.read0 = true;
                args.delimiter = 0;
                continue;
            }

            if (try parseArg(&args, arg, argv, &i)) continue;

            // Unknown args are ignored for fzf compatibility
        }

        return .{ .args = args, .argv = argv, .allocator = allocator };
    }

    /// Parse a single argument, returns true if handled
    fn parseArg(args: *Args, arg: []const u8, argv: [][:0]u8, i: *usize) !bool {
        inline for (@typeInfo(@TypeOf(meta)).@"struct".fields) |field| {
            const opt = @field(meta, field.name);

            // Handle boolean flags
            if (@TypeOf(@field(args.*, field.name)) == bool) {
                // Positive flag
                if (@hasField(@TypeOf(opt), "short")) {
                    if (std.mem.eql(u8, arg, opt.short)) {
                        @field(args.*, field.name) = true;
                        return true;
                    }
                }
                if (@hasField(@TypeOf(opt), "long")) {
                    if (std.mem.eql(u8, arg, opt.long)) {
                        @field(args.*, field.name) = true;
                        return true;
                    }
                }
                // Negative flag
                if (@hasField(@TypeOf(opt), "neg_short")) {
                    if (std.mem.eql(u8, arg, opt.neg_short)) {
                        @field(args.*, field.name) = false;
                        return true;
                    }
                }
                if (@hasField(@TypeOf(opt), "neg_long")) {
                    if (std.mem.eql(u8, arg, opt.neg_long)) {
                        @field(args.*, field.name) = false;
                        return true;
                    }
                }
            }

            // Handle value options
            if (@hasField(@TypeOf(opt), "takes_value") and opt.takes_value) {
                if (try parseValueOpt(args, field.name, opt, arg, argv, i)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Parse an option that takes a value
    fn parseValueOpt(
        args: *Args,
        comptime field_name: []const u8,
        comptime opt: anytype,
        arg: []const u8,
        argv: [][:0]u8,
        i: *usize,
    ) !bool {
        const FieldType = @TypeOf(@field(args.*, field_name));
        const default_int: ?usize = if (@hasField(@TypeOf(opt), "default_int")) opt.default_int else null;

        // Try short option: -qvalue or -q value
        if (@hasField(@TypeOf(opt), "short")) {
            const short = opt.short;
            if (std.mem.startsWith(u8, arg, short)) {
                if (arg.len > short.len) {
                    // -qvalue form
                    const value = arg[short.len..];
                    setField(args, field_name, FieldType, value, default_int);
                    return true;
                } else if (i.* + 1 < argv.len) {
                    // -q value form
                    i.* += 1;
                    setField(args, field_name, FieldType, argv[i.*], default_int);
                    return true;
                }
            }
        }

        // Try long option: --query=value or --query value
        if (@hasField(@TypeOf(opt), "long")) {
            const long = opt.long;
            const long_eq = long ++ "=";
            if (std.mem.startsWith(u8, arg, long_eq)) {
                // --query=value form
                const value = arg[long_eq.len..];
                setField(args, field_name, FieldType, value, default_int);
                return true;
            } else if (std.mem.eql(u8, arg, long)) {
                // --query value form
                if (i.* + 1 < argv.len) {
                    i.* += 1;
                    setField(args, field_name, FieldType, argv[i.*], default_int);
                    return true;
                }
            }
        }

        return false;
    }

    /// Set a field value with appropriate type conversion
    fn setField(
        args: *Args,
        comptime field_name: []const u8,
        comptime FieldType: type,
        value: []const u8,
        comptime default_int: ?usize,
    ) void {
        if (FieldType == ?[]const u8) {
            @field(args.*, field_name) = value;
        } else if (FieldType == []const u8) {
            @field(args.*, field_name) = value;
        } else if (FieldType == usize) {
            @field(args.*, field_name) = std.fmt.parseInt(usize, value, 10) catch (default_int orelse 0);
        } else if (FieldType == Layout) {
            if (std.mem.eql(u8, value, "reverse")) {
                args.layout = .reverse_layout;
            } else if (std.mem.eql(u8, value, "reverse-list")) {
                args.layout = .reverse_list;
            } else {
                args.layout = .default;
            }
        }
    }
};

/// Field range for --nth option
pub const FieldRange = struct {
    start: ?i32 = null, // null means beginning
    end: ?i32 = null, // null means end, negative counts from end

    /// Parse a single field range like "1", "2..", "..3", "1..3", "-1"
    pub fn parse(s: []const u8) ?FieldRange {
        if (s.len == 0) return null;

        // Check for range
        if (std.mem.indexOf(u8, s, "..")) |dotdot| {
            const start_str = s[0..dotdot];
            const end_str = s[dotdot + 2 ..];

            var range = FieldRange{};
            if (start_str.len > 0) {
                range.start = std.fmt.parseInt(i32, start_str, 10) catch return null;
            }
            if (end_str.len > 0) {
                range.end = std.fmt.parseInt(i32, end_str, 10) catch return null;
            }
            return range;
        }

        // Single field
        const n = std.fmt.parseInt(i32, s, 10) catch return null;
        return FieldRange{ .start = n, .end = n };
    }

    /// Check if field index matches this range (1-based, negative counts from end)
    pub fn matches(self: FieldRange, idx: usize, total: usize) bool {
        const i: i32 = @intCast(idx + 1); // Convert to 1-based
        const t: i32 = @intCast(total);

        // Resolve negative indices
        const start = if (self.start) |s| (if (s < 0) t + s + 1 else s) else 1;
        const end = if (self.end) |e| (if (e < 0) t + e + 1 else e) else t;

        return i >= start and i <= end;
    }
};

/// Extract fields from a line based on --nth specification
pub fn extractNthFields(allocator: std.mem.Allocator, line: []const u8, nth: []const u8, delimiter: u8) ![]const u8 {
    // Split line into fields
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fields.deinit(allocator);

    _ = delimiter; // TODO: use custom delimiter when specified

    // Split by delimiter (simplified: just split by space/tab for now like fzf default)
    var start: usize = 0;
    var in_field = false;
    for (line, 0..) |c, i| {
        const is_delim = (c == ' ' or c == '\t');
        if (!in_field and !is_delim) {
            start = i;
            in_field = true;
        } else if (in_field and is_delim) {
            try fields.append(allocator, line[start..i]);
            in_field = false;
        }
    }
    if (in_field) {
        try fields.append(allocator, line[start..]);
    }

    if (fields.items.len == 0) {
        return line;
    }

    // Parse nth ranges
    var ranges: std.ArrayListUnmanaged(FieldRange) = .empty;
    defer ranges.deinit(allocator);

    var nth_it = std.mem.splitScalar(u8, nth, ',');
    while (nth_it.next()) |range_str| {
        if (FieldRange.parse(range_str)) |range| {
            try ranges.append(allocator, range);
        }
    }

    if (ranges.items.len == 0) {
        return line;
    }

    // Build result from matching fields
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var first = true;
    for (fields.items, 0..) |field, idx| {
        var matches_any = false;
        for (ranges.items) |range| {
            if (range.matches(idx, fields.items.len)) {
                matches_any = true;
                break;
            }
        }
        if (matches_any) {
            if (!first) {
                try result.append(allocator, ' ');
            }
            try result.appendSlice(allocator, field);
            first = false;
        }
    }

    if (result.items.len == 0) {
        return line;
    }

    return try allocator.dupe(u8, result.items);
}

/// Item with score for sorting
pub const ScoredItem = struct {
    line: []const u8,
    score: u32,

    pub fn lessThan(_: void, a: ScoredItem, b: ScoredItem) bool {
        // Higher score first
        return a.score > b.score;
    }
};

pub fn printHelp() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(
        \\nom - A fuzzy finder (fzf-compatible)
        \\
        \\Usage: nom [options]
        \\
        \\Search Mode:
        \\  -x, --extended        Extended-search mode (default)
        \\  +x, --no-extended     Disable extended-search mode
        \\  -e, --exact           Enable exact-match
        \\  -i                    Case-insensitive match
        \\  +i                    Case-sensitive match
        \\
        \\Interface:
        \\  -m, --multi           Enable multi-select
        \\  --no-mouse            Disable mouse
        \\  --reverse             Reverse orientation
        \\  --height=HEIGHT       Display height of the finder
        \\  --min-height=HEIGHT   Minimum height when --height is percent
        \\  --layout=LAYOUT       Choose layout: default, reverse, reverse-list
        \\
        \\Display:
        \\  --prompt=STR          Input prompt (default: '> ')
        \\  --pointer=STR         Pointer to the current line (default: '>')
        \\  --marker=STR          Multi-select marker (default: '>')
        \\  --header=STR          Header string
        \\  --header-lines=N      First N lines of input as header
        \\  --ansi                Enable processing of ANSI color codes
        \\  --no-ansi             Disable ANSI color processing
        \\  --tabstop=N           Number of spaces for a tab character (default: 8)
        \\
        \\Preview:
        \\  --preview=COMMAND     Command to preview highlighted line ({})
        \\  --preview-window=OPT  Preview window layout
        \\
        \\Scripting:
        \\  -q, --query=STR       Start the finder with the given query
        \\  -f, --filter=STR      Filter mode (no interactive finder)
        \\  -1, --select-1        Auto-select if only one match
        \\  -0, --exit-0          Exit immediately when no match
        \\  --print-query         Print query as the first line
        \\  --expect=KEYS         Comma-separated list of keys to complete
        \\  --read0               Read input delimited by NUL character
        \\  --print0              Print output delimited by NUL character
        \\  --sync                Synchronous search for batch processing
        \\
        \\History:
        \\  --history=FILE        History file
        \\  --history-size=N      Maximum number of history entries (default: 1000)
        \\
        \\Other:
        \\  -h, --help            Show this help
        \\  --version             Show version
        \\
    ) catch {};
}

pub fn printVersion() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll("nom 0.1.0\n") catch {};
}

/// Run filter mode (no TUI, just output matching lines)
pub fn runFilter(
    allocator: std.mem.Allocator,
    args: *const Args,
    input: []const u8,
) !void {
    var matcher = try nom.Matcher.initDefault(allocator);
    defer matcher.deinit();

    // Configure case sensitivity
    if (args.case_sensitive) {
        matcher.config.ignore_case = false;
    } else if (!args.smart_case) {
        matcher.config.ignore_case = true;
    }

    const filter_query = args.filter orelse "";

    const case_mode: CaseMatching = if (args.case_sensitive)
        .respect
    else if (args.smart_case)
        .smart
    else
        .ignore;

    const normalization: Normalization = .smart;

    var pattern = try nom.Pattern.parse(allocator, filter_query, case_mode, normalization);
    defer pattern.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(allocator);

    // Track allocated nth fields for cleanup
    var nth_fields: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (nth_fields.items) |f| {
            allocator.free(f);
        }
        nth_fields.deinit(allocator);
    }

    // Collect and score all matching items
    var scored_items: std.ArrayListUnmanaged(ScoredItem) = .empty;
    defer scored_items.deinit(allocator);

    var lines = std.mem.splitScalar(u8, input, args.delimiter);
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Extract fields for matching if --nth is specified
        const match_text = if (args.nth) |nth| blk: {
            const extracted = try extractNthFields(allocator, line, nth, args.delimiter);
            if (extracted.ptr != line.ptr) {
                try nth_fields.append(allocator, extracted);
            }
            break :blk extracted;
        } else line;

        const haystack = nom.Utf32Str.init(match_text, allocator, &buf);
        if (pattern.score(haystack, &matcher)) |s| {
            // Always output the original line, not the extracted fields
            try scored_items.append(allocator, .{ .line = line, .score = s });
        }
    }

    // Sort by score (highest first)
    std.mem.sort(ScoredItem, scored_items.items, {}, ScoredItem.lessThan);

    // Output matching lines
    const stdout = std.fs.File.stdout();
    const output_delimiter: []const u8 = if (args.print0) "\x00" else "\n";

    for (scored_items.items) |item| {
        stdout.writeAll(item.line) catch {};
        stdout.writeAll(output_delimiter) catch {};
    }
}

/// Run interactive TUI mode. Returns true if user aborted.
pub fn runTui(
    allocator: std.mem.Allocator,
    args: *const Args,
    input: []const u8,
) !bool {
    // Parse input into lines
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, input, args.delimiter);
    while (it.next()) |line| {
        if (line.len > 0) {
            try lines.append(allocator, line);
        }
    }

    if (lines.items.len == 0) {
        return false;
    }

    // Configure TUI
    const case_matching: CaseMatching = if (args.case_sensitive)
        .respect
    else if (args.smart_case)
        .smart
    else
        .ignore;

    // Parse height option
    var fullscreen = false;
    var height: ?u16 = null;
    if (args.height) |h| {
        if (std.mem.eql(u8, h, "100%")) {
            fullscreen = true;
        } else if (std.mem.endsWith(u8, h, "%")) {
            // Percentage height - treat as non-fullscreen with calculated height
            const pct = std.fmt.parseInt(u16, h[0 .. h.len - 1], 10) catch 50;
            height = @max(5, pct / 5); // Rough approximation
        } else {
            // Absolute line count
            height = std.fmt.parseInt(u16, h, 10) catch null;
        }
    }

    const tui_config = nom.TuiConfig{
        .prompt = args.prompt,
        .pointer = args.pointer,
        .marker = args.marker,
        .header = args.header,
        .header_lines = args.header_lines,
        .multi = args.multi,
        .reverse = args.reverse,
        .no_mouse = args.no_mouse,
        .ansi = args.ansi,
        .case_matching = case_matching,
        .exact = args.exact,
        .fullscreen = fullscreen,
        .height = height,
    };

    // Run TUI
    var tui = try nom.Tui.init(allocator, lines.items, tui_config);
    defer tui.deinit();

    // Set initial query if provided
    if (args.query) |q| {
        try tui.setQuery(q);
    }

    // Set preview if configured
    if (args.preview) |preview_cmd| {
        const preview_width: u16 = @truncate(tui.term.width / 2);
        tui.setPreview(preview_cmd, preview_width);
    }

    // Run
    var result = try tui.run();
    defer result.deinit();

    // Output results
    const stdout = std.fs.File.stdout();
    const output_delimiter: []const u8 = if (args.print0) "\x00" else "\n";

    if (args.print_query) {
        stdout.writeAll(result.query) catch {};
        stdout.writeAll(output_delimiter) catch {};
    }

    if (result.aborted) {
        return true; // Signal abort to caller
    }

    for (result.selected.items) |item| {
        stdout.writeAll(item) catch {};
        stdout.writeAll(output_delimiter) catch {};
    }

    return false;
}

test "Args.parse basic flags" {
    // This would need to mock argv for proper testing
}

test "FieldRange.parse" {
    const testing = std.testing;

    // Single field
    const r1 = FieldRange.parse("1").?;
    try testing.expectEqual(@as(?i32, 1), r1.start);
    try testing.expectEqual(@as(?i32, 1), r1.end);

    // Range
    const r2 = FieldRange.parse("1..3").?;
    try testing.expectEqual(@as(?i32, 1), r2.start);
    try testing.expectEqual(@as(?i32, 3), r2.end);

    // Open start
    const r3 = FieldRange.parse("..3").?;
    try testing.expectEqual(@as(?i32, null), r3.start);
    try testing.expectEqual(@as(?i32, 3), r3.end);

    // Open end
    const r4 = FieldRange.parse("2..").?;
    try testing.expectEqual(@as(?i32, 2), r4.start);
    try testing.expectEqual(@as(?i32, null), r4.end);

    // Negative
    const r5 = FieldRange.parse("-1").?;
    try testing.expectEqual(@as(?i32, -1), r5.start);
    try testing.expectEqual(@as(?i32, -1), r5.end);
}

test "FieldRange.matches" {
    const testing = std.testing;

    // Single field
    const r1 = FieldRange{ .start = 2, .end = 2 };
    try testing.expect(!r1.matches(0, 5)); // field 1
    try testing.expect(r1.matches(1, 5)); // field 2
    try testing.expect(!r1.matches(2, 5)); // field 3

    // Range
    const r2 = FieldRange{ .start = 2, .end = 4 };
    try testing.expect(!r2.matches(0, 5));
    try testing.expect(r2.matches(1, 5));
    try testing.expect(r2.matches(2, 5));
    try testing.expect(r2.matches(3, 5));
    try testing.expect(!r2.matches(4, 5));

    // Negative index
    const r3 = FieldRange{ .start = -1, .end = -1 };
    try testing.expect(!r3.matches(3, 5)); // field 4
    try testing.expect(r3.matches(4, 5)); // field 5 (last)
}
