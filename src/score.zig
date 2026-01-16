//! Scoring constants and calculations for fuzzy matching.
//!
//! The scoring system is based on the Smith-Waterman algorithm with affine gaps.
//! It rewards matches at word boundaries, consecutive matches, and penalizes gaps.

const std = @import("std");

/// Base score for matching a character
pub const SCORE_MATCH: u16 = 16;

/// Penalty for starting a gap (skipping characters in haystack)
pub const PENALTY_GAP_START: u16 = 3;

/// Penalty for extending an existing gap
pub const PENALTY_GAP_EXTENSION: u16 = 1;

/// Scale factor for prefix bonus
pub const PREFIX_BONUS_SCALE: u16 = 2;

/// Maximum prefix bonus
pub const MAX_PREFIX_BONUS: u16 = BONUS_BOUNDARY;

/// Bonus for word boundary (SCORE_MATCH / 2)
/// We prefer matches at the beginning of a word, but the bonus should not be
/// too great to prevent the longer acronym matches from always winning over
/// shorter fuzzy matches. The bonus point here was specifically chosen that
/// the bonus is cancelled when the gap between the acronyms grows over
/// 8 characters.
pub const BONUS_BOUNDARY: u16 = SCORE_MATCH / 2;

/// Edge-triggered bonus for matches in camelCase words (lower to upper transition)
/// or number transitions. Value is BONUS_BOUNDARY - PENALTY_GAP_START = 5.
pub const BONUS_CAMEL123: u16 = BONUS_BOUNDARY - PENALTY_GAP_START;

/// Bonus for non-word characters (punctuation, etc.)
/// Although bonus point for non-word characters is non-contextual, we need it
/// for computing bonus points for consecutive chunks starting with a non-word character.
pub const BONUS_NON_WORD: u16 = BONUS_BOUNDARY;

/// Minimum bonus point given to characters in consecutive chunks.
pub const BONUS_CONSECUTIVE: u16 = PENALTY_GAP_START + PENALTY_GAP_EXTENSION;

/// The first character in the typed pattern usually has more significance
/// than the rest so it's important that it appears at special positions where
/// bonus points are given. This multiplier increases the first char bonus.
pub const BONUS_FIRST_CHAR_MULTIPLIER: u16 = 2;

test "score constants are consistent" {
    // Verify relationships between constants
    try std.testing.expect(BONUS_BOUNDARY == SCORE_MATCH / 2);
    try std.testing.expect(BONUS_CAMEL123 == BONUS_BOUNDARY - PENALTY_GAP_START);
    try std.testing.expect(BONUS_CONSECUTIVE == PENALTY_GAP_START + PENALTY_GAP_EXTENSION);
    try std.testing.expect(PENALTY_GAP_START > PENALTY_GAP_EXTENSION);
}
