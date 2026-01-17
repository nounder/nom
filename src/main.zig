//! nom - A fuzzy finder CLI compatible with fzf
//!
//! Usage: nom [options]
//!
//! Options are largely compatible with fzf.

const std = @import("std");
const fzf = @import("fzf.zig");
const StreamingReader = @import("streaming_reader.zig").StreamingReader;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parsed = try fzf.Args.parse(allocator);
    defer parsed.deinit();
    const args = parsed.args;

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
        const input = try fzf.getDefaultSource(allocator);
        defer allocator.free(input);
        break :blk fzf.runTui(allocator, &args, input);
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
