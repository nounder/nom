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
const fd = @import("fd/fd.zig");

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
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = Args{};
    errdefer args.deinit(allocator);

    var arg_iter = try std.process.argsWithAllocator(allocator);
    defer arg_iter.deinit();

    // Skip program name
    _ = arg_iter.skip();

    var positional_count: usize = 0;

    while (arg_iter.next()) |arg| {
        // Handle flags
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.help = true;
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                args.version = true;
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--hidden")) {
                args.hidden = true;
            } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--no-ignore")) {
                args.no_ignore = true;
            } else if (std.mem.eql(u8, arg, "--no-ignore-vcs")) {
                args.no_ignore_vcs = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--case-sensitive")) {
                args.case_sensitive = true;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                args.case_insensitive = true;
            } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
                args.glob = true;
                args.fixed_strings = false;
            } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
                args.fixed_strings = true;
                args.glob = false;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--full-path")) {
                args.full_path = true;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--absolute-path")) {
                args.absolute_path = true;
            } else if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--print0")) {
                args.print0 = true;
            } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--follow")) {
                args.follow = true;
            } else if (std.mem.eql(u8, arg, "--one-file-system")) {
                args.one_file_system = true;
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
                if (arg_iter.next()) |type_arg| {
                    const ft = fd.FileType.fromChar(type_arg[0]) orelse {
                        std.debug.print("error: invalid type '{s}'\n", .{type_arg});
                        return error.InvalidArgument;
                    };
                    if (args.file_types) |existing| {
                        args.file_types = existing.merge(ft);
                    } else {
                        args.file_types = ft;
                    }
                } else {
                    std.debug.print("error: --type requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--extension")) {
                if (arg_iter.next()) |ext| {
                    try args.extensions.append(allocator, ext);
                } else {
                    std.debug.print("error: --extension requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--exclude")) {
                if (arg_iter.next()) |pattern| {
                    try args.exclude_patterns.append(allocator, pattern);
                } else {
                    std.debug.print("error: --exclude requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--max-depth")) {
                if (arg_iter.next()) |depth_str| {
                    args.max_depth = std.fmt.parseInt(usize, depth_str, 10) catch {
                        std.debug.print("error: invalid depth '{s}'\n", .{depth_str});
                        return error.InvalidArgument;
                    };
                } else {
                    std.debug.print("error: --max-depth requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--min-depth")) {
                if (arg_iter.next()) |depth_str| {
                    args.min_depth = std.fmt.parseInt(usize, depth_str, 10) catch {
                        std.debug.print("error: invalid depth '{s}'\n", .{depth_str});
                        return error.InvalidArgument;
                    };
                } else {
                    std.debug.print("error: --min-depth requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--size")) {
                if (arg_iter.next()) |size_str| {
                    const sf = fd.SizeFilter.parse(size_str) catch {
                        std.debug.print("error: invalid size '{s}'\n", .{size_str});
                        return error.InvalidArgument;
                    };
                    try args.size_filters.append(allocator, sf);
                } else {
                    std.debug.print("error: --size requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--max-results")) {
                if (arg_iter.next()) |num_str| {
                    args.max_results = std.fmt.parseInt(usize, num_str, 10) catch {
                        std.debug.print("error: invalid number '{s}'\n", .{num_str});
                        return error.InvalidArgument;
                    };
                } else {
                    std.debug.print("error: --max-results requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--color")) {
                if (arg_iter.next()) |color_arg| {
                    if (std.mem.eql(u8, color_arg, "auto")) {
                        args.color = .auto;
                    } else if (std.mem.eql(u8, color_arg, "always")) {
                        args.color = .always;
                    } else if (std.mem.eql(u8, color_arg, "never")) {
                        args.color = .never;
                    } else {
                        std.debug.print("error: invalid color mode '{s}'\n", .{color_arg});
                        return error.InvalidArgument;
                    }
                } else {
                    std.debug.print("error: --color requires an argument\n", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.startsWith(u8, arg, "-t")) {
                // Handle -tf, -td, etc.
                const type_char = arg[2];
                const ft = fd.FileType.fromChar(type_char) orelse {
                    std.debug.print("error: invalid type '{c}'\n", .{type_char});
                    return error.InvalidArgument;
                };
                if (args.file_types) |existing| {
                    args.file_types = existing.merge(ft);
                } else {
                    args.file_types = ft;
                }
            } else if (std.mem.startsWith(u8, arg, "-e")) {
                // Handle -ezig, -ers, etc.
                const ext = arg[2..];
                try args.extensions.append(allocator, ext);
            } else if (std.mem.startsWith(u8, arg, "-E")) {
                // Handle -Epattern
                const pattern = arg[2..];
                try args.exclude_patterns.append(allocator, pattern);
            } else if (std.mem.startsWith(u8, arg, "-d")) {
                // Handle -d3
                const depth_str = arg[2..];
                args.max_depth = std.fmt.parseInt(usize, depth_str, 10) catch {
                    std.debug.print("error: invalid depth '{s}'\n", .{depth_str});
                    return error.InvalidArgument;
                };
            } else {
                std.debug.print("error: unknown option '{s}'\n", .{arg});
                return error.UnknownOption;
            }
        } else {
            // Positional argument
            if (positional_count == 0) {
                args.pattern = arg;
            } else {
                try args.paths.append(allocator, arg);
            }
            positional_count += 1;
        }
    }

    return args;
}

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = parseArgs(allocator) catch |err| {
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
    // fd default: regex (substring matching), -g for glob, -F for fixed
    const pattern_kind: fd.PatternKind = if (args.fixed_strings)
        .fixed
    else if (args.glob)
        .glob
    else
        .fixed; // Default to substring matching like fd

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
            // Prepend search path if not "."
            if (!std.mem.eql(u8, search_path, ".")) {
                if (args.absolute_path) {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const abs = try search_dir.realpath(entry.path, &buf);
                    writer.writeAll(abs) catch {};
                } else {
                    writer.writeAll(search_path) catch {};
                    if (entry.path.len > 0) {
                        writer.writeAll("/") catch {};
                        writer.writeAll(entry.path) catch {};
                    }
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
