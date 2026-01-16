//! Configuration for the fuzzy matcher.

const std = @import("std");
const CharClass = @import("chars.zig").CharClass;
const score = @import("score.zig");

/// Configuration data that controls how a matcher behaves
pub const Config = struct {
    /// Characters that act as delimiters and provide bonus for matching the following char
    delimiter_chars: []const u8,

    /// Extra bonus for word boundary after whitespace character or beginning of the string
    bonus_boundary_white: u16,

    /// Extra bonus for word boundary after slash, colon, semi-colon, and comma
    bonus_boundary_delimiter: u16,

    /// Character class assumed before the start of the haystack
    initial_char_class: CharClass,

    /// Whether to normalize latin script characters to ASCII (enabled by default)
    normalize: bool,

    /// Whether to ignore casing
    ignore_case: bool,

    /// Whether to provide a bonus to matches by their distance from the start
    /// of the haystack. The bonus is fairly small compared to the normal gap
    /// penalty to avoid messing with the normal score heuristic.
    prefer_prefix: bool,

    /// The default configuration
    pub fn default() Config {
        return .{
            .delimiter_chars = "/,:;|",
            .bonus_boundary_white = score.BONUS_BOUNDARY + 2,
            .bonus_boundary_delimiter = score.BONUS_BOUNDARY + 1,
            .initial_char_class = .whitespace,
            .normalize = true,
            .ignore_case = true,
            .prefer_prefix = false,
        };
    }

    /// Configures the matcher with bonuses appropriate for matching file paths.
    pub fn matchPaths(self: Config) Config {
        var config = self;
        if (@import("builtin").os.tag == .windows) {
            config.delimiter_chars = "/\\";
        } else {
            config.delimiter_chars = "/";
        }
        config.bonus_boundary_white = score.BONUS_BOUNDARY;
        config.initial_char_class = .delimiter;
        return config;
    }

    /// Calculate the bonus for a character transition
    pub fn bonusFor(self: *const Config, prev_class: CharClass, class: CharClass) u16 {
        if (class.isWord()) {
            // transition from non-word to word
            return switch (prev_class) {
                .whitespace => self.bonus_boundary_white,
                .delimiter => self.bonus_boundary_delimiter,
                .non_word => score.BONUS_BOUNDARY,
                else => blk: {
                    // Check for camelCase or number transitions
                    if (prev_class == .lower and class == .upper) {
                        break :blk score.BONUS_CAMEL123;
                    }
                    if (prev_class != .number and class == .number) {
                        break :blk score.BONUS_CAMEL123;
                    }
                    break :blk 0;
                },
            };
        }
        if (class == .whitespace) {
            return self.bonus_boundary_white;
        }
        if (class == .non_word) {
            return score.BONUS_NON_WORD;
        }
        return 0;
    }
};

test "default config" {
    const config = Config.default();
    try std.testing.expect(config.ignore_case);
    try std.testing.expect(config.normalize);
    try std.testing.expect(!config.prefer_prefix);
    try std.testing.expectEqual(CharClass.whitespace, config.initial_char_class);
}

test "match paths config" {
    const config = Config.default().matchPaths();
    try std.testing.expectEqual(CharClass.delimiter, config.initial_char_class);
}

test "bonus calculation" {
    const config = Config.default();

    // Word boundary after whitespace
    try std.testing.expectEqual(score.BONUS_BOUNDARY + 2, config.bonusFor(.whitespace, .lower));

    // Word boundary after delimiter
    try std.testing.expectEqual(score.BONUS_BOUNDARY + 1, config.bonusFor(.delimiter, .lower));

    // CamelCase transition
    try std.testing.expectEqual(score.BONUS_CAMEL123, config.bonusFor(.lower, .upper));

    // Number transition
    try std.testing.expectEqual(score.BONUS_CAMEL123, config.bonusFor(.lower, .number));

    // No bonus for same class
    try std.testing.expectEqual(@as(u16, 0), config.bonusFor(.lower, .lower));
}
