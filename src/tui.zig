//! Interactive TUI for fuzzy finder.
//!
//! This module provides the interactive fuzzy finder interface with:
//! - Real-time search as you type
//! - Match highlighting
//! - Multi-select support
//! - Preview window
//! - Keybindings

const std = @import("std");
const Allocator = std.mem.Allocator;

const Terminal = @import("term.zig").Terminal;
const Color = @import("term.zig").Color;
const input = @import("input.zig");
const Event = input.Event;
const Key = input.Key;
const InputReader = input.InputReader;
const chunk = @import("chunklist.zig");
const StreamingReader = @import("streaming_reader.zig").StreamingReader;
const ParsedNth = @import("streaming_reader.zig").ParsedNth;
const TopKHeap = @import("topk.zig").TopKHeap;

const nom = @import("root.zig");
const Matcher = nom.Matcher;
const Pattern = nom.Pattern;
const Utf32Str = nom.Utf32Str;
const CaseMatching = nom.CaseMatching;
const Normalization = nom.Normalization;

/// Check if a Key is a specific character
fn isChar(key: Key, ch: u21) bool {
    return switch (key) {
        .char => |c| c == ch,
        else => false,
    };
}

/// Configuration for the TUI
pub const TuiConfig = struct {
    prompt: []const u8 = "> ",
    pointer: []const u8 = ">",
    marker: []const u8 = ">",
    header: ?[]const u8 = null,
    header_lines: usize = 0,
    multi: bool = false,
    reverse: bool = false,
    no_mouse: bool = false,
    ansi: bool = true,
    case_matching: CaseMatching = .smart,
    exact: bool = false,
    delimiter: u8 = '\n',
    nth: ?[]const u8 = null,
    with_nth: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    preview_window: PreviewWindow = .{},
    fullscreen: bool = false, // Use alternate screen buffer
    height: ?u16 = null, // Height in lines (null = use terminal height)
};

/// Preview window configuration
pub const PreviewWindow = struct {
    position: Position = .right,
    size: u16 = 50, // percentage
    border: bool = true,
    wrap: bool = false,
    hidden: bool = false,

    pub const Position = enum { up, down, left, right };

    pub fn parse(spec: []const u8) PreviewWindow {
        var pw = PreviewWindow{};
        var it = std.mem.splitScalar(u8, spec, ':');
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "up")) {
                pw.position = .up;
            } else if (std.mem.eql(u8, part, "down")) {
                pw.position = .down;
            } else if (std.mem.eql(u8, part, "left")) {
                pw.position = .left;
            } else if (std.mem.eql(u8, part, "right")) {
                pw.position = .right;
            } else if (std.mem.eql(u8, part, "wrap")) {
                pw.wrap = true;
            } else if (std.mem.eql(u8, part, "nowrap")) {
                pw.wrap = false;
            } else if (std.mem.eql(u8, part, "border")) {
                pw.border = true;
            } else if (std.mem.eql(u8, part, "noborder")) {
                pw.border = false;
            } else if (std.mem.eql(u8, part, "hidden")) {
                pw.hidden = true;
            } else if (std.mem.endsWith(u8, part, "%")) {
                pw.size = std.fmt.parseInt(u16, part[0 .. part.len - 1], 10) catch 50;
            } else if (part.len > 0 and part[0] >= '0' and part[0] <= '9') {
                pw.size = std.fmt.parseInt(u16, part, 10) catch 50;
            }
        }
        return pw;
    }
};

/// Result from the TUI
pub const TuiResult = struct {
    allocator: Allocator,
    selected: std.ArrayList([]const u8),
    query: []const u8,
    aborted: bool,

    pub fn deinit(self: *TuiResult) void {
        self.selected.deinit(self.allocator);
        self.allocator.free(self.query);
    }
};

/// Item with match data
const Item = struct {
    item: *const chunk.ChunkItem,
    score: u32,
    indices: []const u32,
    selected: bool = false,
};

const SearchResult = struct {
    item: *const chunk.ChunkItem,
    score: u32,
    indices: []const u32,
    selected: bool = false,
};

const MAX_RESULTS: usize = 2000;

fn buildChunkFromLines(
    allocator: Allocator,
    lines: []const []const u8,
    start_id: usize,
    nth: *ParsedNth,
    with_nth: *ParsedNth,
) !struct { chunk: chunk.Chunk, next_id: usize } {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var items = try allocator.alloc(chunk.ChunkItem, lines.len);
    var next = start_id;

    for (lines, 0..) |line, i| {
        const match_text = try nth.apply(arena.allocator(), line);
        const display_text = try with_nth.apply(arena.allocator(), line);

        items[i] = .{
            .id = next,
            .display = display_text,
            .match_text = match_text,
            .original = line,
        };
        next += 1;
    }

    return .{
        .chunk = .{
            .items = items,
            .data = &.{}, // Owned by caller (input buffer), not freed here
            .arena = arena,
        },
        .next_id = next,
    };
}

/// The interactive TUI
pub const Tui = struct {
    allocator: Allocator,
    term: Terminal,
    reader: InputReader,
    config: TuiConfig,

    // Input data
    chunk_list: chunk.ChunkList,
    items: std.ArrayList(*const chunk.ChunkItem),
    header_items: std.ArrayList(*const chunk.ChunkItem),
    stream_reader: ?*StreamingReader,
    loading: bool,
    total_loaded: usize,

    // Matcher
    matcher: Matcher,

    // Search state
    query: std.ArrayList(u8),
    cursor_pos: usize,

    // Results
    matched_items: std.ArrayList(Item),
    indices_buf: std.ArrayList(u32),
    showing_all: bool, // When true, render directly from items (no query)

    // Display state
    scroll_offset: usize,
    selected_idx: usize,
    visible_count: usize,

    // Selection (for multi-select)
    selections: std.AutoHashMap(usize, void),

    // Preview
    preview_cmd: ?[]const u8,
    preview_visible: bool,
    preview_width: u16,

    // Running state
    needs_redraw: bool,
    needs_search: bool,
    last_search_time: i64, // Throttle rapid searches during streaming
    search_throttle_ms: i64 = 50, // Min time between searches (fzf uses ~50ms)

    // For inline mode cleanup
    start_row: u16,
    lines_used: u16,

    pub fn init(
        allocator: Allocator,
        items: []const []const u8,
        config: TuiConfig,
        stream_reader: ?*StreamingReader,
    ) !Tui {
        var term = try Terminal.init();
        errdefer term.deinit();

        var matcher = try Matcher.initDefault(allocator);
        errdefer matcher.deinit();

        // Configure matcher based on config
        if (config.case_matching == .ignore) {
            matcher.config.ignore_case = true;
        } else if (config.case_matching == .respect) {
            matcher.config.ignore_case = false;
        }

        var chunk_list = chunk.ChunkList.init(allocator);
        errdefer chunk_list.deinit();

        var item_list = std.ArrayList(*const chunk.ChunkItem){};
        errdefer item_list.deinit(allocator);

        var header_list = std.ArrayList(*const chunk.ChunkItem){};
        errdefer header_list.deinit(allocator);

        // Build initial chunk for static items
        if (items.len > 0) {
            var nth_parser = try ParsedNth.init(allocator, config.nth);
            defer nth_parser.deinit();
            var with_nth_parser = try ParsedNth.init(allocator, config.with_nth);
            defer with_nth_parser.deinit();

            const built = try buildChunkFromLines(allocator, items, 0, &nth_parser, &with_nth_parser);
            try chunk_list.appendChunk(built.chunk);

            for (built.chunk.items) |*it| {
                if (it.id < config.header_lines) {
                    try header_list.append(allocator, it);
                } else {
                    try item_list.append(allocator, it);
                }
            }
        }

        return Tui{
            .allocator = allocator,
            .term = term,
            .reader = .{},
            .config = config,
            .chunk_list = chunk_list,
            .items = item_list,
            .header_items = header_list,
            .stream_reader = stream_reader,
            .loading = stream_reader != null,
            .total_loaded = chunk_list.total_count,
            .matcher = matcher,
            .query = .empty,
            .cursor_pos = 0,
            .matched_items = .empty,
            .indices_buf = .empty,
            .showing_all = true,
            .scroll_offset = 0,
            .selected_idx = 0,
            .visible_count = 0,
            .selections = std.AutoHashMap(usize, void).init(allocator),
            .preview_cmd = null,
            .preview_visible = false,
            .preview_width = 0,
            .needs_redraw = true,
            .needs_search = true,
            .last_search_time = 0,
            .start_row = 1,
            .lines_used = 0,
        };
    }

    pub fn deinit(self: *Tui) void {
        // Restore terminal
        self.term.showCursor() catch {};
        self.term.resetStyle() catch {};
        self.term.disableMouse() catch {};
        self.term.deinit();

        // Free resources
        for (self.matched_items.items) |item| {
            if (item.indices.len > 0) {
                self.allocator.free(@constCast(item.indices));
            }
        }
        self.matched_items.deinit(self.allocator);
        self.indices_buf.deinit(self.allocator);
        self.query.deinit(self.allocator);
        self.selections.deinit();
        self.items.deinit(self.allocator);
        self.header_items.deinit(self.allocator);
        self.chunk_list.deinit();
        self.matcher.deinit();
    }

    /// Set initial query
    pub fn setQuery(self: *Tui, q: []const u8) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, q);
        self.cursor_pos = q.len;
        self.needs_search = true;
    }

    /// Set preview command
    pub fn setPreview(self: *Tui, cmd: []const u8, width: u16) void {
        self.preview_cmd = cmd;
        self.preview_visible = true;
        self.preview_width = width;
    }

    /// Run the interactive finder
    pub fn run(self: *Tui) !TuiResult {
        // Setup terminal
        if (self.config.fullscreen) {
            // Fullscreen mode: use alternate screen buffer
            try self.term.enterAltScreen();
            self.start_row = 1;
        } else {
            // Inline mode: get current cursor position and draw below
            if (self.term.getCursorPos()) |pos| {
                self.start_row = pos.row;
            } else {
                // Fallback: assume we're near the bottom
                self.start_row = self.term.height;
            }
            // Make room by scrolling if needed
            const needed_lines = self.calculateNeededLines();
            const available = self.term.height - self.start_row + 1;
            if (needed_lines > available) {
                // Scroll up to make room
                const scroll_amount = needed_lines - available;
                var i: u16 = 0;
                while (i < scroll_amount) : (i += 1) {
                    try self.term.write("\n");
                }
                self.start_row -|= scroll_amount;
            }
        }

        try self.term.hideCursor();
        if (!self.config.no_mouse) {
            try self.term.enableMouse();
        }

        // Start in "loading" mode when streaming; initial draw happens before any search.
        self.loading = if (self.stream_reader) |r| !r.isDone() else false;
        self.total_loaded = self.chunk_list.total_count;
        self.needs_redraw = true;
        try self.draw();

        // Main loop
        while (true) {
            try self.pollStream();

            // Throttle searches during rapid input - prevents blocking on large streaming datasets
            if (self.needs_search and self.shouldPerformSearch()) {
                try self.performSearch();
                self.updateLastSearchTime();
                self.needs_search = false;
                self.needs_redraw = true;
            }

            if (self.needs_redraw) {
                try self.draw();
                self.needs_redraw = false;
            }

            const event = self.reader.readEventWithTimeout(&self.term, 10 * std.time.ns_per_ms);
            const action = try self.handleEvent(event);

            switch (action) {
                .none => {},
                .quit => {
                    try self.clearDisplay();
                    return .{
                        .allocator = self.allocator,
                        .selected = .empty,
                        .query = try self.allocator.dupe(u8, self.query.items),
                        .aborted = true,
                    };
                },
                .accept => {
                    try self.clearDisplay();
                    return try self.buildResult();
                },
                .accept_all => {
                    try self.clearDisplay();
                    return try self.buildResultAll();
                },
            }
        }
    }

    fn pollStream(self: *Tui) !void {
        const reader = self.stream_reader orelse return;

        const prev_loading = self.loading;

        while (reader.pollChunk()) |c| {
            try self.addChunk(c);
        }

        self.loading = !reader.isDone();
        self.total_loaded = self.chunk_list.total_count;
        if (self.loading != prev_loading) {
            self.needs_redraw = true;
        }
        try reader.checkError();
    }

    fn addChunk(self: *Tui, c: chunk.Chunk) !void {
        try self.chunk_list.appendChunk(c);

        for (c.items) |*it| {
            if (it.id < self.config.header_lines) {
                try self.header_items.append(self.allocator, it);
            } else {
                try self.items.append(self.allocator, it);
            }
        }

        self.total_loaded = self.chunk_list.total_count;

        // Only trigger search if we have an active query
        // When showing_all (empty query), new items are displayed directly - no search needed
        if (!self.showing_all) {
            self.needs_search = true;
        }
        self.needs_redraw = true;
    }

    const Action = enum {
        none,
        quit,
        accept,
        accept_all,
    };

    fn handleEvent(self: *Tui, event: Event) !Action {
        switch (event) {
            .key => |k| {
                // Handle Ctrl+C, Ctrl+G, Escape
                if (k.modifiers.ctrl) {
                    if (isChar(k.key, 'c')) return .quit;
                    if (isChar(k.key, 'g')) return .quit;
                }
                if (k.key == .escape) {
                    return .quit;
                }

                // Handle Enter
                if (k.key == .enter) {
                    return .accept;
                }

                // Handle Ctrl+A (accept all in multi mode)
                if (k.modifiers.ctrl and isChar(k.key, 'a') and self.config.multi) {
                    return .accept_all;
                }

                // Navigation
                if (k.key == .up or (k.modifiers.ctrl and isChar(k.key, 'p')) or
                    (k.modifiers.ctrl and isChar(k.key, 'k')))
                {
                    self.moveUp();
                    return .none;
                }
                if (k.key == .down or (k.modifiers.ctrl and isChar(k.key, 'n')) or
                    (k.modifiers.ctrl and isChar(k.key, 'j')))
                {
                    self.moveDown();
                    return .none;
                }
                if (k.key == .page_up or (k.modifiers.alt and isChar(k.key, 'v'))) {
                    self.pageUp();
                    return .none;
                }
                if (k.key == .page_down or (k.modifiers.ctrl and isChar(k.key, 'v'))) {
                    self.pageDown();
                    return .none;
                }
                if (k.modifiers.ctrl and k.key == .home) {
                    self.scrollToTop();
                    return .none;
                }
                if (k.modifiers.ctrl and k.key == .end) {
                    self.scrollToBottom();
                    return .none;
                }

                // Toggle selection (Tab)
                if (k.key == .tab and self.config.multi) {
                    self.toggleSelection();
                    self.moveDown();
                    return .none;
                }
                if (k.key == .backtab and self.config.multi) {
                    self.moveUp();
                    self.toggleSelection();
                    return .none;
                }

                // Cursor movement in query
                if (k.key == .left or (k.modifiers.ctrl and isChar(k.key, 'b'))) {
                    if (self.cursor_pos > 0) {
                        self.cursor_pos -= 1;
                        self.needs_redraw = true;
                    }
                    return .none;
                }
                if (k.key == .right or (k.modifiers.ctrl and isChar(k.key, 'f'))) {
                    if (self.cursor_pos < self.query.items.len) {
                        self.cursor_pos += 1;
                        self.needs_redraw = true;
                    }
                    return .none;
                }
                if (k.key == .home or (k.modifiers.ctrl and isChar(k.key, 'a'))) {
                    self.cursor_pos = 0;
                    self.needs_redraw = true;
                    return .none;
                }
                if (k.key == .end or (k.modifiers.ctrl and isChar(k.key, 'e'))) {
                    self.cursor_pos = self.query.items.len;
                    self.needs_redraw = true;
                    return .none;
                }

                // Editing
                if (k.key == .backspace or (k.modifiers.ctrl and isChar(k.key, 'h'))) {
                    if (self.cursor_pos > 0) {
                        _ = self.query.orderedRemove(self.cursor_pos - 1);
                        self.cursor_pos -= 1;
                        self.needs_search = true;
                    }
                    return .none;
                }
                if (k.key == .delete) {
                    if (self.cursor_pos < self.query.items.len) {
                        _ = self.query.orderedRemove(self.cursor_pos);
                        self.needs_search = true;
                    }
                    return .none;
                }
                if (k.modifiers.ctrl and isChar(k.key, 'u')) {
                    // Clear to beginning
                    const remaining = self.query.items[self.cursor_pos..];
                    self.query.clearRetainingCapacity();
                    self.query.appendSlice(self.allocator, remaining) catch {};
                    self.cursor_pos = 0;
                    self.needs_search = true;
                    return .none;
                }
                if (k.modifiers.ctrl and isChar(k.key, 'w')) {
                    // Delete word backwards
                    try self.deleteWordBackward();
                    return .none;
                }

                // Character input - check if it's a char variant
                switch (k.key) {
                    .char => |ch| {
                        if (ch < 128 and !k.modifiers.ctrl and !k.modifiers.alt) {
                            self.query.insert(self.allocator, self.cursor_pos, @truncate(ch)) catch {};
                            self.cursor_pos += 1;
                            self.needs_search = true;
                        }
                    },
                    else => {},
                }
                return .none;
            },
            .mouse => |m| {
                switch (m.kind) {
                    .press => {
                        if (m.button == .left) {
                            // Click to select
                            const clicked_row = self.getClickedItemIndex(m.row);
                            if (clicked_row) |idx| {
                                self.selected_idx = idx;
                                self.needs_redraw = true;
                            }
                        } else if (m.button == .scroll_up) {
                            self.moveUp();
                        } else if (m.button == .scroll_down) {
                            self.moveDown();
                        }
                    },
                    else => {},
                }
            },
            .resize => |r| {
                self.term.width = r.width;
                self.term.height = r.height;
                self.needs_redraw = true;
            },
            .none => {},
        }
        return .none;
    }

    fn deleteWordBackward(self: *Tui) !void {
        if (self.cursor_pos == 0) return;

        var end = self.cursor_pos;
        // Skip trailing spaces
        while (end > 0 and self.query.items[end - 1] == ' ') {
            end -= 1;
        }
        // Delete word
        while (end > 0 and self.query.items[end - 1] != ' ') {
            end -= 1;
        }

        const to_delete = self.cursor_pos - end;
        var i: usize = 0;
        while (i < to_delete) : (i += 1) {
            _ = self.query.orderedRemove(end);
        }
        self.cursor_pos = end;
        self.needs_search = true;
    }

    /// Get the count of displayable results (virtual or filtered)
    fn getResultCount(self: *Tui) usize {
        return if (self.showing_all) self.items.items.len else self.matched_items.items.len;
    }

    /// Check if enough time has passed to perform a search (throttle rapid searches)
    fn shouldPerformSearch(self: *Tui) bool {
        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_search_time;
        return elapsed >= self.search_throttle_ms;
    }

    /// Update last search time
    fn updateLastSearchTime(self: *Tui) void {
        self.last_search_time = std.time.milliTimestamp();
    }

    /// Get item info at index for rendering (works in both modes)
    const DisplayItem = struct {
        display: []const u8,
        indices: []const u32,
        selected: bool,
    };

    fn getDisplayItem(self: *Tui, idx: usize) DisplayItem {
        if (self.showing_all) {
            const item_ptr = self.items.items[idx];
            return .{
                .display = item_ptr.display,
                .indices = &[_]u32{},
                .selected = self.selections.contains(item_ptr.id),
            };
        } else {
            const item = self.matched_items.items[idx];
            return .{
                .display = item.item.display,
                .indices = item.indices,
                .selected = item.selected,
            };
        }
    }

    fn moveUp(self: *Tui) void {
        const count = self.getResultCount();
        if (self.config.reverse) {
            if (self.selected_idx + 1 < count) {
                self.selected_idx += 1;
                self.ensureVisible();
                self.needs_redraw = true;
            }
        } else {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
                self.ensureVisible();
                self.needs_redraw = true;
            }
        }
    }

    fn moveDown(self: *Tui) void {
        const count = self.getResultCount();
        if (self.config.reverse) {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
                self.ensureVisible();
                self.needs_redraw = true;
            }
        } else {
            if (self.selected_idx + 1 < count) {
                self.selected_idx += 1;
                self.ensureVisible();
                self.needs_redraw = true;
            }
        }
    }

    fn pageUp(self: *Tui) void {
        const count = self.getResultCount();
        const page_size = self.visible_count;
        if (self.config.reverse) {
            self.selected_idx = @min(self.selected_idx + page_size, count -| 1);
        } else {
            self.selected_idx -|= page_size;
        }
        self.ensureVisible();
        self.needs_redraw = true;
    }

    fn pageDown(self: *Tui) void {
        const count = self.getResultCount();
        const page_size = self.visible_count;
        if (self.config.reverse) {
            self.selected_idx -|= page_size;
        } else {
            self.selected_idx = @min(self.selected_idx + page_size, count -| 1);
        }
        self.ensureVisible();
        self.needs_redraw = true;
    }

    fn scrollToTop(self: *Tui) void {
        self.selected_idx = 0;
        self.scroll_offset = 0;
        self.needs_redraw = true;
    }

    fn scrollToBottom(self: *Tui) void {
        const count = self.getResultCount();
        if (count > 0) {
            self.selected_idx = count - 1;
            self.ensureVisible();
        }
        self.needs_redraw = true;
    }

    fn toggleSelection(self: *Tui) void {
        const count = self.getResultCount();
        if (count == 0) return;

        const item_id = if (self.showing_all)
            self.items.items[self.selected_idx].id
        else
            self.matched_items.items[self.selected_idx].item.id;

        if (self.selections.contains(item_id)) {
            _ = self.selections.remove(item_id);
            // Update selected flag if in matched_items mode
            if (!self.showing_all) {
                self.matched_items.items[self.selected_idx].selected = false;
            }
        } else {
            self.selections.put(item_id, {}) catch {};
            if (!self.showing_all) {
                self.matched_items.items[self.selected_idx].selected = true;
            }
        }
        self.needs_redraw = true;
    }

    fn ensureVisible(self: *Tui) void {
        const count = self.getResultCount();
        if (count == 0) return;

        if (self.selected_idx < self.scroll_offset) {
            self.scroll_offset = self.selected_idx;
        } else if (self.selected_idx >= self.scroll_offset + self.visible_count) {
            self.scroll_offset = self.selected_idx - self.visible_count + 1;
        }
    }

    fn getClickedItemIndex(self: *Tui, row: u16) ?usize {
        const count = self.getResultCount();
        const list_start: u16 = if (self.config.reverse) 1 else 2;
        const list_end = list_start + @as(u16, @truncate(self.visible_count));

        if (row < list_start or row >= list_end) return null;

        const relative_row = row - list_start;
        const idx = self.scroll_offset + relative_row;

        if (idx < count) {
            return idx;
        }
        return null;
    }

    fn performSearch(self: *Tui) !void {
        // Check for empty query first (O(1) path)
        if (self.query.items.len == 0) {
            // Free old indices before switching to show-all mode
            for (self.matched_items.items) |item| {
                if (item.indices.len > 0) {
                    self.allocator.free(@constCast(item.indices));
                }
            }
            try self.showAllItems();
            return;
        }

        // Has query - switch to filtered mode
        self.showing_all = false;

        // Free old indices
        for (self.matched_items.items) |item| {
            if (item.indices.len > 0) {
                self.allocator.free(@constCast(item.indices));
            }
        }
        self.matched_items.clearRetainingCapacity();

        const normalization: Normalization = .smart;
        var pattern = try Pattern.parse(
            self.allocator,
            self.query.items,
            self.config.case_matching,
            normalization,
        );
        defer pattern.deinit();

        var buf: std.ArrayListUnmanaged(u21) = .empty;
        defer buf.deinit(self.allocator);

        var heap = TopKHeap(SearchResult, MAX_RESULTS).init(self.allocator);
        defer heap.deinit();

        for (self.items.items) |item_ptr| {
            const haystack = Utf32Str.init(item_ptr.match_text, self.allocator, &buf);

            self.indices_buf.clearRetainingCapacity();
            if (pattern.scoreWithIndices(haystack, &self.matcher, &self.indices_buf)) |score| {
                const accept = heap.items.items.len < MAX_RESULTS or
                    (heap.items.items.len > 0 and score > heap.items.items[0].score);
                if (!accept) continue;

                const alloc_indices = self.indices_buf.items.len > 0;
                const indices_copy = if (alloc_indices)
                    try self.allocator.dupe(u32, self.indices_buf.items)
                else
                    &[_]u32{};
                errdefer if (alloc_indices) self.allocator.free(@constCast(indices_copy));
                const is_selected = self.selections.contains(item_ptr.id);

                const replaced = try heap.push(.{
                    .item = item_ptr,
                    .score = score,
                    .indices = indices_copy,
                    .selected = is_selected,
                });
                if (replaced) |old| {
                    if (old.indices.len > 0) self.allocator.free(@constCast(old.indices));
                }
            }
        }

        var results = std.ArrayList(SearchResult){};
        defer results.deinit(self.allocator);

        while (heap.pop()) |res| {
            try results.append(self.allocator, res);
        }

        std.mem.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        try self.matched_items.ensureTotalCapacity(self.allocator, results.items.len);

        for (results.items) |res| {
            try self.matched_items.append(self.allocator, .{
                .item = res.item,
                .score = res.score,
                .indices = res.indices,
                .selected = res.selected,
            });
        }

        if (self.selected_idx >= self.matched_items.items.len) {
            self.selected_idx = if (self.matched_items.items.len > 0)
                self.matched_items.items.len - 1
            else
                0;
        }
        self.scroll_offset = 0;
        self.ensureVisible();
    }

    fn showAllItems(self: *Tui) !void {
        // O(1) operation: just set flag, render directly from items
        self.showing_all = true;
        self.matched_items.clearRetainingCapacity();

        // Clamp selection to valid range
        const total = self.items.items.len;
        if (self.selected_idx >= total) {
            self.selected_idx = if (total > 0) total - 1 else 0;
        }
        self.scroll_offset = 0;
        self.ensureVisible();
    }

    fn draw(self: *Tui) !void {
        self.term.updateSize();

        // Calculate layout
        const header_height: u16 = @truncate(self.header_items.items.len);
        const prompt_height: u16 = 1;
        const info_height: u16 = 1;
        const reserved = header_height + prompt_height + info_height;

        // Calculate available height for list
        const available_height: u16 = if (self.config.fullscreen)
            self.term.height
        else blk: {
            // Inline mode: use configured height or remaining terminal space
            const max_height = self.term.height - self.start_row + 1;
            if (self.config.height) |h| {
                break :blk @min(h + reserved, max_height);
            }
            break :blk max_height;
        };

        self.visible_count = if (available_height > reserved)
            available_height - reserved
        else
            1;

        // Track total lines we use
        self.lines_used = reserved + @as(u16, @truncate(self.visible_count));

        // Start drawing from our start row
        try self.term.moveTo(self.start_row, 1);
        try self.term.clearToEnd();

        if (self.config.reverse) {
            // Prompt at top
            try self.drawPromptLine();
            try self.drawInfoLine();
            try self.drawList();
            try self.drawHeader();
        } else {
            // Prompt at bottom (fzf default style)
            // Draw from bottom up: list items from top, then info, then prompt at bottom
            try self.drawHeader();
            try self.drawListBottomUp();
            try self.drawInfoLine();
            try self.drawPromptLine();
        }

        // Position cursor in prompt
        const prompt_row: u16 = if (self.config.reverse)
            self.start_row
        else
            self.start_row + self.lines_used - 1;
        const prompt_col: u16 = @truncate(self.config.prompt.len + self.cursor_pos + 1);
        try self.term.moveTo(prompt_row, prompt_col);
        try self.term.showCursor();

        // Flush output to screen
        self.term.flush();
    }

    fn drawPromptLine(self: *Tui) !void {
        try self.term.resetStyle();
        try self.term.write(self.config.prompt);
        try self.term.write(self.query.items);
        try self.term.clearLineToEnd();
        // No \r\n - cursor will be positioned explicitly
    }

    fn drawInfoLine(self: *Tui) !void {
        try self.term.resetStyle();
        try self.term.setDim();

        var buf: [64]u8 = undefined;
        const total_items = self.items.items.len;
        const total_display = if (self.total_loaded > self.config.header_lines)
            self.total_loaded - self.config.header_lines
        else
            total_items;
        const result_count = self.getResultCount();
        const info = if (self.loading)
            std.fmt.bufPrint(&buf, "  Loading... {d}", .{self.total_loaded}) catch ""
        else
            std.fmt.bufPrint(&buf, "  {d}/{d}", .{
                result_count,
                total_display,
            }) catch "";

        if (self.config.multi and self.selections.count() > 0) {
            var buf2: [32]u8 = undefined;
            const selected_info = std.fmt.bufPrint(&buf2, " ({d})", .{self.selections.count()}) catch "";
            try self.term.write(info);
            try self.term.write(selected_info);
        } else {
            try self.term.write(info);
        }

        try self.term.clearLineToEnd();
        try self.term.resetStyle();
        try self.term.write("\r\n");
    }

    fn drawHeader(self: *Tui) !void {
        // Custom header
        if (self.config.header) |h| {
            try self.term.resetStyle();
            try self.term.setDim();
            try self.term.write("  ");
            try self.term.write(h);
            try self.term.clearLineToEnd();
            try self.term.resetStyle();
            try self.term.write("\r\n");
        }

        // Header lines from input
        for (self.header_items.items) |item_ptr| {
            try self.term.resetStyle();
            try self.term.setDim();
            try self.term.write("  ");
            const max_width = self.term.width -| 2;
            const line = item_ptr.display;
            const display_text = if (line.len > max_width) line[0..max_width] else line;
            try self.term.write(display_text);
            try self.term.clearLineToEnd();
            try self.term.resetStyle();
            try self.term.write("\r\n");
        }
    }

    fn drawList(self: *Tui) !void {
        const count = self.getResultCount();
        const end_idx = @min(self.scroll_offset + self.visible_count, count);

        var row: usize = 0;
        var idx = self.scroll_offset;
        while (idx < end_idx) : (idx += 1) {
            const item = self.getDisplayItem(idx);
            const is_current = idx == self.selected_idx;

            try self.drawDisplayItem(item, is_current);
            row += 1;
        }

        // Fill remaining rows
        while (row < self.visible_count) : (row += 1) {
            try self.term.resetStyle();
            try self.term.clearLine();
            try self.term.write("\r\n");
        }
    }

    /// Draw list in fzf-style: best match at bottom, near the prompt
    fn drawListBottomUp(self: *Tui) !void {
        const count = self.getResultCount();
        const end_idx = @min(self.scroll_offset + self.visible_count, count);
        const num_items = end_idx - self.scroll_offset;

        // First, fill empty rows at top
        var empty_rows = self.visible_count - num_items;
        while (empty_rows > 0) : (empty_rows -= 1) {
            try self.term.resetStyle();
            try self.term.clearLine();
            try self.term.write("\r\n");
        }

        // Then draw items in reverse order (last item first, so best match is at bottom)
        if (num_items > 0) {
            var i: usize = num_items;
            while (i > 0) {
                i -= 1;
                const idx = self.scroll_offset + i;
                const item = self.getDisplayItem(idx);
                const is_current = idx == self.selected_idx;
                try self.drawDisplayItem(item, is_current);
            }
        }
    }

    fn drawDisplayItem(self: *Tui, item: DisplayItem, is_current: bool) !void {
        try self.term.resetStyle();

        // Pointer/marker
        if (is_current) {
            try self.term.setBold();
            try self.term.setFg(Color.cyan);
            try self.term.write(self.config.pointer);
        } else if (item.selected) {
            try self.term.setFg(Color.magenta);
            try self.term.write(self.config.marker);
        } else {
            try self.term.write(" ");
        }

        try self.term.write(" ");

        // Text with highlighting
        const max_width = self.term.width -| 3;
        try self.drawHighlightedText(item.display, item.indices, max_width, is_current);

        try self.term.clearLineToEnd();
        try self.term.resetStyle();
        try self.term.write("\r\n");
    }

    fn drawHighlightedText(self: *Tui, text: []const u8, indices: []const u32, max_width: u16, is_current: bool) !void {
        var col: u16 = 0;
        var idx_pos: usize = 0;
        var byte_pos: usize = 0;
        var char_pos: usize = 0;

        while (byte_pos < text.len and col < max_width) {
            // Get codepoint length
            const byte = text[byte_pos];
            const cp_len: usize = if (byte < 0x80)
                1
            else if (byte < 0xE0)
                2
            else if (byte < 0xF0)
                3
            else
                4;

            const is_match = idx_pos < indices.len and indices[idx_pos] == char_pos;

            if (is_match) {
                try self.term.setBold();
                try self.term.setFg(Color.green);
                idx_pos += 1;
            } else if (is_current) {
                try self.term.resetStyle();
                try self.term.setBold();
            } else {
                try self.term.resetStyle();
            }

            // Write character
            const end = @min(byte_pos + cp_len, text.len);
            try self.term.write(text[byte_pos..end]);

            byte_pos = end;
            char_pos += 1;
            col += 1;
        }

        // Truncation indicator
        if (byte_pos < text.len) {
            try self.term.resetStyle();
            try self.term.setDim();
            try self.term.write("…");
        }
    }

    fn clearDisplay(self: *Tui) !void {
        try self.term.resetStyle();

        if (self.config.fullscreen) {
            // Fullscreen mode: leave alternate screen buffer
            try self.term.showCursor();
            try self.term.leaveAltScreen();
        } else {
            // Inline mode: move to start position and clear only the lines we used
            try self.term.moveTo(self.start_row, 1);
            try self.term.clearToEnd(); // Clear from cursor to end of screen
            try self.term.showCursor();
        }
    }

    /// Calculate how many lines the TUI needs
    fn calculateNeededLines(self: *Tui) u16 {
        const header_height: u16 = @truncate(self.header_items.items.len);
        const prompt_height: u16 = 1;
        const info_height: u16 = 1;

        // Use configured height or default to reasonable size
        const list_height: u16 = if (self.config.height) |h| h else 10;

        return header_height + prompt_height + info_height + list_height;
    }

    fn buildResult(self: *Tui) !TuiResult {
        var result = TuiResult{
            .allocator = self.allocator,
            .selected = .empty,
            .query = try self.allocator.dupe(u8, self.query.items),
            .aborted = false,
        };

        if (self.config.multi and self.selections.count() > 0) {
            // Return all selections
            var it = self.selections.keyIterator();
            while (it.next()) |id_ptr| {
                if (self.findItemById(id_ptr.*)) |item_ptr| {
                    try result.selected.append(self.allocator, item_ptr.original);
                }
            }
        } else {
            const count = self.getResultCount();
            if (count > 0) {
                // Return current item (handle both showing_all and filtered modes)
                const original = if (self.showing_all)
                    self.items.items[self.selected_idx].original
                else
                    self.matched_items.items[self.selected_idx].item.original;
                try result.selected.append(self.allocator, original);
            }
        }

        return result;
    }

    fn buildResultAll(self: *Tui) !TuiResult {
        var result = TuiResult{
            .allocator = self.allocator,
            .selected = .empty,
            .query = try self.allocator.dupe(u8, self.query.items),
            .aborted = false,
        };

        // Return all results (handle both showing_all and filtered modes)
        if (self.showing_all) {
            for (self.items.items) |item_ptr| {
                try result.selected.append(self.allocator, item_ptr.original);
            }
        } else {
            for (self.matched_items.items) |item| {
                try result.selected.append(self.allocator, item.item.original);
            }
        }

        return result;
    }

    fn findItemById(self: *Tui, id: usize) ?*const chunk.ChunkItem {
        const snapshot = self.chunk_list.snapshot();
        for (snapshot.chunks) |c| {
            for (c.items) |*it| {
                if (it.id == id) return it;
            }
        }
        return null;
    }
};
