//! Icons for files and directories, similar to lsd.
//!
//! Two themes:
//! - `fancy` (default): Nerd-Font glyphs. Requires a Nerd Font.
//! - `unicode`: plain BMP Unicode symbols that render with most fonts.
//!
//! Each icon carries a 256-color palette index for tinting.

const std = @import("std");

pub const Theme = enum { fancy, unicode };

/// When to show icons. Mirrors lsd's `--icon` flag.
pub const When = enum { always, auto, never };

pub const Icon = struct {
    glyph: []const u8,
    color: u8, // 256-color palette
};

// Codepoints sourced from eza (https://github.com/eza-community/eza/blob/main/src/output/icons.rs),
// which uses Nerd Fonts v3 mappings.
const default_file: Icon = .{ .glyph = "\u{f15b}", .color = 250 }; //
const default_dir: Icon = .{ .glyph = "\u{e5ff}", .color = 75 }; //  (folder, NF v3)
const default_exec: Icon = .{ .glyph = "\u{f489}", .color = 113 }; //  (terminal)
const symlink: Icon = .{ .glyph = "\u{f481}", .color = 75 }; //

const NameIcon = struct { name: []const u8, icon: Icon };
const ExtIcon = struct { ext: []const u8, icon: Icon };

// Exact filename matches (case-insensitive). Checked before extensions.
const by_name = [_]NameIcon{
    .{ .name = ".gitignore", .icon = .{ .glyph = "\u{f02a2}", .color = 202 } },
    .{ .name = ".gitattributes", .icon = .{ .glyph = "\u{f02a2}", .color = 202 } },
    .{ .name = ".gitmodules", .icon = .{ .glyph = "\u{f02a2}", .color = 202 } },
    .{ .name = ".git", .icon = .{ .glyph = "\u{e5fb}", .color = 202 } },
    .{ .name = "license", .icon = .{ .glyph = "\u{f02d}", .color = 185 } },
    .{ .name = "license.md", .icon = .{ .glyph = "\u{f02d}", .color = 185 } },
    .{ .name = "license.txt", .icon = .{ .glyph = "\u{f02d}", .color = 185 } },
    .{ .name = "readme", .icon = .{ .glyph = "\u{f00ba}", .color = 75 } },
    .{ .name = "readme.md", .icon = .{ .glyph = "\u{f00ba}", .color = 75 } },
    .{ .name = "readme.txt", .icon = .{ .glyph = "\u{f00ba}", .color = 75 } },
    .{ .name = "makefile", .icon = .{ .glyph = "\u{e673}", .color = 166 } },
    .{ .name = "dockerfile", .icon = .{ .glyph = "\u{e650}", .color = 39 } },
    .{ .name = "docker-compose.yml", .icon = .{ .glyph = "\u{e650}", .color = 39 } },
    .{ .name = "docker-compose.yaml", .icon = .{ .glyph = "\u{e650}", .color = 39 } },
    .{ .name = "cargo.toml", .icon = .{ .glyph = "\u{e68b}", .color = 166 } },
    .{ .name = "cargo.lock", .icon = .{ .glyph = "\u{e68b}", .color = 166 } },
    .{ .name = "package.json", .icon = .{ .glyph = "\u{e71e}", .color = 197 } },
    .{ .name = "package-lock.json", .icon = .{ .glyph = "\u{e71e}", .color = 197 } },
    .{ .name = "build.zig", .icon = .{ .glyph = "\u{e6a9}", .color = 208 } },
    .{ .name = "build.zig.zon", .icon = .{ .glyph = "\u{e6a9}", .color = 208 } },
    .{ .name = ".env", .icon = .{ .glyph = "\u{f462}", .color = 227 } },
};

// Extensions (case-insensitive, no leading dot).
const by_ext = [_]ExtIcon{
    // Languages
    .{ .ext = "zig", .icon = .{ .glyph = "\u{e6a9}", .color = 208 } },
    .{ .ext = "rs", .icon = .{ .glyph = "\u{e68b}", .color = 166 } },
    .{ .ext = "go", .icon = .{ .glyph = "\u{e65e}", .color = 81 } },
    .{ .ext = "py", .icon = .{ .glyph = "\u{e606}", .color = 220 } },
    .{ .ext = "pyc", .icon = .{ .glyph = "\u{e606}", .color = 220 } },
    .{ .ext = "rb", .icon = .{ .glyph = "\u{e739}", .color = 196 } },
    .{ .ext = "c", .icon = .{ .glyph = "\u{e61e}", .color = 75 } },
    .{ .ext = "h", .icon = .{ .glyph = "\u{e61e}", .color = 140 } },
    .{ .ext = "cpp", .icon = .{ .glyph = "\u{e61d}", .color = 75 } },
    .{ .ext = "cc", .icon = .{ .glyph = "\u{e61d}", .color = 75 } },
    .{ .ext = "cxx", .icon = .{ .glyph = "\u{e61d}", .color = 75 } },
    .{ .ext = "hpp", .icon = .{ .glyph = "\u{e61d}", .color = 140 } },
    .{ .ext = "java", .icon = .{ .glyph = "\u{e256}", .color = 167 } },
    .{ .ext = "kt", .icon = .{ .glyph = "\u{e634}", .color = 99 } },
    .{ .ext = "swift", .icon = .{ .glyph = "\u{e755}", .color = 209 } },
    .{ .ext = "js", .icon = .{ .glyph = "\u{e74e}", .color = 185 } },
    .{ .ext = "mjs", .icon = .{ .glyph = "\u{e74e}", .color = 185 } },
    .{ .ext = "cjs", .icon = .{ .glyph = "\u{e74e}", .color = 185 } },
    .{ .ext = "ts", .icon = .{ .glyph = "\u{e628}", .color = 75 } },
    .{ .ext = "tsx", .icon = .{ .glyph = "\u{e7ba}", .color = 75 } },
    .{ .ext = "jsx", .icon = .{ .glyph = "\u{e7ba}", .color = 185 } },
    .{ .ext = "vue", .icon = .{ .glyph = "\u{f0844}", .color = 113 } },
    .{ .ext = "lua", .icon = .{ .glyph = "\u{e620}", .color = 75 } },
    .{ .ext = "php", .icon = .{ .glyph = "\u{e73d}", .color = 99 } },
    .{ .ext = "scala", .icon = .{ .glyph = "\u{e737}", .color = 196 } },
    .{ .ext = "ex", .icon = .{ .glyph = "\u{e62d}", .color = 99 } },
    .{ .ext = "exs", .icon = .{ .glyph = "\u{e62d}", .color = 99 } },
    .{ .ext = "erl", .icon = .{ .glyph = "\u{e7b1}", .color = 196 } },
    .{ .ext = "hs", .icon = .{ .glyph = "\u{e777}", .color = 99 } },
    .{ .ext = "clj", .icon = .{ .glyph = "\u{e768}", .color = 113 } },
    .{ .ext = "dart", .icon = .{ .glyph = "\u{e798}", .color = 39 } },
    .{ .ext = "nim", .icon = .{ .glyph = "\u{e677}", .color = 220 } },

    // Shell
    .{ .ext = "sh", .icon = .{ .glyph = "\u{f489}", .color = 113 } },
    .{ .ext = "bash", .icon = .{ .glyph = "\u{f489}", .color = 113 } },
    .{ .ext = "zsh", .icon = .{ .glyph = "\u{f489}", .color = 113 } },
    .{ .ext = "fish", .icon = .{ .glyph = "\u{f489}", .color = 113 } },

    // Web
    .{ .ext = "html", .icon = .{ .glyph = "\u{f13b}", .color = 202 } },
    .{ .ext = "htm", .icon = .{ .glyph = "\u{f13b}", .color = 202 } },
    .{ .ext = "css", .icon = .{ .glyph = "\u{e749}", .color = 75 } },
    .{ .ext = "scss", .icon = .{ .glyph = "\u{e603}", .color = 197 } },
    .{ .ext = "sass", .icon = .{ .glyph = "\u{e603}", .color = 197 } },
    .{ .ext = "less", .icon = .{ .glyph = "\u{e758}", .color = 99 } },

    // Data / config
    .{ .ext = "json", .icon = .{ .glyph = "\u{e60b}", .color = 185 } },
    .{ .ext = "yaml", .icon = .{ .glyph = "\u{e8eb}", .color = 167 } },
    .{ .ext = "yml", .icon = .{ .glyph = "\u{e8eb}", .color = 167 } },
    .{ .ext = "toml", .icon = .{ .glyph = "\u{e6b2}", .color = 167 } },
    .{ .ext = "xml", .icon = .{ .glyph = "\u{f05c0}", .color = 166 } },
    .{ .ext = "ini", .icon = .{ .glyph = "\u{f107b}", .color = 245 } },
    .{ .ext = "cfg", .icon = .{ .glyph = "\u{f107b}", .color = 245 } },
    .{ .ext = "conf", .icon = .{ .glyph = "\u{f107b}", .color = 245 } },
    .{ .ext = "lock", .icon = .{ .glyph = "\u{f023}", .color = 245 } },
    .{ .ext = "csv", .icon = .{ .glyph = "\u{eefc}", .color = 113 } },
    .{ .ext = "tsv", .icon = .{ .glyph = "\u{f1c3}", .color = 113 } },
    .{ .ext = "sql", .icon = .{ .glyph = "\u{f1c0}", .color = 209 } },
    .{ .ext = "db", .icon = .{ .glyph = "\u{f1c0}", .color = 209 } },
    .{ .ext = "sqlite", .icon = .{ .glyph = "\u{e7c4}", .color = 209 } },

    // Docs
    .{ .ext = "md", .icon = .{ .glyph = "\u{f48a}", .color = 75 } },
    .{ .ext = "markdown", .icon = .{ .glyph = "\u{f48a}", .color = 75 } },
    .{ .ext = "rst", .icon = .{ .glyph = "\u{f15c}", .color = 245 } },
    .{ .ext = "txt", .icon = .{ .glyph = "\u{f15c}", .color = 245 } },
    .{ .ext = "log", .icon = .{ .glyph = "\u{f18d}", .color = 245 } },
    .{ .ext = "pdf", .icon = .{ .glyph = "\u{f1c1}", .color = 196 } },
    .{ .ext = "doc", .icon = .{ .glyph = "\u{f1c2}", .color = 27 } },
    .{ .ext = "docx", .icon = .{ .glyph = "\u{f1c2}", .color = 27 } },
    .{ .ext = "xls", .icon = .{ .glyph = "\u{f1c3}", .color = 28 } },
    .{ .ext = "xlsx", .icon = .{ .glyph = "\u{f1c3}", .color = 28 } },
    .{ .ext = "ppt", .icon = .{ .glyph = "\u{f1c4}", .color = 196 } },
    .{ .ext = "pptx", .icon = .{ .glyph = "\u{f1c4}", .color = 196 } },

    // Images
    .{ .ext = "png", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },
    .{ .ext = "jpg", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },
    .{ .ext = "jpeg", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },
    .{ .ext = "gif", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },
    .{ .ext = "bmp", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },
    .{ .ext = "webp", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },
    .{ .ext = "svg", .icon = .{ .glyph = "\u{f0559}", .color = 220 } },
    .{ .ext = "ico", .icon = .{ .glyph = "\u{f1c5}", .color = 140 } },

    // Audio / video
    .{ .ext = "mp3", .icon = .{ .glyph = "\u{f001}", .color = 99 } },
    .{ .ext = "wav", .icon = .{ .glyph = "\u{f001}", .color = 99 } },
    .{ .ext = "flac", .icon = .{ .glyph = "\u{f001}", .color = 99 } },
    .{ .ext = "ogg", .icon = .{ .glyph = "\u{f001}", .color = 99 } },
    .{ .ext = "mp4", .icon = .{ .glyph = "\u{f03d}", .color = 197 } },
    .{ .ext = "mkv", .icon = .{ .glyph = "\u{f03d}", .color = 197 } },
    .{ .ext = "mov", .icon = .{ .glyph = "\u{f03d}", .color = 197 } },
    .{ .ext = "avi", .icon = .{ .glyph = "\u{f03d}", .color = 197 } },
    .{ .ext = "webm", .icon = .{ .glyph = "\u{f03d}", .color = 197 } },

    // Archives
    .{ .ext = "zip", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "tar", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "gz", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "tgz", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "bz2", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "xz", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "7z", .icon = .{ .glyph = "\u{f410}", .color = 220 } },
    .{ .ext = "rar", .icon = .{ .glyph = "\u{f410}", .color = 220 } },

    // Binaries / objects
    .{ .ext = "o", .icon = .{ .glyph = "\u{eae8}", .color = 245 } },
    .{ .ext = "a", .icon = .{ .glyph = "\u{f17c}", .color = 245 } },
    .{ .ext = "so", .icon = .{ .glyph = "\u{f17c}", .color = 245 } },
    .{ .ext = "dylib", .icon = .{ .glyph = "\u{f179}", .color = 245 } },
    .{ .ext = "dll", .icon = .{ .glyph = "\u{eb9c}", .color = 245 } },
    .{ .ext = "exe", .icon = .{ .glyph = "\u{ebc4}", .color = 245 } },
};

/// Lowercase ASCII byte (non-ASCII bytes pass through unchanged).
fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Case-insensitive ASCII compare.
fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

/// Extract the basename of a path (the part after the final '/').
fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return path[i + 1 ..];
    }
    return path;
}

/// Extract the extension of a basename (without the leading dot).
/// Returns empty for hidden files like ".env" with no further dot.
fn extension(name: []const u8) []const u8 {
    if (name.len == 0) return "";
    // Skip leading dot for hidden files when looking for the extension.
    const start: usize = if (name[0] == '.') 1 else 0;
    if (std.mem.lastIndexOfScalar(u8, name[start..], '.')) |rel| {
        return name[start + rel + 1 ..];
    }
    return "";
}

/// Resolve an icon for the given path under the requested theme. Currently
/// treats every entry as a regular file (the streaming sources don't carry
/// file-type info). Trailing '/' is treated as a directory.
pub fn forPath(path: []const u8, theme: Theme) Icon {
    return switch (theme) {
        .fancy => fancyForPath(path),
        .unicode => unicodeForPath(path),
    };
}

fn fancyForPath(path: []const u8) Icon {
    if (path.len == 0) return default_file;
    if (path[path.len - 1] == '/') return default_dir;

    const name = basename(path);

    for (by_name) |entry| {
        if (eqlAsciiIgnoreCase(name, entry.name)) return entry.icon;
    }

    const ext = extension(name);
    if (ext.len > 0) {
        for (by_ext) |entry| {
            if (eqlAsciiIgnoreCase(ext, entry.ext)) return entry.icon;
        }
    }

    return default_file;
}

// --- Unicode theme -----------------------------------------------------------
//
// Plain BMP symbols that render with most monospace fonts. Coarser groupings
// than the fancy theme — we only need a handful of categories.

const Category = enum {
    folder,
    image,
    audio,
    video,
    archive,
    pdf,
    config,
    lock,
    code,
    doc,
    binary,
    plain,
};

fn unicodeIcon(cat: Category) Icon {
    return switch (cat) {
        .folder => .{ .glyph = "\u{1F4C1}", .color = 75 }, // 📁
        .image => .{ .glyph = "\u{1F5BC}", .color = 140 }, // 🖼
        .audio => .{ .glyph = "\u{1F3B5}", .color = 99 }, // 🎵
        .video => .{ .glyph = "\u{1F3AC}", .color = 197 }, // 🎬
        .archive => .{ .glyph = "\u{1F4E6}", .color = 220 }, // 📦
        .pdf => .{ .glyph = "\u{1F4D5}", .color = 196 }, // 📕
        .config => .{ .glyph = "\u{2699}", .color = 245 }, // ⚙
        .lock => .{ .glyph = "\u{1F512}", .color = 245 }, // 🔒
        .code => .{ .glyph = "\u{1F4DC}", .color = 185 }, // 📜
        .doc => .{ .glyph = "\u{1F4DD}", .color = 75 }, // 📝
        .binary => .{ .glyph = "\u{1F4BE}", .color = 245 }, // 💾
        .plain => .{ .glyph = "\u{1F4C4}", .color = 250 }, // 📄
    };
}

fn extCategory(ext: []const u8) ?Category {
    const map = [_]struct { ext: []const u8, cat: Category }{
        // images
        .{ .ext = "png", .cat = .image },   .{ .ext = "jpg", .cat = .image },
        .{ .ext = "jpeg", .cat = .image },  .{ .ext = "gif", .cat = .image },
        .{ .ext = "bmp", .cat = .image },   .{ .ext = "webp", .cat = .image },
        .{ .ext = "svg", .cat = .image },   .{ .ext = "ico", .cat = .image },
        // audio
        .{ .ext = "mp3", .cat = .audio },   .{ .ext = "wav", .cat = .audio },
        .{ .ext = "flac", .cat = .audio },  .{ .ext = "ogg", .cat = .audio },
        // video
        .{ .ext = "mp4", .cat = .video },   .{ .ext = "mkv", .cat = .video },
        .{ .ext = "mov", .cat = .video },   .{ .ext = "avi", .cat = .video },
        .{ .ext = "webm", .cat = .video },
        // archives
        .{ .ext = "zip", .cat = .archive }, .{ .ext = "tar", .cat = .archive },
        .{ .ext = "gz", .cat = .archive },  .{ .ext = "tgz", .cat = .archive },
        .{ .ext = "bz2", .cat = .archive }, .{ .ext = "xz", .cat = .archive },
        .{ .ext = "7z", .cat = .archive },  .{ .ext = "rar", .cat = .archive },
        // pdf
        .{ .ext = "pdf", .cat = .pdf },
        // config
        .{ .ext = "json", .cat = .config }, .{ .ext = "yaml", .cat = .config },
        .{ .ext = "yml", .cat = .config },  .{ .ext = "toml", .cat = .config },
        .{ .ext = "ini", .cat = .config },  .{ .ext = "cfg", .cat = .config },
        .{ .ext = "conf", .cat = .config }, .{ .ext = "xml", .cat = .config },
        // lock
        .{ .ext = "lock", .cat = .lock },
        // code
        .{ .ext = "zig", .cat = .code },    .{ .ext = "rs", .cat = .code },
        .{ .ext = "go", .cat = .code },     .{ .ext = "py", .cat = .code },
        .{ .ext = "rb", .cat = .code },     .{ .ext = "c", .cat = .code },
        .{ .ext = "h", .cat = .code },      .{ .ext = "cpp", .cat = .code },
        .{ .ext = "cc", .cat = .code },     .{ .ext = "cxx", .cat = .code },
        .{ .ext = "hpp", .cat = .code },    .{ .ext = "java", .cat = .code },
        .{ .ext = "kt", .cat = .code },     .{ .ext = "swift", .cat = .code },
        .{ .ext = "js", .cat = .code },     .{ .ext = "mjs", .cat = .code },
        .{ .ext = "cjs", .cat = .code },    .{ .ext = "ts", .cat = .code },
        .{ .ext = "tsx", .cat = .code },    .{ .ext = "jsx", .cat = .code },
        .{ .ext = "vue", .cat = .code },    .{ .ext = "lua", .cat = .code },
        .{ .ext = "php", .cat = .code },    .{ .ext = "scala", .cat = .code },
        .{ .ext = "ex", .cat = .code },     .{ .ext = "exs", .cat = .code },
        .{ .ext = "erl", .cat = .code },    .{ .ext = "hs", .cat = .code },
        .{ .ext = "clj", .cat = .code },    .{ .ext = "dart", .cat = .code },
        .{ .ext = "nim", .cat = .code },    .{ .ext = "sh", .cat = .code },
        .{ .ext = "bash", .cat = .code },   .{ .ext = "zsh", .cat = .code },
        .{ .ext = "fish", .cat = .code },   .{ .ext = "html", .cat = .code },
        .{ .ext = "htm", .cat = .code },    .{ .ext = "css", .cat = .code },
        .{ .ext = "scss", .cat = .code },   .{ .ext = "sass", .cat = .code },
        .{ .ext = "less", .cat = .code },   .{ .ext = "sql", .cat = .code },
        // docs
        .{ .ext = "md", .cat = .doc },      .{ .ext = "markdown", .cat = .doc },
        .{ .ext = "rst", .cat = .doc },     .{ .ext = "txt", .cat = .doc },
        .{ .ext = "log", .cat = .doc },     .{ .ext = "doc", .cat = .doc },
        .{ .ext = "docx", .cat = .doc },
        // binaries
        .{ .ext = "o", .cat = .binary },    .{ .ext = "a", .cat = .binary },
        .{ .ext = "so", .cat = .binary },   .{ .ext = "dylib", .cat = .binary },
        .{ .ext = "dll", .cat = .binary },  .{ .ext = "exe", .cat = .binary },
    };
    for (map) |entry| {
        if (eqlAsciiIgnoreCase(ext, entry.ext)) return entry.cat;
    }
    return null;
}

fn unicodeForPath(path: []const u8) Icon {
    if (path.len == 0) return unicodeIcon(.plain);
    if (path[path.len - 1] == '/') return unicodeIcon(.folder);

    const name = basename(path);

    // A few exact-name overrides for the unicode theme.
    if (eqlAsciiIgnoreCase(name, ".gitignore") or
        eqlAsciiIgnoreCase(name, ".gitattributes") or
        eqlAsciiIgnoreCase(name, ".gitmodules") or
        eqlAsciiIgnoreCase(name, ".git"))
        return unicodeIcon(.config);
    if (eqlAsciiIgnoreCase(name, "makefile") or
        eqlAsciiIgnoreCase(name, "dockerfile"))
        return unicodeIcon(.config);

    const ext = extension(name);
    if (ext.len > 0) {
        if (extCategory(ext)) |cat| return unicodeIcon(cat);
    }
    return unicodeIcon(.plain);
}

test "extension extraction" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings("zig", extension("main.zig"));
    try expectEqualStrings("gz", extension("foo.tar.gz"));
    try expectEqualStrings("", extension("README"));
    try expectEqualStrings("", extension(".env"));
    try expectEqualStrings("md", extension(".readme.md"));
}

test "fancy: by-name match wins over extension" {
    const ic = forPath("path/to/Cargo.toml", .fancy);
    const expected: []const u8 = "\u{e68b}";
    try std.testing.expectEqualStrings(expected, ic.glyph);
}

test "fancy: extension match" {
    const ic = forPath("src/main.zig", .fancy);
    const expected: []const u8 = "\u{e6a9}";
    try std.testing.expectEqualStrings(expected, ic.glyph);
}

test "fancy: fallback for unknown" {
    const ic = forPath("foo.unknownext", .fancy);
    try std.testing.expectEqualStrings(default_file.glyph, ic.glyph);
}

test "fancy: directory by trailing slash" {
    const ic = forPath("src/", .fancy);
    try std.testing.expectEqualStrings(default_dir.glyph, ic.glyph);
}

test "unicode: code category" {
    const ic = forPath("src/main.zig", .unicode);
    try std.testing.expectEqualStrings(unicodeIcon(.code).glyph, ic.glyph);
}

test "unicode: image category" {
    const ic = forPath("a/b/c.png", .unicode);
    try std.testing.expectEqualStrings(unicodeIcon(.image).glyph, ic.glyph);
}

test "unicode: directory" {
    const ic = forPath("src/", .unicode);
    try std.testing.expectEqualStrings(unicodeIcon(.folder).glyph, ic.glyph);
}

test "unicode: fallback plain" {
    const ic = forPath("foo.unknownext", .unicode);
    try std.testing.expectEqualStrings(unicodeIcon(.plain).glyph, ic.glyph);
}
