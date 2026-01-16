//! nom - A fuzzy finder CLI compatible with fzf
//!
//! Usage: nom [options]
//!
//! Options are largely compatible with fzf.

const std = @import("std");
const fzf = @import("fzf.zig");

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

    // Get input: use FZF_DEFAULT_COMMAND or walker if stdin is TTY
    const input = if (fzf.isStdinTty())
        try fzf.getDefaultSource(allocator)
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(input);

    if (args.filter != null) {
        try fzf.runFilter(allocator, &args, input);
        return;
    }

    // Run interactive TUI
    const aborted = fzf.runTui(allocator, &args, input) catch |err| {
        return err;
    };

    if (aborted) {
        std.process.exit(130);
    }
}
