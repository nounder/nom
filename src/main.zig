//! nom - A fuzzy finder CLI compatible with fzf
//!
//! Usage: nom [options]
//!
//! Options are largely compatible with fzf.

const std = @import("std");
const nom = @import("root.zig");

const Matcher = nom.Matcher;
const Pattern = nom.Pattern;
const Utf32Str = nom.Utf32Str;
const Config = nom.Config;
const CaseMatching = nom.CaseMatching;
const Normalization = nom.Normalization;
const Tui = nom.Tui;
const TuiConfig = nom.TuiConfig;

/// CLI arguments
const Args = struct {
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

    const Layout = enum {
        default,
        reverse_layout,
        reverse_list,
    };

    /// Parse command line arguments. Returns args and the argv slice which must be kept alive.
    fn parse(allocator: std.mem.Allocator) !struct { args: Args, argv: [][:0]u8 } {
        var args = Args{};
        const argv = try std.process.argsAlloc(allocator);
        // Note: argv must NOT be freed while args is in use

        var i: usize = 1; // Skip program name
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];

            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.help = true;
            } else if (std.mem.eql(u8, arg, "--version")) {
                args.version = true;
            } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--extended")) {
                args.extended = true;
            } else if (std.mem.eql(u8, arg, "+x") or std.mem.eql(u8, arg, "--no-extended")) {
                args.extended = false;
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exact")) {
                args.exact = true;
            } else if (std.mem.eql(u8, arg, "+e") or std.mem.eql(u8, arg, "--no-exact")) {
                args.exact = false;
            } else if (std.mem.eql(u8, arg, "-i")) {
                args.case_sensitive = false;
                args.smart_case = false;
            } else if (std.mem.eql(u8, arg, "+i")) {
                args.case_sensitive = true;
                args.smart_case = false;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--multi")) {
                args.multi = true;
            } else if (std.mem.eql(u8, arg, "+m") or std.mem.eql(u8, arg, "--no-multi")) {
                args.multi = false;
            } else if (std.mem.eql(u8, arg, "--no-mouse")) {
                args.no_mouse = true;
            } else if (std.mem.eql(u8, arg, "--reverse")) {
                args.reverse = true;
            } else if (std.mem.eql(u8, arg, "--no-reverse")) {
                args.reverse = false;
            } else if (std.mem.eql(u8, arg, "--ansi")) {
                args.ansi = true;
            } else if (std.mem.eql(u8, arg, "--no-ansi")) {
                args.ansi = false;
            } else if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--read0")) {
                args.read0 = true;
                args.delimiter = 0;
            } else if (std.mem.eql(u8, arg, "--print0")) {
                args.print0 = true;
            } else if (std.mem.eql(u8, arg, "-1") or std.mem.eql(u8, arg, "--select-1")) {
                args.select_1 = true;
            } else if (std.mem.eql(u8, arg, "--exit-0")) {
                args.exit_0 = true;
            } else if (std.mem.eql(u8, arg, "--print-query")) {
                args.print_query = true;
            } else if (std.mem.eql(u8, arg, "--sync")) {
                args.sync = true;
            } else if (std.mem.startsWith(u8, arg, "-q") or std.mem.startsWith(u8, arg, "--query")) {
                if (std.mem.startsWith(u8, arg, "-q")) {
                    if (arg.len > 2) {
                        args.query = arg[2..];
                    } else if (i + 1 < argv.len) {
                        i += 1;
                        args.query = argv[i];
                    }
                } else if (std.mem.startsWith(u8, arg, "--query=")) {
                    args.query = arg[8..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.query = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "-f") or std.mem.startsWith(u8, arg, "--filter")) {
                if (std.mem.startsWith(u8, arg, "-f")) {
                    if (arg.len > 2) {
                        args.filter = arg[2..];
                    } else if (i + 1 < argv.len) {
                        i += 1;
                        args.filter = argv[i];
                    }
                } else if (std.mem.startsWith(u8, arg, "--filter=")) {
                    args.filter = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.filter = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--prompt")) {
                if (std.mem.startsWith(u8, arg, "--prompt=")) {
                    args.prompt = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.prompt = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--pointer")) {
                if (std.mem.startsWith(u8, arg, "--pointer=")) {
                    args.pointer = arg[10..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.pointer = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--marker")) {
                if (std.mem.startsWith(u8, arg, "--marker=")) {
                    args.marker = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.marker = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--header")) {
                if (std.mem.startsWith(u8, arg, "--header=")) {
                    args.header = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.header = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--header-lines")) {
                if (std.mem.startsWith(u8, arg, "--header-lines=")) {
                    args.header_lines = std.fmt.parseInt(usize, arg[15..], 10) catch 0;
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.header_lines = std.fmt.parseInt(usize, argv[i], 10) catch 0;
                }
            } else if (std.mem.startsWith(u8, arg, "--height")) {
                if (std.mem.startsWith(u8, arg, "--height=")) {
                    args.height = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.height = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--min-height")) {
                if (std.mem.startsWith(u8, arg, "--min-height=")) {
                    args.min_height = std.fmt.parseInt(usize, arg[13..], 10) catch 10;
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.min_height = std.fmt.parseInt(usize, argv[i], 10) catch 10;
                }
            } else if (std.mem.startsWith(u8, arg, "--layout")) {
                var layout_str: []const u8 = "";
                if (std.mem.startsWith(u8, arg, "--layout=")) {
                    layout_str = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    layout_str = argv[i];
                }
                if (std.mem.eql(u8, layout_str, "reverse")) {
                    args.layout = .reverse_layout;
                } else if (std.mem.eql(u8, layout_str, "reverse-list")) {
                    args.layout = .reverse_list;
                }
            } else if (std.mem.startsWith(u8, arg, "--preview")) {
                if (std.mem.startsWith(u8, arg, "--preview=")) {
                    args.preview = arg[10..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.preview = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--preview-window")) {
                if (std.mem.startsWith(u8, arg, "--preview-window=")) {
                    args.preview_window = arg[17..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.preview_window = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--tabstop")) {
                if (std.mem.startsWith(u8, arg, "--tabstop=")) {
                    args.tabstop = std.fmt.parseInt(usize, arg[10..], 10) catch 8;
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.tabstop = std.fmt.parseInt(usize, argv[i], 10) catch 8;
                }
            } else if (std.mem.startsWith(u8, arg, "--expect")) {
                if (std.mem.startsWith(u8, arg, "--expect=")) {
                    args.expect = arg[9..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.expect = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--history")) {
                if (std.mem.startsWith(u8, arg, "--history=")) {
                    args.history = arg[10..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.history = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--history-size")) {
                if (std.mem.startsWith(u8, arg, "--history-size=")) {
                    args.history_size = std.fmt.parseInt(usize, arg[15..], 10) catch 1000;
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.history_size = std.fmt.parseInt(usize, argv[i], 10) catch 1000;
                }
            } else if (std.mem.startsWith(u8, arg, "-n") or std.mem.startsWith(u8, arg, "--nth")) {
                if (std.mem.startsWith(u8, arg, "-n")) {
                    if (arg.len > 2) {
                        args.nth = arg[2..];
                    } else if (i + 1 < argv.len) {
                        i += 1;
                        args.nth = argv[i];
                    }
                } else if (std.mem.startsWith(u8, arg, "--nth=")) {
                    args.nth = arg[6..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.nth = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--with-nth")) {
                if (std.mem.startsWith(u8, arg, "--with-nth=")) {
                    args.with_nth = arg[11..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    args.with_nth = argv[i];
                }
            }
            // Ignore unknown args for now
        }

        return .{ .args = args, .argv = argv };
    }
};

fn printHelp() void {
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

fn printVersion() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll("nom 0.1.0\n") catch {};
}

/// Field range for --nth option
const FieldRange = struct {
    start: ?i32 = null, // null means beginning
    end: ?i32 = null, // null means end, negative counts from end

    /// Parse a single field range like "1", "2..", "..3", "1..3", "-1"
    fn parse(s: []const u8) ?FieldRange {
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
    fn matches(self: FieldRange, idx: usize, total: usize) bool {
        const i: i32 = @intCast(idx + 1); // Convert to 1-based
        const t: i32 = @intCast(total);

        // Resolve negative indices
        const start = if (self.start) |s| (if (s < 0) t + s + 1 else s) else 1;
        const end = if (self.end) |e| (if (e < 0) t + e + 1 else e) else t;

        return i >= start and i <= end;
    }
};

/// Extract fields from a line based on --nth specification
fn extractNthFields(allocator: std.mem.Allocator, line: []const u8, nth: []const u8, delimiter: u8) ![]const u8 {
    // Split line into fields
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(allocator);

    var field_delim = delimiter;
    if (delimiter == '\n') {
        // Default to whitespace splitting for normal mode
        field_delim = ' ';
    }

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
    var ranges: std.ArrayList(FieldRange) = .empty;
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
    var result: std.ArrayList(u8) = .empty;
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
const ScoredItem = struct {
    line: []const u8,
    score: u32,

    fn lessThan(_: void, a: ScoredItem, b: ScoredItem) bool {
        // Higher score first
        return a.score > b.score;
    }
};

/// Run filter mode (no TUI, just output matching lines)
fn runFilter(
    allocator: std.mem.Allocator,
    args: *const Args,
    input: []const u8,
) !void {
    var matcher = try Matcher.initDefault(allocator);
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

    var pattern = try Pattern.parse(allocator, filter_query, case_mode, normalization);
    defer pattern.deinit();

    var buf: std.ArrayListUnmanaged(u21) = .empty;
    defer buf.deinit(allocator);

    // Track allocated nth fields for cleanup
    var nth_fields: std.ArrayList([]const u8) = .empty;
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

        const haystack = Utf32Str.init(match_text, allocator, &buf);
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsed = try Args.parse(allocator);
    const args = parsed.args;
    defer std.process.argsFree(allocator, parsed.argv);

    if (args.help) {
        printHelp();
        return;
    }

    if (args.version) {
        printVersion();
        return;
    }

    // Read all input
    const stdin = std.fs.File.stdin();
    const input = try stdin.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB max
    defer allocator.free(input);

    if (args.filter != null) {
        try runFilter(allocator, &args, input);
        return;
    }

    // Run interactive TUI
    const aborted = runTui(allocator, &args, input) catch |err| {
        // Non-abort errors propagate
        return err;
    };

    if (aborted) {
        std.process.exit(130);
    }
}

/// Run interactive TUI mode. Returns true if user aborted.
fn runTui(
    allocator: std.mem.Allocator,
    args: *const Args,
    input: []const u8,
) !bool {
    // Parse input into lines
    var lines: std.ArrayList([]const u8) = .empty;
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
            // For now, just use a reasonable default
            const pct = std.fmt.parseInt(u16, h[0 .. h.len - 1], 10) catch 50;
            height = @max(5, pct / 5); // Rough approximation
        } else {
            // Absolute line count
            height = std.fmt.parseInt(u16, h, 10) catch null;
        }
    }

    const tui_config = TuiConfig{
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
    var tui = try Tui.init(allocator, lines.items, tui_config);
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
