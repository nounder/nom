//! nom - A fuzzy finder CLI compatible with fzf
//!
//! Usage: nom [options]
//!        nom fzf [options]   - Run fzf-compatible fuzzy finder
//!        nom fd [options]    - Run fd-compatible file finder
//!
//! Options are largely compatible with fd/fzf.

const std = @import("std");
const fzf = @import("fzf.zig");
const fd_main = @import("fd/main.zig");
const files = @import("files.zig");
const StreamingReader = @import("streaming_reader.zig").StreamingReader;
const StreamingWalker = files.StreamingWalker;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    if (argv.len > 1) {
        const first_arg = argv[1];
        if (std.mem.eql(u8, first_arg, "fd")) {
            var arg_iter = SliceIterator{ .slice = argv[2..] };
            return fd_main.run(allocator, io, &arg_iter);
        } else if (std.mem.eql(u8, first_arg, "fzf")) {
            const args = fzf.Args.parseFromSlice(argv[2..]) catch |err| switch (err) {
                error.UnknownOption => std.process.exit(2),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return runFzf(allocator, io, init.environ_map, args);
        }
    }

    const args = fzf.Args.parseFromSlice(argv[1..]) catch |err| switch (err) {
        error.UnknownOption => std.process.exit(2),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return runFzf(allocator, io, init.environ_map, args);
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
fn runFzf(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, args: fzf.Args) !void {
    if (args.help) {
        fzf.printHelp(io);
        return;
    }

    if (args.version) {
        fzf.printVersion(io);
        return;
    }

    const stdin_is_tty = fzf.isStdinTty(io);

    if (args.filter != null) {
        const input = if (stdin_is_tty)
            try fzf.getDefaultSource(allocator, io, environ_map)
        else
            try readStdinAll(allocator, io);
        defer allocator.free(input);

        try fzf.runFilter(allocator, io, &args, input);
        return;
    }

    // Run interactive TUI
    const aborted = try if (stdin_is_tty) blk: {
        if (environ_map.get("FZF_DEFAULT_COMMAND")) |_| {
            const input = try fzf.getDefaultSource(allocator, io, environ_map);
            defer allocator.free(input);
            break :blk fzf.runTui(allocator, io, &args, input);
        } else {
            var walker = StreamingWalker.init(allocator, io, std.Io.Dir.cwd());
            defer walker.deinit();
            try walker.start();
            break :blk fzf.runTuiWithWalker(allocator, io, &args, &walker);
        }
    } else blk: {
        var reader = StreamingReader.init(allocator, io, args.delimiter, args.header_lines, args.nth, args.with_nth);
        defer reader.deinit();
        try reader.start(std.Io.File.stdin());
        break :blk fzf.runTuiStreaming(allocator, io, &args, &reader);
    };

    if (aborted) {
        std.process.exit(130);
    }
}

fn readStdinAll(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [64 * 1024]u8 = undefined;
    var sr = std.Io.File.stdin().readerStreaming(io, &buf);
    return try sr.interface.allocRemaining(allocator, .unlimited);
}
