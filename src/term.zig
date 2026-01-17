//! Terminal handling for TUI.
//!
//! This module provides low-level terminal control including:
//! - Raw mode enable/disable
//! - Cursor movement and visibility
//! - Screen clearing and scrolling
//! - Color and style output
//! - Buffered output (all writes accumulated, single atomic flush)

const std = @import("std");
const posix = std.posix;

/// Size of write buffer - 64KB should be enough for most screens
const WRITE_BUFFER_SIZE = 64 * 1024;

/// Terminal state for raw mode
pub const Terminal = struct {
    ttyin: std.fs.File, // For reading input
    ttyout: std.fs.File, // For writing output
    original_termios: posix.termios,
    width: u16,
    height: u16,

    // Write buffer for atomic screen updates (like fzf's strings.Builder)
    write_buf: [WRITE_BUFFER_SIZE]u8 = undefined,
    write_len: usize = 0,

    /// Initialize terminal and enter raw mode
    pub fn init() !Terminal {
        // Open /dev/tty for reading (user input)
        const ttyin = std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_only }) catch
            return error.NoTTY;
        errdefer ttyin.close();

        // Open /dev/tty for writing (display output)
        // If this fails, fall back to stderr
        const ttyout = std.fs.cwd().openFile("/dev/tty", .{ .mode = .write_only }) catch
            std.fs.File.stderr();

        var self = Terminal{
            .ttyin = ttyin,
            .ttyout = ttyout,
            .original_termios = undefined,
            .width = 80,
            .height = 24,
        };

        // Get original termios from input TTY
        self.original_termios = try posix.tcgetattr(ttyin.handle);

        // Get terminal size
        self.updateSize();

        // Enter raw mode
        try self.enableRawMode();

        return self;
    }

    /// Clean up and restore terminal
    pub fn deinit(self: *Terminal) void {
        self.disableRawMode() catch {};
        self.ttyin.close();
        // Only close ttyout if it's not stderr
        if (self.ttyout.handle != std.fs.File.stderr().handle) {
            self.ttyout.close();
        }
    }

    /// Enable raw mode
    fn enableRawMode(self: *Terminal) !void {
        var raw = self.original_termios;

        // Input modes: no break, no CR to NL, no parity check, no strip char, no start/stop
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output modes: disable post processing
        raw.oflag.OPOST = false;

        // Control modes: set 8 bit chars
        raw.cflag.CSIZE = .CS8;

        // Local modes: no echo, no canonical, no extended functions, no signal chars
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control chars: set return condition: min 0 bytes, 100ms timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1; // 100ms timeout

        try posix.tcsetattr(self.ttyin.handle, .FLUSH, raw);
    }

    /// Disable raw mode (restore original)
    fn disableRawMode(self: *Terminal) !void {
        try posix.tcsetattr(self.ttyin.handle, .FLUSH, self.original_termios);
    }

    /// Update terminal size from ioctl
    pub fn updateSize(self: *Terminal) void {
        var ws: posix.winsize = undefined;

        // Try ttyin first (the /dev/tty we opened for reading)
        const result = posix.system.ioctl(self.ttyin.handle, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0 and ws.col > 0 and ws.row > 0) {
            self.width = ws.col;
            self.height = ws.row;
            return;
        }

        // Fallback: try ttyout
        const result2 = posix.system.ioctl(self.ttyout.handle, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result2 == 0 and ws.col > 0 and ws.row > 0) {
            self.width = ws.col;
            self.height = ws.row;
            return;
        }

        // Fallback: try stderr
        const stderr_handle = std.fs.File.stderr().handle;
        const result3 = posix.system.ioctl(stderr_handle, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result3 == 0 and ws.col > 0 and ws.row > 0) {
            self.width = ws.col;
            self.height = ws.row;
            return;
        }

        // Keep defaults (80x24) if all fail
    }

    /// Queue bytes to write buffer (does NOT write to terminal yet)
    /// All writes are accumulated and sent atomically on flush()
    pub fn write(self: *Terminal, bytes: []const u8) !void {
        const available = WRITE_BUFFER_SIZE - self.write_len;
        const to_write = @min(bytes.len, available);
        if (to_write > 0) {
            @memcpy(self.write_buf[self.write_len..][0..to_write], bytes[0..to_write]);
            self.write_len += to_write;
        }
        // If buffer full, flush and continue (shouldn't happen normally)
        if (to_write < bytes.len) {
            self.flush();
            const remaining = bytes[to_write..];
            const to_write2 = @min(remaining.len, WRITE_BUFFER_SIZE);
            @memcpy(self.write_buf[0..to_write2], remaining[0..to_write2]);
            self.write_len = to_write2;
        }
    }

    /// Flush buffered output to terminal - atomic screen update
    /// This is the key to preventing flicker: all CSI codes and text
    /// are written in a single write() call
    pub fn flush(self: *Terminal) void {
        if (self.write_len > 0) {
            // Single atomic write - prevents flicker
            _ = self.ttyout.write(self.write_buf[0..self.write_len]) catch {};
            self.write_len = 0;
        }
    }

    /// Write formatted output to buffer
    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
        try self.write(str);
    }

    /// Read a single byte (with timeout)
    pub fn readByte(self: *Terminal) ?u8 {
        var buf: [1]u8 = undefined;
        const n = self.ttyin.read(&buf) catch return null;
        if (n == 0) return null;
        return buf[0];
    }

    /// Read multiple bytes
    pub fn read(self: *Terminal, buf: []u8) usize {
        return self.ttyin.read(buf) catch 0;
    }

    // === Cursor Control ===

    /// Hide cursor
    pub fn hideCursor(self: *Terminal) !void {
        try self.write("\x1b[?25l");
    }

    /// Show cursor
    pub fn showCursor(self: *Terminal) !void {
        try self.write("\x1b[?25h");
    }

    /// Move cursor to position (1-indexed)
    pub fn moveTo(self: *Terminal, row: u16, col: u16) !void {
        try self.print("\x1b[{d};{d}H", .{ row, col });
    }

    /// Move cursor to column (1-indexed)
    pub fn moveToCol(self: *Terminal, col: u16) !void {
        try self.print("\x1b[{d}G", .{col});
    }

    /// Move cursor up n rows
    pub fn moveUp(self: *Terminal, n: u16) !void {
        if (n > 0) try self.print("\x1b[{d}A", .{n});
    }

    /// Move cursor down n rows
    pub fn moveDown(self: *Terminal, n: u16) !void {
        if (n > 0) try self.print("\x1b[{d}B", .{n});
    }

    /// Write directly to terminal, bypassing buffer (for queries that need immediate response)
    fn writeImmediate(self: *Terminal, bytes: []const u8) !void {
        _ = try self.ttyout.write(bytes);
    }

    /// Query cursor position and return (row, col), both 1-indexed
    pub fn getCursorPos(self: *Terminal) ?struct { row: u16, col: u16 } {
        // Flush any pending output first
        self.flush();
        // Send cursor position query directly (needs immediate response)
        self.writeImmediate("\x1b[6n") catch return null;

        // Read response: ESC [ row ; col R
        var buf: [32]u8 = undefined;
        var len: usize = 0;

        // Read with timeout - look for 'R' terminator
        while (len < buf.len) {
            const byte = self.readByte() orelse break;
            buf[len] = byte;
            len += 1;
            if (byte == 'R') break;
        }

        // Parse response
        if (len < 6) return null; // Minimum: ESC [ 1 ; 1 R
        if (buf[0] != '\x1b' or buf[1] != '[') return null;

        // Find semicolon
        var semi_pos: usize = 2;
        while (semi_pos < len and buf[semi_pos] != ';') : (semi_pos += 1) {}
        if (semi_pos >= len - 1) return null;

        // Parse row and col
        const row = std.fmt.parseInt(u16, buf[2..semi_pos], 10) catch return null;
        const col = std.fmt.parseInt(u16, buf[semi_pos + 1 .. len - 1], 10) catch return null;

        return .{ .row = row, .col = col };
    }

    /// Begin a render frame - hide cursor and disable line wrap
    pub fn beginFrame(self: *Terminal) !void {
        try self.write("\x1b[?25l\x1b[?7l"); // Hide cursor, disable line wrap
    }

    /// End a render frame - restore cursor and line wrap, then flush
    pub fn endFrame(self: *Terminal, show_cursor: bool) void {
        if (show_cursor) {
            self.write("\x1b[?25h\x1b[?7h") catch {}; // Show cursor, enable line wrap
        } else {
            self.write("\x1b[?7h") catch {}; // Just enable line wrap
        }
        self.flush();
    }

    // === Screen Control ===

    /// Clear entire screen
    pub fn clearScreen(self: *Terminal) !void {
        try self.write("\x1b[2J");
    }

    /// Clear from cursor to end of screen
    pub fn clearToEnd(self: *Terminal) !void {
        try self.write("\x1b[J");
    }

    /// Clear current line
    pub fn clearLine(self: *Terminal) !void {
        try self.write("\x1b[2K");
    }

    /// Clear from cursor to end of line
    pub fn clearLineToEnd(self: *Terminal) !void {
        try self.write("\x1b[K");
    }

    /// Enter alternate screen buffer
    pub fn enterAltScreen(self: *Terminal) !void {
        try self.write("\x1b[?1049h");
    }

    /// Leave alternate screen buffer
    pub fn leaveAltScreen(self: *Terminal) !void {
        try self.write("\x1b[?1049l");
    }

    /// Enable mouse tracking
    pub fn enableMouse(self: *Terminal) !void {
        try self.write("\x1b[?1000h\x1b[?1002h\x1b[?1015h\x1b[?1006h");
    }

    /// Disable mouse tracking
    pub fn disableMouse(self: *Terminal) !void {
        try self.write("\x1b[?1006l\x1b[?1015l\x1b[?1002l\x1b[?1000l");
    }

    // === Style Control ===

    /// Reset all attributes
    pub fn resetStyle(self: *Terminal) !void {
        try self.write("\x1b[0m");
    }

    /// Set bold
    pub fn setBold(self: *Terminal) !void {
        try self.write("\x1b[1m");
    }

    /// Set dim
    pub fn setDim(self: *Terminal) !void {
        try self.write("\x1b[2m");
    }

    /// Set underline
    pub fn setUnderline(self: *Terminal) !void {
        try self.write("\x1b[4m");
    }

    /// Set reverse video
    pub fn setReverse(self: *Terminal) !void {
        try self.write("\x1b[7m");
    }

    /// Set foreground color (basic 8 colors: 0-7)
    pub fn setFg(self: *Terminal, color: u8) !void {
        try self.print("\x1b[{d}m", .{30 + color});
    }

    /// Set background color (basic 8 colors: 0-7)
    pub fn setBg(self: *Terminal, color: u8) !void {
        try self.print("\x1b[{d}m", .{40 + color});
    }

    /// Set foreground color (256 colors)
    pub fn setFg256(self: *Terminal, color: u8) !void {
        try self.print("\x1b[38;5;{d}m", .{color});
    }

    /// Set background color (256 colors)
    pub fn setBg256(self: *Terminal, color: u8) !void {
        try self.print("\x1b[48;5;{d}m", .{color});
    }

    /// Set foreground RGB color
    pub fn setFgRgb(self: *Terminal, r: u8, g: u8, b: u8) !void {
        try self.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
    }

    /// Set background RGB color
    pub fn setBgRgb(self: *Terminal, r: u8, g: u8, b: u8) !void {
        try self.print("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
    }
};

/// Standard colors
pub const Color = struct {
    pub const black: u8 = 0;
    pub const red: u8 = 1;
    pub const green: u8 = 2;
    pub const yellow: u8 = 3;
    pub const blue: u8 = 4;
    pub const magenta: u8 = 5;
    pub const cyan: u8 = 6;
    pub const white: u8 = 7;
};
