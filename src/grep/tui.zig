//! Grep-specific interactive picker.
//!
//! Items are 2-line records (path + source line). The user types a literal
//! needle directly into the prompt; the TUI debounces query changes and
//! drives a `WalkerSession` (cancel + restart with new needle) instead of
//! filtering a static set of matches. Below the 3-character threshold we
//! cancel the active walker and show an empty-state prompt.
//!
//! Up/Down move by item, Enter returns a `Selection`, Esc / Ctrl-C aborts.
//!
//! This is *not* a generic TUI — it's purpose-built for grep matches and
//! intentionally narrower than `src/tui.zig`.

const std = @import("std");

const Terminal = @import("../term.zig").Terminal;
const input = @import("../input.zig");
const CaseMatching = @import("../pattern.zig").CaseMatching;
const match_list = @import("match_list.zig");
const grep = @import("grep.zig");

/// Returned to the caller when the user accepts a match.
pub const Selection = struct {
    path: []u8,
    line_no: u32,
    col: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Selection) void {
        self.allocator.free(self.path);
    }
};

pub const Options = struct {
    case_matching: CaseMatching = .smart,
    /// Hint shown above the query line when no walker is active (query
    /// hasn't crossed the min-length threshold).
    empty_prompt: []const u8 = "type ≥3 chars to search",
    /// Minimum query length before the walker is started.
    min_query_len: usize = 3,
    /// Wait this many milliseconds of input quiet before restarting the
    /// walker on a query change. Avoids thrashing on rapid keystrokes.
    debounce_ms: u64 = 150,
};

const MAX_RESULTS: usize = 5000;
const ITEM_LINES: u16 = 2;
/// Min interval between full redraws while results stream in. Without
/// this cap, a fast walker can easily push the TUI past 1000 redraws/sec
/// and starve keystroke handling.
const FRAME_INTERVAL_MS: u64 = 33; // ~30 fps

const C = struct {
    const reset = "\x1b[0m";
    const path = "\x1b[35m"; // magenta
    const line_no = "\x1b[32m"; // green
    const match = "\x1b[1;31m"; // bold red
    const dim = "\x1b[2m";
    const reverse = "\x1b[7m";
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *grep.WalkerSession,
    opts: Options,
) !?Selection {
    var term = try Terminal.init(io);
    defer term.deinit(io);

    try term.enterAltScreen();
    try term.hideCursor();
    defer {
        term.showCursor() catch {};
        term.leaveAltScreen() catch {};
    }

    var query: std.ArrayListUnmanaged(u8) = .empty;
    defer query.deinit(allocator);

    // Needle currently driving the active walker. Empty if no walker.
    var active_needle: std.ArrayListUnmanaged(u8) = .empty;
    defer active_needle.deinit(allocator);

    var current_list: ?*match_list.MatchList = null; // borrowed from session

    var selected: usize = 0;
    var scroll_offset: usize = 0;
    // Result count already reflected in the rendered frame.
    var rendered_count: usize = 0;

    var query_dirty = false; // query changed; debounce timer ticking
    var last_query_change: std.Io.Timestamp = .zero;
    const debounce_ns: i96 = @intCast(opts.debounce_ms * std.time.ns_per_ms);
    const frame_interval_ns: i96 = @intCast(FRAME_INTERVAL_MS * std.time.ns_per_ms);
    var last_draw: std.Io.Timestamp = .zero;
    var needs_redraw = true;

    var reader: input.InputReader = .{};

    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);

        // 1. Maybe (re)start the walker, debounced.
        if (query_dirty and last_query_change.durationTo(now).nanoseconds >= debounce_ns) {
            query_dirty = false;
            try syncWalker(allocator, session, query.items, &active_needle, &current_list, opts.min_query_len);
            // Walker just changed; reset selection/scroll.
            selected = 0;
            scroll_offset = 0;
            rendered_count = 0;
            needs_redraw = true;
        }

        // 2. Pick up new items from the active walker. New items only
        // matter for redraw — there's no per-keystroke filter pass to
        // re-run, the walker already constrains results to the needle.
        if (current_list) |list| {
            const cur = list.snapshotLen();
            if (cur != rendered_count) needs_redraw = true;
        }

        // 3. Draw, but at most once per frame interval. This keeps the
        // event loop responsive when matches stream in faster than we
        // can render (and faster than the user would notice).
        if (needs_redraw and last_draw.durationTo(now).nanoseconds >= frame_interval_ns) {
            const total = if (current_list) |list| list.snapshotLen() else 0;
            const visible = @min(total, MAX_RESULTS);
            if (selected >= visible) selected = if (visible == 0) 0 else visible - 1;
            try draw(&term, current_list, visible, query.items, active_needle.items.len, selected, &scroll_offset, opts);
            rendered_count = total;
            last_draw = now;
            needs_redraw = false;
        }

        // 4. Drain pending input events before sleeping. The first read
        // blocks up to 16ms (so we wake periodically to pick up streamed
        // matches even when the user isn't typing); subsequent reads
        // within the same iteration use a 0ms timeout so a burst of
        // keystrokes (paste, fast typing) all advance state before we
        // redraw.
        var first_read = true;
        drain: while (true) {
            const ev_timeout: u64 = if (first_read) 16 * std.time.ns_per_ms else 0;
            first_read = false;
            const event = reader.readEventWithTimeout(&term, ev_timeout);
            switch (event) {
                .none => break :drain,
                .resize => {
                    term.updateSize();
                    needs_redraw = true;
                },
                .mouse => {},
                .key => |ke| switch (ke.key) {
                    .escape => return null,
                    .char => |c| {
                        if (ke.modifiers.ctrl) {
                            switch (c) {
                                'c', 'C', 'g', 'G' => return null,
                                'p', 'P' => {
                                    if (selected > 0) {
                                        selected -= 1;
                                        needs_redraw = true;
                                    }
                                },
                                'n', 'N' => {
                                    if (selected + 1 < currentVisibleCount(current_list)) {
                                        selected += 1;
                                        needs_redraw = true;
                                    }
                                },
                                'u', 'U' => {
                                    query.clearRetainingCapacity();
                                    query_dirty = true;
                                    last_query_change = now;
                                    needs_redraw = true;
                                },
                                'w', 'W' => {
                                    deleteWord(&query);
                                    query_dirty = true;
                                    last_query_change = now;
                                    needs_redraw = true;
                                },
                                else => {},
                            }
                        } else if (c < 0x80) {
                            try query.append(allocator, @intCast(c));
                            query_dirty = true;
                            last_query_change = now;
                            needs_redraw = true;
                        } else {
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(@intCast(c), &buf) catch continue :drain;
                            try query.appendSlice(allocator, buf[0..n]);
                            query_dirty = true;
                            last_query_change = now;
                            needs_redraw = true;
                        }
                    },
                    .backspace => {
                        if (query.items.len > 0) {
                            var i = query.items.len;
                            while (i > 0) {
                                i -= 1;
                                if (query.items[i] & 0xC0 != 0x80) break;
                            }
                            query.items.len = i;
                            query_dirty = true;
                            last_query_change = now;
                            needs_redraw = true;
                        }
                    },
                    .up => if (selected > 0) {
                        selected -= 1;
                        needs_redraw = true;
                    },
                    .down => if (selected + 1 < currentVisibleCount(current_list)) {
                        selected += 1;
                        needs_redraw = true;
                    },
                    .page_up => {
                        const step = pageStep(term.height);
                        selected = if (selected > step) selected - step else 0;
                        needs_redraw = true;
                    },
                    .page_down => {
                        const step = pageStep(term.height);
                        const total = currentVisibleCount(current_list);
                        selected += step;
                        if (selected >= total) selected = if (total == 0) 0 else total - 1;
                        needs_redraw = true;
                    },
                    .enter => {
                        const list = current_list orelse continue :drain;
                        const total = @min(list.snapshotLen(), MAX_RESULTS);
                        if (total == 0 or selected >= total) continue :drain;
                        const items = list.snapshotItems(list.snapshotLen());
                        const it = items[selected];
                        return Selection{
                            .path = try allocator.dupe(u8, it.path),
                            .line_no = it.line_no,
                            .col = if (it.cols.len > 0) it.cols[0] else 1,
                            .allocator = allocator,
                        };
                    },
                    else => {},
                },
            }
        }
    }
}

/// Reconcile the active walker with the current query. Three transitions:
///
/// - query too short (< min): cancel any active walker, clear `current_list`.
/// - query ≥ min and differs from `active_needle`: cancel + restart.
/// - query ≥ min and matches `active_needle`: no-op.
fn syncWalker(
    allocator: std.mem.Allocator,
    session: *grep.WalkerSession,
    query: []const u8,
    active_needle: *std.ArrayListUnmanaged(u8),
    current_list: *?*match_list.MatchList,
    min_len: usize,
) !void {
    if (query.len < min_len) {
        if (current_list.* != null) {
            session.cancel();
            current_list.* = null;
            active_needle.clearRetainingCapacity();
        }
        return;
    }

    if (std.mem.eql(u8, active_needle.items, query)) return;

    current_list.* = try session.start(query);
    active_needle.clearRetainingCapacity();
    try active_needle.appendSlice(allocator, query);
}

fn currentVisibleCount(current_list: ?*match_list.MatchList) usize {
    const list = current_list orelse return 0;
    return @min(list.snapshotLen(), MAX_RESULTS);
}

fn pageStep(height: u16) usize {
    const usable = if (height > 4) height - 3 else 1;
    return @max(1, usable / ITEM_LINES);
}

fn deleteWord(q: *std.ArrayListUnmanaged(u8)) void {
    while (q.items.len > 0 and std.ascii.isWhitespace(q.items[q.items.len - 1])) {
        q.items.len -= 1;
    }
    while (q.items.len > 0 and !std.ascii.isWhitespace(q.items[q.items.len - 1])) {
        q.items.len -= 1;
    }
}

fn draw(
    term: *Terminal,
    current_list: ?*match_list.MatchList,
    visible_count: usize,
    query: []const u8,
    needle_len: usize,
    selected: usize,
    scroll_offset: *usize,
    opts: Options,
) !void {
    const w = term.width;
    const h = term.height;
    if (h < 4 or w < 10) {
        try term.moveTo(1, 1);
        try term.clearScreen();
        return;
    }

    // Layout: rows 1..h-2 = list, h-1 = info, h = prompt.
    const list_rows = h - 2;
    const items_visible = list_rows / ITEM_LINES;
    if (items_visible == 0) return;

    if (selected < scroll_offset.*) {
        scroll_offset.* = selected;
    } else if (selected >= scroll_offset.* + items_visible) {
        scroll_offset.* = selected + 1 - items_visible;
    }

    try term.moveTo(1, 1);
    try term.clearScreen();

    if (current_list == null) {
        // Below threshold — hint sits one row above the prompt.
        try term.moveTo(h - 1, 3);
        try term.write(C.dim);
        try term.write(opts.empty_prompt);
        try term.write(C.reset);
    } else {
        const list = current_list.?;
        const items = list.snapshotItems(list.snapshotLen());

        var screen_row: u16 = 1;
        var i: usize = scroll_offset.*;
        var drawn: u16 = 0;
        while (drawn < items_visible and i < visible_count) : ({
            i += 1;
            drawn += 1;
            screen_row += ITEM_LINES;
        }) {
            if (i >= items.len) break;
            const it = items[i];
            const is_current = (i == selected);
            try drawItem(term, screen_row, w, it, needle_len, is_current);
        }

        // Info line — only when a walker is active.
        try term.moveTo(h - 1, 1);
        try term.clearLine();
        const total = items.len;
        if (list.isDone()) {
            try term.print("  {d}", .{total});
        } else {
            try term.print("  {d} (searching…)", .{total});
        }
    }

    // Prompt.
    try term.moveTo(h, 1);
    try term.clearLine();
    try term.write("> ");
    try term.write(query);
    term.flush();
}

fn drawItem(
    term: *Terminal,
    row: u16,
    width: u16,
    it: match_list.Item,
    needle_len: usize,
    is_current: bool,
) !void {
    if (is_current) {
        try term.moveTo(row, 1);
        try term.write(C.reverse);
        try term.write("> ");
    } else {
        try term.moveTo(row, 1);
        try term.write("  ");
    }
    try term.write(C.path);
    try writeTrunc(term, it.path, width -| 2);
    try term.write(C.reset);
    if (is_current) try term.write(C.reset);

    try term.moveTo(row + 1, 1);
    if (is_current) try term.write(C.reverse);
    try term.write("    ");
    try term.write(C.line_no);
    try term.print("{d:>5}", .{it.line_no});
    try term.write(C.reset);
    if (is_current) try term.write(C.reverse);
    try term.write("  ");

    const remaining: i32 = @as(i32, @intCast(width)) - 4 - 5 - 2;
    if (remaining > 0) {
        try writeHighlightedSource(term, it.line_text, it.cols, needle_len, @intCast(remaining));
    }
    if (is_current) try term.write(C.reset);
}

fn writeTrunc(term: *Terminal, s: []const u8, max_w: u16) !void {
    if (s.len <= max_w) {
        try term.write(s);
    } else if (max_w > 1) {
        try term.write(s[0 .. max_w - 1]);
        try term.write("…");
    }
}

fn writeHighlightedSource(
    term: *Terminal,
    text: []const u8,
    cols: []const u32,
    needle_len: usize,
    max_w: u16,
) !void {
    const n = @min(text.len, max_w);
    const view = text[0..n];

    if (needle_len == 0 or cols.len == 0) {
        try term.write(view);
        return;
    }

    var cursor: usize = 0;
    for (cols) |col_1based| {
        const start: usize = @intCast(col_1based - 1);
        if (start >= view.len) break;
        const end: usize = @min(start + needle_len, view.len);
        if (start < cursor) continue;
        try term.write(view[cursor..start]);
        try term.write(C.match);
        try term.write(view[start..end]);
        try term.write(C.reset);
        cursor = end;
    }
    if (cursor < view.len) try term.write(view[cursor..]);
}
