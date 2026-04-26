//! nom-grep - A literal-string grep for source trees.
//!
//! Usage: nom grep [OPTIONS] PATTERN [PATH]
//!
//! Walks the tree (respecting .gitignore by default), searches each
//! non-binary file for the literal pattern, and prints grouped results.

const std = @import("std");
const grep = @import("grep.zig");

const Args = struct {
    needle: ?[]const u8 = null,
    path: ?[]const u8 = null,

    case_insensitive: bool = false,
    before_context: usize = 0,
    after_context: usize = 0,
    /// `-C N` sets both before and after if neither was set explicitly.
    context: ?usize = null,

    extensions: std.ArrayListUnmanaged([]const u8) = .empty,
    exclude_patterns: std.ArrayListUnmanaged([]const u8) = .empty,

    hidden: bool = false,
    no_ignore: bool = false,
    follow: bool = false,
    max_depth: ?usize = null,
    threads: ?usize = null,

    color: enum { auto, always, never } = .auto,

    help: bool = false,
    version: bool = false,

    fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.extensions.deinit(allocator);
        self.exclude_patterns.deinit(allocator);
    }

    pub const ParseError = error{
        UnknownOption,
        InvalidArgument,
        MissingArgument,
        OutOfMemory,
    };

    fn parseFromIter(allocator: std.mem.Allocator, arg_iter: anytype) ParseError!Args {
        var args = Args{};
        errdefer args.deinit(allocator);

        var positional: usize = 0;

        while (arg_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                args.version = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                args.case_insensitive = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--hidden")) {
                args.hidden = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--no-ignore")) {
                args.no_ignore = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--follow")) {
                args.follow = true;
                continue;
            }

            if (try takeValueOpt(arg, "-A", "--after-context", arg_iter)) |v| {
                args.after_context = try parseNumArg("-A", v);
                continue;
            }
            if (try takeValueOpt(arg, "-B", "--before-context", arg_iter)) |v| {
                args.before_context = try parseNumArg("-B", v);
                continue;
            }
            if (try takeValueOpt(arg, "-C", "--context", arg_iter)) |v| {
                args.context = try parseNumArg("-C", v);
                continue;
            }
            if (try takeValueOpt(arg, "-d", "--max-depth", arg_iter)) |v| {
                args.max_depth = try parseNumArg("-d", v);
                continue;
            }
            if (try takeValueOpt(arg, "-j", "--threads", arg_iter)) |v| {
                args.threads = try parseNumArg("-j", v);
                continue;
            }
            if (try takeValueOpt(arg, "-e", "--extension", arg_iter)) |v| {
                args.extensions.append(allocator, v) catch return error.OutOfMemory;
                continue;
            }
            if (try takeValueOpt(arg, "-E", "--exclude", arg_iter)) |v| {
                args.exclude_patterns.append(allocator, v) catch return error.OutOfMemory;
                continue;
            }
            if (try takeValueOpt(arg, null, "--color", arg_iter)) |v| {
                args.color = std.meta.stringToEnum(@TypeOf(args.color), v) orelse {
                    std.debug.print("error: --color: invalid value '{s}' (expected auto, always, or never)\n", .{v});
                    return error.InvalidArgument;
                };
                continue;
            }

            if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
                std.debug.print("error: unknown option '{s}'\n", .{arg});
                return error.UnknownOption;
            }

            switch (positional) {
                0 => args.needle = arg,
                1 => args.path = arg,
                else => return error.UnknownOption,
            }
            positional += 1;
        }

        if (args.context) |c| {
            if (args.before_context == 0) args.before_context = c;
            if (args.after_context == 0) args.after_context = c;
        }

        return args;
    }
};

/// Match `arg` against `-X` (with optional combined `-Xvalue`), `--long`, or
/// `--long=value`. Returns the value, consuming the next iter element when
/// the form is `-X value` or `--long value`.
fn takeValueOpt(arg: []const u8, short: ?[]const u8, long: []const u8, arg_iter: anytype) Args.ParseError!?[]const u8 {
    if (std.mem.eql(u8, arg, long)) {
        return arg_iter.next() orelse {
            std.debug.print("error: {s} requires an argument\n", .{long});
            return error.MissingArgument;
        };
    }
    const long_eq = blk: {
        var buf: [64]u8 = undefined;
        if (long.len + 1 > buf.len) break :blk null;
        @memcpy(buf[0..long.len], long);
        buf[long.len] = '=';
        break :blk buf[0 .. long.len + 1];
    };
    if (long_eq) |le| {
        if (std.mem.startsWith(u8, arg, le)) return arg[le.len..];
    }
    if (short) |s| {
        if (std.mem.eql(u8, arg, s)) {
            return arg_iter.next() orelse {
                std.debug.print("error: {s} requires an argument\n", .{s});
                return error.MissingArgument;
            };
        }
        if (std.mem.startsWith(u8, arg, s) and arg.len > s.len) {
            return arg[s.len..];
        }
    }
    return null;
}

fn parseNumArg(flag: []const u8, s: []const u8) Args.ParseError!usize {
    return std.fmt.parseInt(usize, s, 10) catch {
        std.debug.print("error: {s}: value is not a valid number: '{s}'\n", .{ flag, s });
        return error.InvalidArgument;
    };
}

fn printHelp(io: std.Io) void {
    const text =
        \\nom-grep - Literal string search across a source tree
        \\
        \\USAGE:
        \\    nom grep [OPTIONS] PATTERN [PATH]
        \\
        \\ARGUMENTS:
        \\    PATTERN    Literal string to search for (no regex)
        \\    PATH       Root directory to search (default: .)
        \\
        \\OPTIONS:
        \\    -h, --help                 Print this help message
        \\    -V, --version              Print version information
        \\
        \\  Pattern:
        \\    -i, --ignore-case          Case-insensitive search
        \\
        \\  Context:
        \\    -A, --after-context <N>    Show N lines after each match
        \\    -B, --before-context <N>   Show N lines before each match
        \\    -C, --context <N>          Show N lines on both sides
        \\
        \\  Filtering:
        \\    -e, --extension <ext>      Only search files with this extension
        \\                               (repeatable; e.g. -e zig -e rs)
        \\    -E, --exclude <pattern>    Exclude entries matching glob
        \\    -d, --max-depth <num>      Maximum search depth
        \\
        \\  Traversal:
        \\    -H, --hidden               Include hidden files/directories
        \\    -I, --no-ignore            Don't respect .gitignore
        \\    -L, --follow               Follow symbolic links
        \\
        \\  Output:
        \\        --color <when>         When to use colors: auto, always, never
        \\    -j, --threads <num>        Worker thread count
        \\
        \\EXAMPLES:
        \\    nom grep TODO                       All TODOs in cwd
        \\    nom grep -i error src/              Case-insensitive
        \\    nom grep -C 2 needle                With 2 lines of context
        \\    nom grep -e zig -e rs needle        Only .zig and .rs files
        \\
    ;
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.writeAll(text) catch {};
    fw.interface.flush() catch {};
}

fn printVersion(io: std.Io) void {
    var buf: [32]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.writeAll("nom-grep 0.1.0\n") catch {};
    fw.interface.flush() catch {};
}

/// Run grep with the given argument iterator (skips the first arg which is
/// the program name or "grep" subcommand).
pub fn run(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, arg_iter: anytype) !void {
    var args = Args.parseFromIter(allocator, arg_iter) catch |err| {
        if (err == error.InvalidArgument or err == error.MissingArgument or err == error.UnknownOption) {
            std.process.exit(1);
        }
        return err;
    };
    defer args.deinit(allocator);

    if (args.help) {
        printHelp(io);
        return;
    }
    if (args.version) {
        printVersion(io);
        return;
    }

    const needle = args.needle orelse {
        std.debug.print("error: missing PATTERN\n", .{});
        printHelp(io);
        std.process.exit(2);
    };

    const search_path = args.path orelse ".";
    const cwd = std.Io.Dir.cwd();

    // Stat to decide: file vs directory. A non-existent path errors out.
    const st = cwd.statFile(io, search_path, .{}) catch |err| {
        std.debug.print("error: cannot access '{s}': {}\n", .{ search_path, err });
        std.process.exit(1);
    };

    const use_color = switch (args.color) {
        .always => true,
        .never => false,
        .auto => std.Io.File.stdout().isTty(io) catch false,
    };

    var write_buf: [16 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &write_buf);
    const writer = &fw.interface;

    const opts: grep.Options = .{
        .needle = needle,
        .case_insensitive = args.case_insensitive,
        .extensions = args.extensions.items,
        .before_context = args.before_context,
        .after_context = args.after_context,
        .ignore_hidden = !args.hidden,
        .read_gitignore = !args.no_ignore,
        .require_git = !args.no_ignore,
        .follow_symlinks = args.follow,
        .max_depth = args.max_depth,
        .threads = args.threads,
        .home_dir = environ_map.get("HOME"),
        .exclude_patterns = args.exclude_patterns.items,
        .use_color = use_color,
    };

    const total = if (st.kind == .directory) blk: {
        var search_dir = cwd.openDir(io, search_path, .{ .iterate = true }) catch |err| {
            std.debug.print("error: cannot open dir '{s}': {}\n", .{ search_path, err });
            std.process.exit(1);
        };
        defer search_dir.close(io);
        const display_root = if (std.mem.eql(u8, search_path, ".")) "" else search_path;
        break :blk try grep.run(allocator, io, search_dir, display_root, opts, writer);
    } else try grep.runSingleFile(allocator, io, cwd, search_path, search_path, opts, writer);

    writer.flush() catch {};

    // Exit code 1 when no matches, 0 otherwise (BSD/GNU grep convention).
    if (total == 0) std.process.exit(1);
}
