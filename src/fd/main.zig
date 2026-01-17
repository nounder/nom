//! nom-fd - A file finder CLI compatible with fd
//!
//! Usage: nom-fd [OPTIONS] [PATTERN] [PATH]...
//!
//! Arguments:
//!   PATTERN  Search pattern (glob by default)
//!   PATH     Root directories to search (default: .)
//!
//! Options are largely compatible with fd.

const std = @import("std");
const fd = @import("fd.zig");

const Args = struct {
    // Pattern and paths
    pattern: ?[]const u8 = null,
    paths: std.ArrayListUnmanaged([]const u8) = .{},

    // Pattern options
    glob: bool = false, // fd default is regex (substring)
    fixed_strings: bool = false,
    case_sensitive: bool = false,
    case_insensitive: bool = false,
    full_path: bool = false,

    // Type filters
    file_types: ?fd.FileType = null,
    extensions: std.ArrayListUnmanaged([]const u8) = .{},
    size_filters: std.ArrayListUnmanaged(fd.SizeFilter) = .{},

    // Depth
    min_depth: ?usize = null,
    max_depth: ?usize = null,

    // Visibility
    hidden: bool = false,
    no_ignore: bool = false,
    no_ignore_vcs: bool = false,

    // Symlinks
    follow: bool = false,

    // Output
    absolute_path: bool = false,
    print0: bool = false,
    color: fd.ColorMode = .auto,

    // Misc
    help: bool = false,
    version: bool = false,
    max_results: ?usize = null,
    one_file_system: bool = false,

    // Exclude patterns
    exclude_patterns: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        self.extensions.deinit(allocator);
        self.size_filters.deinit(allocator);
        self.exclude_patterns.deinit(allocator);
    }

    /// Argument metadata for comptime parsing
    const Opt = struct {
        short: ?[]const u8 = null,
        long: ?[]const u8 = null,
        takes_value: bool = false,
        /// For options that can be combined like -tf, -ezig
        short_combined: bool = false,
    };

    /// Metadata for all arguments - drives the comptime parser generation
    const meta = .{
        .help = Opt{ .short = "-h", .long = "--help" },
        .version = Opt{ .short = "-V", .long = "--version" },
        .hidden = Opt{ .short = "-H", .long = "--hidden" },
        .no_ignore = Opt{ .short = "-I", .long = "--no-ignore" },
        .no_ignore_vcs = Opt{ .long = "--no-ignore-vcs" },
        .case_sensitive = Opt{ .short = "-s", .long = "--case-sensitive" },
        .case_insensitive = Opt{ .short = "-i", .long = "--ignore-case" },
        .glob = Opt{ .short = "-g", .long = "--glob" },
        .fixed_strings = Opt{ .short = "-F", .long = "--fixed-strings" },
        .full_path = Opt{ .short = "-p", .long = "--full-path" },
        .absolute_path = Opt{ .short = "-a", .long = "--absolute-path" },
        .print0 = Opt{ .short = "-0", .long = "--print0" },
        .follow = Opt{ .short = "-L", .long = "--follow" },
        .one_file_system = Opt{ .long = "--one-file-system" },
        .max_depth = Opt{ .short = "-d", .long = "--max-depth", .takes_value = true, .short_combined = true },
        .min_depth = Opt{ .long = "--min-depth", .takes_value = true },
        .max_results = Opt{ .long = "--max-results", .takes_value = true },
    };

    pub const ParseError = error{
        UnknownOption,
        InvalidArgument,
        MissingArgument,
        OutOfMemory,
    };

    /// Parse command line arguments using comptime-generated parser
    fn parse(allocator: std.mem.Allocator) ParseError!Args {
        var arg_iter = std.process.argsWithAllocator(allocator) catch return error.OutOfMemory;
        defer arg_iter.deinit();
        _ = arg_iter.skip(); // Skip program name
        return parseFromIter(allocator, &arg_iter);
    }

    /// Parse from an existing argument iterator (does not skip first arg)
    fn parseFromIter(allocator: std.mem.Allocator, arg_iter: anytype) ParseError!Args {
        var args = Args{};
        errdefer args.deinit(allocator);

        var positional_count: usize = 0;

        while (arg_iter.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                // Positional argument
                if (positional_count == 0) {
                    args.pattern = arg;
                } else {
                    args.paths.append(allocator, arg) catch return error.OutOfMemory;
                }
                positional_count += 1;
                continue;
            }

            // Try comptime-generated matchers for simple flags
            if (parseSimpleFlag(&args, arg)) continue;

            // Try comptime-generated matchers for value options
            if (try parseValueOpt(&args, arg, arg_iter, allocator)) continue;

            // Handle special cases not covered by comptime parser
            if (try parseSpecialOpt(&args, arg, arg_iter, allocator)) continue;

            std.debug.print("error: unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        }

        return args;
    }

    /// Parse simple boolean flags using comptime iteration
    fn parseSimpleFlag(args: *Args, arg: []const u8) bool {
        inline for (@typeInfo(@TypeOf(meta)).@"struct".fields) |field| {
            const opt: Opt = @field(meta, field.name);
            if (opt.takes_value) continue;

            if (opt.short) |short| {
                if (std.mem.eql(u8, arg, short)) {
                    @field(args, field.name) = true;
                    return true;
                }
            }
            if (opt.long) |long| {
                if (std.mem.eql(u8, arg, long)) {
                    @field(args, field.name) = true;
                    return true;
                }
            }
        }
        return false;
    }

    /// Parse options that take values using comptime iteration
    fn parseValueOpt(args: *Args, arg: []const u8, arg_iter: anytype, allocator: std.mem.Allocator) ParseError!bool {
        _ = allocator;
        inline for (@typeInfo(@TypeOf(meta)).@"struct".fields) |field| {
            const opt: Opt = @field(meta, field.name);
            if (!opt.takes_value) continue;

            const FieldType = @TypeOf(@field(args, field.name));

            // Check --long=value or --long value
            if (opt.long) |long| {
                const long_eq = long ++ "=";
                if (std.mem.startsWith(u8, arg, long_eq)) {
                    const value = arg[long_eq.len..];
                    setField(args, field.name, FieldType, value);
                    return true;
                } else if (std.mem.eql(u8, arg, long)) {
                    if (arg_iter.next()) |value| {
                        setField(args, field.name, FieldType, value);
                        return true;
                    }
                    std.debug.print("error: {s} requires an argument\n", .{long});
                    return error.MissingArgument;
                }
            }

            // Check -x value or -xvalue (combined)
            if (opt.short) |short| {
                if (std.mem.eql(u8, arg, short)) {
                    if (arg_iter.next()) |value| {
                        setField(args, field.name, FieldType, value);
                        return true;
                    }
                    std.debug.print("error: {s} requires an argument\n", .{short});
                    return error.MissingArgument;
                }
                if (opt.short_combined and std.mem.startsWith(u8, arg, short) and arg.len > short.len) {
                    const value = arg[short.len..];
                    setField(args, field.name, FieldType, value);
                    return true;
                }
            }
        }
        return false;
    }

    /// Set a field value with appropriate type conversion
    fn setField(args: *Args, comptime field_name: []const u8, comptime FieldType: type, value: []const u8) void {
        if (FieldType == ?usize) {
            @field(args, field_name) = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (FieldType == usize) {
            @field(args, field_name) = std.fmt.parseInt(usize, value, 10) catch 0;
        } else if (FieldType == ?[]const u8) {
            @field(args, field_name) = value;
        } else if (FieldType == []const u8) {
            @field(args, field_name) = value;
        }
    }

    /// Handle special options that need custom logic
    fn parseSpecialOpt(args: *Args, arg: []const u8, arg_iter: anytype, allocator: std.mem.Allocator) ParseError!bool {
        // -t/--type with special char parsing and merging
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            const type_arg = arg_iter.next() orelse {
                std.debug.print("error: --type requires an argument\n", .{});
                return error.MissingArgument;
            };
            return handleTypeArg(args, type_arg);
        }
        // -tf, -td combined form
        if (std.mem.startsWith(u8, arg, "-t") and arg.len == 3) {
            return handleTypeArg(args, arg[2..3]);
        }

        // -e/--extension with list accumulation
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--extension")) {
            const ext = arg_iter.next() orelse {
                std.debug.print("error: --extension requires an argument\n", .{});
                return error.MissingArgument;
            };
            args.extensions.append(allocator, ext) catch return error.OutOfMemory;
            return true;
        }
        // -ezig combined form
        if (std.mem.startsWith(u8, arg, "-e") and arg.len > 2) {
            args.extensions.append(allocator, arg[2..]) catch return error.OutOfMemory;
            return true;
        }

        // -E/--exclude with list accumulation
        if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--exclude")) {
            const pattern = arg_iter.next() orelse {
                std.debug.print("error: --exclude requires an argument\n", .{});
                return error.MissingArgument;
            };
            args.exclude_patterns.append(allocator, pattern) catch return error.OutOfMemory;
            return true;
        }
        // -Epattern combined form
        if (std.mem.startsWith(u8, arg, "-E") and arg.len > 2) {
            args.exclude_patterns.append(allocator, arg[2..]) catch return error.OutOfMemory;
            return true;
        }

        // -S/--size with special parsing
        if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--size")) {
            const size_str = arg_iter.next() orelse {
                std.debug.print("error: --size requires an argument\n", .{});
                return error.MissingArgument;
            };
            const sf = fd.SizeFilter.parse(size_str) catch {
                std.debug.print("error: invalid size '{s}'\n", .{size_str});
                return error.InvalidArgument;
            };
            args.size_filters.append(allocator, sf) catch return error.OutOfMemory;
            return true;
        }

        // -c/--color with enum parsing
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--color")) {
            const color_arg = arg_iter.next() orelse {
                std.debug.print("error: --color requires an argument\n", .{});
                return error.MissingArgument;
            };
            args.color = std.meta.stringToEnum(fd.ColorMode, color_arg) orelse {
                std.debug.print("error: invalid color mode '{s}'\n", .{color_arg});
                return error.InvalidArgument;
            };
            return true;
        }

        return false;
    }

    fn handleTypeArg(args: *Args, type_arg: []const u8) ParseError!bool {
        const ft = fd.FileType.fromChar(type_arg[0]) orelse {
            std.debug.print("error: invalid type '{s}'\n", .{type_arg});
            return error.InvalidArgument;
        };
        args.file_types = if (args.file_types) |existing| existing.merge(ft) else ft;
        return true;
    }
};

fn printHelp() void {
    const help_text =
        \\nom-fd - A file finder (fd-compatible)
        \\
        \\USAGE:
        \\    nom-fd [OPTIONS] [PATTERN] [PATH]...
        \\
        \\ARGUMENTS:
        \\    PATTERN    Search pattern (glob by default, smart case)
        \\    PATH       Root directories to search (default: .)
        \\
        \\OPTIONS:
        \\    -h, --help              Print this help message
        \\    -V, --version           Print version information
        \\
        \\  Pattern:
        \\    -g, --glob              Glob-based search (default)
        \\    -F, --fixed-strings     Literal string search
        \\    -s, --case-sensitive    Case-sensitive search
        \\    -i, --ignore-case       Case-insensitive search
        \\    -p, --full-path         Match against full path
        \\
        \\  Filtering:
        \\    -t, --type <type>       Filter by type: f(ile), d(ir), l(ink), x(exec), e(mpty)
        \\    -e, --extension <ext>   Filter by file extension
        \\    -S, --size <size>       Filter by size (+1k, -10m, 100b)
        \\    -d, --max-depth <num>   Maximum search depth
        \\        --min-depth <num>   Minimum search depth
        \\    -E, --exclude <pattern> Exclude entries matching pattern
        \\        --max-results <num> Limit number of results
        \\
        \\  Traversal:
        \\    -H, --hidden            Include hidden files/directories
        \\    -I, --no-ignore         Don't respect .gitignore
        \\        --no-ignore-vcs     Don't respect .gitignore (same as -I)
        \\    -L, --follow            Follow symbolic links
        \\        --one-file-system   Don't cross filesystem boundaries
        \\
        \\  Output:
        \\    -a, --absolute-path     Print absolute paths
        \\    -0, --print0            Separate results with null character
        \\    -c, --color <when>      When to use colors: auto, always, never
        \\
        \\EXAMPLES:
        \\    nom-fd                      List all non-hidden files
        \\    nom-fd '*.zig'              Find all .zig files
        \\    nom-fd -e rs src            Find .rs files in src/
        \\    nom-fd -t f -e md           Find markdown files
        \\    nom-fd -H -t d node_modules Find node_modules (including hidden)
        \\
    ;
    std.fs.File.stdout().writeAll(help_text) catch {};
}

fn printVersion() void {
    std.fs.File.stdout().writeAll("nom-fd 0.1.0\n") catch {};
}

/// Run fd with the given argument iterator (skips first arg which should be program name or "fd")
pub fn run(allocator: std.mem.Allocator, arg_iter: anytype) !void {
    var args = Args.parseFromIter(allocator, arg_iter) catch |err| {
        if (err == error.InvalidArgument or err == error.MissingArgument or err == error.UnknownOption) {
            std.process.exit(1);
        }
        return err;
    };
    defer args.deinit(allocator);

    if (args.help) {
        printHelp();
        return;
    }

    if (args.version) {
        printVersion();
        return;
    }

    // Determine case sensitivity
    const case_sensitive: ?bool = if (args.case_sensitive)
        true
    else if (args.case_insensitive)
        false
    else
        null; // smart case

    // Determine pattern kind
    // fd default: regex, -g for glob, -F for fixed
    const pattern_kind: fd.PatternKind = if (args.fixed_strings)
        .fixed
    else if (args.glob)
        .glob
    else
        .regex; // Default to regex like fd

    // Adjust depths: fd uses 1-based depth, walker uses 0-based
    // fd -d 1 means only direct children (depth 0 in walker)
    // fd --min-depth 1 means at least depth 0 in walker (same as default)
    const max_depth: ?usize = if (args.max_depth) |d| (if (d > 0) d - 1 else 0) else null;
    const min_depth: ?usize = if (args.min_depth) |d| (if (d > 0) d - 1 else 0) else null;

    // Build finder options
    const finder_opts = fd.FinderOptions{
        .search_pattern = args.pattern,
        .pattern_kind = pattern_kind,
        .case_sensitive = case_sensitive,
        .full_path = args.full_path,
        .file_types = args.file_types,
        .extensions = args.extensions.items,
        .size_filters = args.size_filters.items,
        .min_depth = min_depth,
        .max_depth = max_depth,
        .ignore_hidden = !args.hidden,
        .read_gitignore = !args.no_ignore and !args.no_ignore_vcs,
        .require_git = !args.no_ignore and !args.no_ignore_vcs,
        .follow_symlinks = args.follow,
        .one_file_system = args.one_file_system,
        .exclude_patterns = args.exclude_patterns.items,
        .max_results = args.max_results,
    };

    // Initialize finder
    var finder = try fd.Finder.init(allocator, finder_opts);
    defer finder.deinit();

    // Get stdout
    const stdout = std.fs.File.stdout();
    var write_buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&write_buf);
    const writer = &file_writer.interface;

    // Output format
    const output_fmt = fd.OutputFormat{
        .color = args.color,
        .null_separator = args.print0,
        .absolute_path = args.absolute_path,
    };

    // Search paths (default to current directory)
    const search_paths = if (args.paths.items.len > 0)
        args.paths.items
    else
        &[_][]const u8{"."};

    for (search_paths) |search_path| {
        // Open search directory
        var search_dir = std.fs.cwd().openDir(search_path, .{ .iterate = true }) catch |err| {
            std.debug.print("error: cannot access '{s}': {}\n", .{ search_path, err });
            continue;
        };
        defer search_dir.close();

        // Start finder at this path
        finder.startAt(search_dir) catch |err| switch (err) {
            error.AlreadyStarted => {
                // Re-initialize finder for next path
                finder.deinit();
                finder = try fd.Finder.init(allocator, finder_opts);
                try finder.startAt(search_dir);
            },
            else => return err,
        };

        // Iterate and output results
        while (try finder.next()) |entry| {
            const is_dir = entry.kind == .directory;
            // Prepend search path if not "."
            if (!std.mem.eql(u8, search_path, ".")) {
                if (args.absolute_path) {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const abs = try search_dir.realpath(entry.path, &buf);
                    writer.writeAll(abs) catch {};
                    if (is_dir) writer.writeAll("/") catch {};
                } else {
                    writer.writeAll(search_path) catch {};
                    if (entry.path.len > 0) {
                        writer.writeAll("/") catch {};
                        writer.writeAll(entry.path) catch {};
                    }
                    if (is_dir) writer.writeAll("/") catch {};
                }
                if (args.print0) {
                    writer.writeAll("\x00") catch {};
                } else {
                    writer.writeAll("\n") catch {};
                }
            } else {
                output_fmt.format(entry, writer) catch {};
            }
        }
    }
    writer.flush() catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch return error.OutOfMemory;
    defer arg_iter.deinit();
    _ = arg_iter.skip(); // Skip program name

    try run(allocator, &arg_iter);
}
