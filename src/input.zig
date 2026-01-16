//! Input event parsing for TUI.
//!
//! This module handles parsing keyboard and mouse input from the terminal.

const std = @import("std");
const Terminal = @import("term.zig").Terminal;

/// Key modifiers
pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _padding: u5 = 0,
};

/// Special keys
pub const Key = union(enum) {
    char: u21,
    enter,
    tab,
    backtab, // Shift+Tab
    backspace,
    delete,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    unknown,
};

/// Mouse button
pub const MouseButton = enum {
    left,
    middle,
    right,
    scroll_up,
    scroll_down,
    none,
};

/// Mouse event type
pub const MouseEventKind = enum {
    press,
    release,
    drag,
    move,
};

/// Mouse event
pub const MouseEvent = struct {
    button: MouseButton,
    kind: MouseEventKind,
    col: u16,
    row: u16,
    modifiers: Modifiers,
};

/// Input event
pub const Event = union(enum) {
    key: struct {
        key: Key,
        modifiers: Modifiers,
    },
    mouse: MouseEvent,
    resize: struct {
        width: u16,
        height: u16,
    },
    none,
};

/// Input reader that parses terminal input into events.
/// Does not store a pointer to Terminal - instead, Terminal is passed to readEvent().
pub const InputReader = struct {
    buf: [32]u8 = undefined,
    buf_len: usize = 0,
    buf_pos: usize = 0,

    /// Read and parse the next input event
    pub fn readEvent(self: *InputReader, term: *Terminal) Event {
        const byte = self.nextByte(term) orelse return .none;

        // ESC sequence
        if (byte == 0x1b) {
            return self.parseEscapeSequence(term);
        }

        // Control characters
        if (byte < 32) {
            return parseControlChar(byte);
        }

        // DEL
        if (byte == 127) {
            return .{ .key = .{ .key = .backspace, .modifiers = .{} } };
        }

        // Regular character (possibly UTF-8)
        return self.parseChar(term, byte);
    }

    fn nextByte(self: *InputReader, term: *Terminal) ?u8 {
        if (self.buf_pos < self.buf_len) {
            const b = self.buf[self.buf_pos];
            self.buf_pos += 1;
            return b;
        }

        // Read more from terminal
        self.buf_len = term.read(&self.buf);
        self.buf_pos = 0;

        if (self.buf_len == 0) return null;

        const b = self.buf[0];
        self.buf_pos = 1;
        return b;
    }

    fn peekByte(self: *InputReader) ?u8 {
        if (self.buf_pos < self.buf_len) {
            return self.buf[self.buf_pos];
        }
        return null;
    }

    fn parseControlChar(byte: u8) Event {
        const key: Key = switch (byte) {
            0 => .{ .char = ' ' }, // Ctrl+Space
            9 => .tab,
            10, 13 => .enter,
            27 => .escape,
            else => .{ .char = byte + 'a' - 1 },
        };

        var mods = Modifiers{};
        if (byte >= 1 and byte <= 26) {
            mods.ctrl = true;
        }

        return .{ .key = .{ .key = key, .modifiers = mods } };
    }

    fn parseChar(self: *InputReader, term: *Terminal, first: u8) Event {
        // Decode UTF-8
        var codepoint: u21 = first;

        if (first >= 0xC0) {
            const len: u3 = if (first < 0xE0)
                2
            else if (first < 0xF0)
                3
            else
                4;

            codepoint = @as(u21, first) & (@as(u21, 0x7F) >> len);

            var i: u3 = 1;
            while (i < len) : (i += 1) {
                const cont = self.nextByte(term) orelse break;
                if ((cont & 0xC0) != 0x80) break;
                codepoint = (codepoint << 6) | (cont & 0x3F);
            }
        }

        return .{ .key = .{ .key = .{ .char = codepoint }, .modifiers = .{} } };
    }

    fn parseEscapeSequence(self: *InputReader, term: *Terminal) Event {
        // Check if there's more data (escape sequence) or just ESC
        const next = self.peekByte() orelse {
            // Wait a bit for more input
            std.Thread.sleep(10 * std.time.ns_per_ms);
            // Try to read more
            self.buf_len = term.read(&self.buf);
            self.buf_pos = 0;
            if (self.peekByte() == null) {
                return .{ .key = .{ .key = .escape, .modifiers = .{} } };
            }
            return self.parseEscapeSequence(term);
        };

        _ = self.nextByte(term); // consume peeked byte

        if (next == '[') {
            return self.parseCsiSequence(term);
        } else if (next == 'O') {
            return self.parseSs3Sequence(term);
        } else {
            // Alt + key
            if (next < 32) {
                var event = parseControlChar(next);
                if (event == .key) {
                    event.key.modifiers.alt = true;
                }
                return event;
            } else if (next < 127) {
                return .{ .key = .{
                    .key = .{ .char = next },
                    .modifiers = .{ .alt = true },
                } };
            }
            return .{ .key = .{ .key = .unknown, .modifiers = .{} } };
        }
    }

    fn parseCsiSequence(self: *InputReader, term: *Terminal) Event {
        var params: [8]u16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var param_count: usize = 0;
        var current_param: u16 = 0;
        var has_digit = false;

        // Parse parameters
        while (self.nextByte(term)) |b| {
            if (b >= '0' and b <= '9') {
                current_param = current_param * 10 + (b - '0');
                has_digit = true;
            } else if (b == ';') {
                if (param_count < params.len) {
                    params[param_count] = current_param;
                    param_count += 1;
                }
                current_param = 0;
                has_digit = false;
            } else if (b == '<') {
                // SGR mouse mode prefix, continue parsing
                continue;
            } else {
                // Final byte
                if (has_digit and param_count < params.len) {
                    params[param_count] = current_param;
                    param_count += 1;
                }
                return interpretCsi(b, params[0..param_count]);
            }
        }

        return .{ .key = .{ .key = .unknown, .modifiers = .{} } };
    }

    fn interpretCsi(final: u8, params: []u16) Event {

        // Mouse events (SGR format)
        if (final == 'M' or final == 'm') {
            if (params.len >= 3) {
                const button_code = params[0];
                const col = if (params[1] > 0) params[1] - 1 else 0;
                const row = if (params[2] > 0) params[2] - 1 else 0;

                var mods = Modifiers{};
                if (button_code & 4 != 0) mods.shift = true;
                if (button_code & 8 != 0) mods.alt = true;
                if (button_code & 16 != 0) mods.ctrl = true;

                const base_button = button_code & 3;
                const button: MouseButton = if (button_code & 64 != 0)
                    if (base_button == 0) .scroll_up else .scroll_down
                else switch (base_button) {
                    0 => .left,
                    1 => .middle,
                    2 => .right,
                    else => .none,
                };

                const kind: MouseEventKind = if (final == 'm')
                    .release
                else if (button_code & 32 != 0)
                    .drag
                else
                    .press;

                return .{ .mouse = .{
                    .button = button,
                    .kind = kind,
                    .col = @truncate(col),
                    .row = @truncate(row),
                    .modifiers = mods,
                } };
            }
        }

        // Arrow keys and special keys
        const modifier = if (params.len >= 2) blk: {
            const m = params[1];
            break :blk Modifiers{
                .shift = (m & 1) != 0,
                .alt = (m & 2) != 0,
                .ctrl = (m & 4) != 0,
            };
        } else Modifiers{};

        const key: Key = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .backtab,
            '~' => if (params.len > 0) switch (params[0]) {
                1 => .home,
                2 => .insert,
                3 => .delete,
                4 => .end,
                5 => .page_up,
                6 => .page_down,
                15 => .f5,
                17 => .f6,
                18 => .f7,
                19 => .f8,
                20 => .f9,
                21 => .f10,
                23 => .f11,
                24 => .f12,
                else => .unknown,
            } else .unknown,
            else => .unknown,
        };

        return .{ .key = .{ .key = key, .modifiers = modifier } };
    }

    fn parseSs3Sequence(self: *InputReader, term: *Terminal) Event {
        const byte = self.nextByte(term) orelse return .{ .key = .{ .key = .unknown, .modifiers = .{} } };

        const key: Key = switch (byte) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'P' => .f1,
            'Q' => .f2,
            'R' => .f3,
            'S' => .f4,
            else => .unknown,
        };

        return .{ .key = .{ .key = key, .modifiers = .{} } };
    }
};
