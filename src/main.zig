//! nom - A fuzzy finder CLI compatible with fzf
//!
//! Usage: nom [options]
//!        nom fzf [options]   - Run fzf-compatible fuzzy finder
//!        nom fd [options]    - Run fd-compatible file finder
//!
//! Options are largely compatible with fzf/fd.

const std = @import("std");
const fzf = @import("fzf.zig");
const fd_main = @import("fd/main.zig");
const files = @import("files.zig");
const StreamingReader = @import("streaming_reader.zig").StreamingReader;
const StreamingWalker = files.StreamingWalker;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get argv to check for subcommand
    const argv = std.process.argsAlloc(allocator) catch return error.OutOfMemory;
    defer std.process.argsFree(allocator, argv);

    // Check for subcommand (first argument after program name)
    if (argv.len > 1) {
        const first_arg = argv[1];
        if (std.mem.eql(u8, first_arg, "fd")) {
            // Run fd mode with remaining args
            var arg_iter = SliceIterator{ .slice = argv[2..] };
            return fd_main.run(allocator, &arg_iter);
        } else if (std.mem.eql(u8, first_arg, "fzf")) {
            // Run fzf mode with remaining args
            const args = fzf.Args.parseFromSlice(argv[2..]) catch |err| switch (err) {
                error.UnknownOption => std.process.exit(2),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return runFzf(allocator, args);
        }
    }

    // Default: run fzf mode with all args
    const args = fzf.Args.parseFromSlice(argv[1..]) catch |err| switch (err) {
        error.UnknownOption => std.process.exit(2),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return runFzf(allocator, args);
}

/// Iterator adapter for a slice of arguments (for fd_main.run)
const SliceIterator = struct {
    slice: []const [:0]const u8,
    index: usize = 0,

    pub fn next(self: *SliceIterator) ?[:0]const u8 {
        if (self.index >= self.slice.len) return null;
        defer self.index += 1;
        return self.slice[self.index];
    }

    pub fn skip(self: *SliceIterator) bool {
        if (self.index >= self.slice.len) return false;
        self.index += 1;
        return true;
    }
};

/// Run fzf mode with parsed args
fn runFzf(allocator: std.mem.Allocator, args: fzf.Args) !void {
    if (args.help) {
        fzf.printHelp();
        return;
    }

    if (args.version) {
        fzf.printVersion();
        return;
    }

    const stdin_is_tty = fzf.isStdinTty();

    if (args.filter != null) {
        const input = if (stdin_is_tty)
            try fzf.getDefaultSource(allocator)
        else
            try std.fs.File.stdin().readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(input);

        try fzf.runFilter(allocator, &args, input);
        return;
    }

    // Run interactive TUI
    const aborted = try if (stdin_is_tty) blk: {
        // Check for FZF_DEFAULT_COMMAND first
        if (std.posix.getenv("FZF_DEFAULT_COMMAND")) |_| {
            // Use the command output (non-streaming for now)
            const input = try fzf.getDefaultSource(allocator);
            defer allocator.free(input);
            break :blk fzf.runTui(allocator, &args, input);
        } else {
            // Use streaming file walker for built-in directory walking
            var walker = StreamingWalker.init(allocator);
            defer walker.deinit();
            try walker.start();
            break :blk fzf.runTuiWithWalker(allocator, &args, &walker);
        }
    } else blk: {
        var reader = StreamingReader.init(allocator, args.delimiter, args.header_lines, args.nth, args.with_nth);
        defer reader.deinit();
        try reader.start(std.fs.File.stdin());
        break :blk fzf.runTuiStreaming(allocator, &args, &reader);
    };

    if (aborted) {
        std.process.exit(130);
    }
}
