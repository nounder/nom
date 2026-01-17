//! nom - A fuzzy matcher library implementing the nucleo algorithm in Zig.
//!
//! This is a port of the nucleo fuzzy matcher (https://github.com/helix-editor/nucleo)
//! providing high-performance fuzzy matching with support for:
//! - Fuzzy matching (with gaps)
//! - Substring matching
//! - Prefix/postfix matching
//! - Exact matching
//! - Unicode support with case folding and normalization
//!
//! # Example
//! ```zig
//! const nom = @import("nom");
//!
//! var matcher = nom.Matcher.init(nom.Config.default());
//! defer matcher.deinit();
//!
//! const pattern = nom.Pattern.parse("foo bar", .smart, .smart);
//! const score = pattern.score("foo/bar/baz", &matcher);
//! ```

const std = @import("std");

// Core types
pub const Config = @import("config.zig").Config;
pub const CharClass = @import("chars.zig").CharClass;
pub const Char = @import("chars.zig").Char;
pub const AsciiChar = @import("chars.zig").AsciiChar;

// String types
pub const Utf32Str = @import("utf32_str.zig").Utf32Str;
pub const Utf32String = @import("utf32_str.zig").Utf32String;

// Scoring
pub const score = @import("score.zig");

// Matcher
pub const Matcher = @import("matcher.zig").Matcher;

// Pattern API
pub const Pattern = @import("pattern.zig").Pattern;
pub const Atom = @import("pattern.zig").Atom;
pub const AtomKind = @import("pattern.zig").AtomKind;
pub const CaseMatching = @import("pattern.zig").CaseMatching;
pub const Normalization = @import("pattern.zig").Normalization;

// TUI
pub const Tui = @import("tui.zig").Tui;
pub const TuiConfig = @import("tui.zig").TuiConfig;
pub const TuiResult = @import("tui.zig").TuiResult;
pub const PreviewWindow = @import("tui.zig").PreviewWindow;
pub const Terminal = @import("term.zig").Terminal;

// Preview
pub const preview = @import("preview.zig");
pub const PreviewRunner = preview.PreviewRunner;

// fzf compatibility
pub const fzf = @import("fzf.zig");

// File utilities
pub const files = @import("files.zig");

test {
    std.testing.refAllDecls(@This());
}
