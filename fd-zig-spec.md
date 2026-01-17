# fd-zig: Specification for Porting fd to Zig

## Executive Summary

This document specifies the design for implementing **fd-zig**, a file-finding utility similar to the popular Rust-based `fd` tool, but written in Zig. The implementation will be a standalone module that integrates with the existing `nom` project while remaining independent of the core fuzzy matching functionality.

## 1. Overview of fd

**fd** (https://github.com/sharkdp/fd) is a fast, user-friendly alternative to the Unix `find` command. Key characteristics:

- **Fast**: Parallelized directory traversal using the `ignore` crate
- **Smart defaults**: Ignores hidden files, respects `.gitignore` by default
- **User-friendly**: Simpler syntax than `find`, colorized output
- **Cross-platform**: Works on Linux, macOS, and Windows

### Core Features

| Feature | Description |
|---------|-------------|
| Pattern matching | Regex (default), glob, or fixed string |
| Smart case | Case-insensitive unless pattern has uppercase |
| File type filtering | Files, directories, symlinks, executables, empty, devices |
| Size filtering | `+1k`, `-10m`, `100b` (min, max, exact) |
| Time filtering | `--changed-within 2d`, `--changed-before 2024-01-01` |
| Owner filtering | `--owner john:staff` (Unix only) |
| Ignore support | `.gitignore`, `.fdignore`, `.ignore`, global ignore |
| Command execution | `--exec`, `--exec-batch` |
| Output formatting | Colors, hyperlinks, custom templates |

## 2. Current State in nom

The `nom` project already has basic fd-like functionality in `src/files.zig`:

### Existing Implementation

```
files.zig (598 lines)
├── GitignorePattern - Compiled .gitignore pattern
├── globMatch() - Glob pattern matching (*, **, ?, [...])
├── Gitignore - Pattern manager for single directory
├── RecursiveWalker - Stack-based directory traversal
└── StreamingWalker - Background threaded walker for TUI
```

**What works:**
- Skips hidden files (files starting with `.`)
- Respects `.gitignore` with proper semantics (last-match-wins, negations, anchoring)
- Efficient stack-based traversal that prunes ignored directories
- Streaming integration with the TUI

**What's missing (for full fd parity):**
- Pattern matching against file names (regex, glob, fixed string)
- File type filtering (file, directory, symlink, executable, etc.)
- Size constraints
- Time constraints
- Max/min depth limiting
- Extension filtering
- Multiple root directories
- Output formatting and colorization
- Command execution (`--exec`, `--exec-batch`)
- `.fdignore` support
- Global ignore file support
- Symlink handling options
- Parallel traversal

## 3. Design Goals

1. **Independence**: fd-zig should work as a standalone CLI tool or be usable as a library
2. **Integration**: Should integrate smoothly with nom's existing `files.zig` for the streaming walker
3. **Simplicity**: Focus on the most-used 80% of fd features first
4. **Performance**: Match or exceed fd's performance through parallel traversal
5. **Zero dependencies**: Use only Zig's standard library (consistent with nom's approach)

## 4. Architecture

### Module Structure

```
src/
├── fd/
│   ├── fd.zig          # Main module, public API, CLI
│   ├── pattern.zig     # Pattern matching (regex, glob, fixed)
│   ├── filter.zig      # File filtering (type, size, time, extension)
│   ├── walker.zig      # Parallel directory walker
│   ├── ignore.zig      # Ignore file handling (.gitignore, .fdignore)
│   ├── output.zig      # Output formatting (colors, templates)
│   └── exec.zig        # Command execution (--exec, --exec-batch)
├── files.zig           # Existing walker (may import from fd/)
└── ...
```

### Core Components

#### 4.1 Pattern Matching (`pattern.zig`)

```zig
pub const PatternKind = enum {
    regex,
    glob,
    fixed,
};

pub const Pattern = struct {
    kind: PatternKind,
    case_sensitive: bool,
    full_path: bool,     // Match against full path vs basename

    // Internal representation depends on kind
    compiled: union(PatternKind) {
        regex: RegexMatcher,
        glob: GlobMatcher,
        fixed: []const u8,
    },

    pub fn init(pattern: []const u8, kind: PatternKind, options: Options) !Pattern;
    pub fn matches(self: Pattern, text: []const u8) bool;
    pub fn deinit(self: *Pattern) void;
};
```

**Smart case detection**: If pattern contains uppercase, use case-sensitive matching.

**Regex implementation**: For simplicity, start with the existing `globMatch` function expanded to handle more patterns. Consider a simple NFA-based regex engine for basic regex support, or use POSIX regex via `std.c`.

#### 4.2 File Filtering (`filter.zig`)

```zig
pub const FileType = packed struct {
    file: bool = false,
    directory: bool = false,
    symlink: bool = false,
    executable: bool = false,
    empty: bool = false,
    socket: bool = false,
    pipe: bool = false,
    block_device: bool = false,
    char_device: bool = false,
};

pub const SizeFilter = struct {
    pub const Mode = enum { min, max, exact };
    bytes: u64,
    mode: Mode,

    pub fn parse(spec: []const u8) !SizeFilter;
    pub fn matches(self: SizeFilter, size: u64) bool;
};

pub const TimeFilter = struct {
    pub const Mode = enum { newer, older };
    timestamp: i64,  // Unix timestamp
    mode: Mode,

    pub fn parse(spec: []const u8) !TimeFilter;
    pub fn matches(self: TimeFilter, mtime: i64) bool;
};

pub const Filter = struct {
    file_types: ?FileType = null,
    extensions: ?[]const []const u8 = null,
    size_filters: []const SizeFilter = &.{},
    time_filters: []const TimeFilter = &.{},
    min_depth: ?usize = null,
    max_depth: ?usize = null,

    pub fn matches(self: Filter, entry: Entry, depth: usize) !bool;
};
```

#### 4.3 Directory Walker (`walker.zig`)

```zig
pub const WalkOptions = struct {
    // Ignore behavior
    ignore_hidden: bool = true,
    read_gitignore: bool = true,
    read_fdignore: bool = true,
    read_global_ignore: bool = true,
    require_git: bool = true,

    // Traversal behavior
    follow_symlinks: bool = false,
    one_file_system: bool = false,
    max_depth: ?usize = null,
    min_depth: ?usize = null,

    // Parallelism
    threads: usize = 0,  // 0 = auto-detect

    // Filtering
    exclude_patterns: []const []const u8 = &.{},
    custom_ignore_files: []const []const u8 = &.{},
};

pub const Entry = struct {
    path: []const u8,      // Full path
    name: []const u8,      // Basename
    depth: usize,
    kind: std.fs.Dir.Entry.Kind,
    metadata: ?std.fs.File.Stat = null,  // Lazy-loaded

    pub fn getMetadata(self: *Entry) !std.fs.File.Stat;
};

pub const Walker = struct {
    pub fn init(allocator: Allocator, roots: []const []const u8, options: WalkOptions) !Walker;
    pub fn next(self: *Walker) !?Entry;
    pub fn deinit(self: *Walker) void;
};

// Parallel version using thread pool
pub const ParallelWalker = struct {
    pub fn init(allocator: Allocator, roots: []const []const u8, options: WalkOptions) !ParallelWalker;
    pub fn run(self: *ParallelWalker, callback: fn(Entry) void) !void;
    pub fn deinit(self: *ParallelWalker) void;
};
```

#### 4.4 Ignore File Handling (`ignore.zig`)

Extend the existing gitignore handling to support:

```zig
pub const IgnoreKind = enum {
    gitignore,
    fdignore,
    ignore,  // ripgrep-style
};

pub const IgnoreStack = struct {
    // Stack of ignore patterns from root to current directory
    levels: []IgnoreLevel,
    global_ignores: ?Gitignore,

    pub fn init(allocator: Allocator, options: IgnoreOptions) !IgnoreStack;
    pub fn pushDir(self: *IgnoreStack, dir: std.fs.Dir, path: []const u8) !void;
    pub fn popDir(self: *IgnoreStack) void;
    pub fn isIgnored(self: IgnoreStack, name: []const u8, rel_path: []const u8, is_dir: bool) bool;
};
```

#### 4.5 Output Formatting (`output.zig`)

```zig
pub const OutputFormat = struct {
    color: ColorMode = .auto,
    hyperlinks: bool = false,
    null_separator: bool = false,
    path_separator: ?[]const u8 = null,
    template: ?FormatTemplate = null,

    pub fn format(self: OutputFormat, entry: Entry, writer: anytype) !void;
};

pub const ColorMode = enum { auto, always, never };

pub const FormatTemplate = struct {
    // Parsed template with tokens: {}, {/}, {//}, {.}, {/.}
    tokens: []Token,

    pub fn parse(template: []const u8) !FormatTemplate;
    pub fn apply(self: FormatTemplate, path: []const u8, writer: anytype) !void;
};
```

#### 4.6 Command Execution (`exec.zig`)

```zig
pub const ExecMode = enum { each, batch };

pub const CommandTemplate = struct {
    args: []const []const u8,
    placeholders: []PlaceholderInfo,

    pub fn parse(args: []const []const u8) !CommandTemplate;
    pub fn execute(self: CommandTemplate, paths: []const []const u8) !u8;
};

pub const Executor = struct {
    mode: ExecMode,
    template: CommandTemplate,
    batch_size: usize = 0,  // 0 = auto (based on ARG_MAX)

    pub fn run(self: Executor, paths: []const []const u8) !u8;
};
```

### 4.7 Main CLI (`fd.zig`)

```zig
pub const Config = struct {
    // Search
    pattern: ?[]const u8 = null,
    pattern_kind: PatternKind = .regex,
    case_sensitive: ?bool = null,  // null = smart case
    full_path: bool = false,

    // Filtering
    filter: Filter = .{},

    // Traversal
    walk_options: WalkOptions = .{},
    roots: []const []const u8 = &.{"."},

    // Output
    output: OutputFormat = .{},
    quiet: bool = false,
    max_results: ?usize = null,

    // Execution
    exec: ?Executor = null,
};

pub fn run(allocator: Allocator, config: Config) !ExitCode;
pub fn parseArgs(allocator: Allocator) !Config;
```

## 5. Implementation Phases

### Phase 1: Core Walking (MVP)
- [x] Basic directory walking (exists in `files.zig`)
- [x] Hidden file filtering (exists)
- [x] `.gitignore` support (exists)
- [ ] Glob pattern matching for file names
- [ ] Max/min depth limiting
- [ ] Extension filtering

### Phase 2: Enhanced Filtering
- [ ] File type filtering (file, dir, symlink, executable, empty)
- [ ] Size constraints
- [ ] Time constraints
- [ ] Multiple root directories

### Phase 3: Advanced Features
- [ ] Regex pattern matching
- [ ] `.fdignore` support
- [ ] Global ignore file (`~/.config/fd/ignore`)
- [ ] Exclude patterns (`--exclude`)
- [ ] Follow symlinks option

### Phase 4: Output & Execution
- [ ] Colorized output (LS_COLORS)
- [ ] Custom format templates
- [ ] `--exec` command execution
- [ ] `--exec-batch` batch execution
- [ ] Null-separated output

### Phase 5: Performance
- [ ] Parallel traversal with thread pool
- [ ] Backpressure and result buffering
- [ ] Early termination on max results

## 6. CLI Interface

Match fd's CLI for familiarity:

```
fd-zig [FLAGS/OPTIONS] [<pattern>] [<path>...]

FLAGS:
    -H, --hidden            Include hidden files
    -I, --no-ignore         Don't respect ignore files
    -s, --case-sensitive    Case-sensitive search
    -i, --ignore-case       Case-insensitive search
    -g, --glob              Glob-based search
    -F, --fixed-strings     Treat pattern as literal
    -a, --absolute-path     Show absolute paths
    -l, --list-details      Use long listing format
    -L, --follow            Follow symlinks
    -p, --full-path         Match against full path
    -0, --print0            Null-separated output
    -1                      Stop after first match
    -q, --quiet             Quiet mode (exit code only)

OPTIONS:
    -d, --max-depth <num>   Max directory depth
    --min-depth <num>       Min directory depth
    -t, --type <type>       Filter by type (f,d,l,x,e,s,p,b,c)
    -e, --extension <ext>   Filter by extension
    -S, --size <spec>       Filter by size (+1k, -10m)
    --changed-within <dur>  Files changed recently
    --changed-before <dur>  Files changed before
    -E, --exclude <pattern> Exclude pattern
    -j, --threads <num>     Number of threads
    -x, --exec <cmd>        Execute command for each result
    -X, --exec-batch <cmd>  Execute command with batch

ARGS:
    <pattern>    Search pattern (regex by default)
    <path>...    Root directories to search (default: .)
```

## 7. Integration with nom

The fd-zig implementation can be integrated with nom in two ways:

### Option A: Extend existing `files.zig`
- Add pattern matching and filtering to `RecursiveWalker`
- Keep the streaming interface for TUI integration
- Minimal code changes

### Option B: New `fd/` module
- Clean separation of concerns
- `files.zig` imports from `fd/walker.zig`
- More modular, testable

**Recommendation**: Option B for cleaner architecture, with the ability to use fd-zig standalone or as a library.

## 8. Differences from fd

For pragmatic reasons, some fd features may be deferred or simplified:

| Feature | fd | fd-zig (initial) |
|---------|-----|------------------|
| Regex | Full PCRE2 | Basic regex or glob-only |
| Parallelism | `ignore` crate | Simple thread pool |
| Smart case | Pattern AST analysis | Simple uppercase check |
| LS_COLORS | Full support | Basic/optional |
| Windows | Full support | Unix-first, Windows later |
| Jemalloc | Yes | No (use GPA) |

## 9. Testing Strategy

1. **Unit tests**: Pattern matching, filtering, ignore parsing
2. **Integration tests**: Full directory walks with known structure
3. **Compatibility tests**: Compare output with fd on same inputs
4. **Performance benchmarks**: Compare with fd, find, and existing walker

## 10. Success Criteria

1. Can find files by pattern (glob or regex)
2. Respects `.gitignore` and `.fdignore`
3. Filters by type, extension, size, time
4. Performance within 2x of fd for typical workloads
5. Works as standalone CLI and as library for nom
