//! Benchmarks for the nom fuzzy matcher.
//!
//! Run with: zig build bench

const std = @import("std");
const Matcher = @import("matcher.zig").Matcher;
const Config = @import("config.zig").Config;
const Utf32Str = @import("utf32_str.zig").Utf32Str;
const prefilter = @import("prefilter.zig");

const WARMUP_ITERATIONS = 1000;
const BENCH_ITERATIONS = 100_000;

/// Benchmark result
const BenchResult = struct {
    name: []const u8,
    min_ns: u64,
    max_ns: u64,
    avg_ns: u64,
    ops_per_sec: f64,
    iterations: usize,
};

fn benchmark(comptime name: []const u8, iterations: usize, comptime func: anytype) BenchResult {
    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        std.mem.doNotOptimizeAway(@call(.never_inline, func, .{}));
    }

    var timer = std.time.Timer.start() catch unreachable;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    // Run batches of 100 iterations
    const batch_size = 100;
    const num_batches = iterations / batch_size;

    for (0..num_batches) |_| {
        timer.reset();
        for (0..batch_size) |_| {
            std.mem.doNotOptimizeAway(@call(.never_inline, func, .{}));
        }
        const elapsed = timer.read();
        const per_iter = elapsed / batch_size;
        min_ns = @min(min_ns, per_iter);
        max_ns = @max(max_ns, per_iter);
        total_ns += elapsed;
    }

    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0);

    return .{
        .name = name,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
        .iterations = iterations,
    };
}

fn printResult(result: BenchResult) void {
    std.debug.print("{s:<45} avg: {d:>6} ns  min: {d:>6} ns  max: {d:>8} ns  {d:>12.0} ops/s\n", .{
        result.name,
        result.avg_ns,
        result.min_ns,
        result.max_ns,
        result.ops_per_sec,
    });
}

// ============================================================
// Test Data
// ============================================================

// Short strings (typical filename)
const SHORT_HAYSTACK = "main.zig";
const SHORT_NEEDLE = "mz";

// Medium strings (typical path)
const MEDIUM_HAYSTACK = "src/components/ui/button/Button.tsx";
const MEDIUM_NEEDLE = "button";

// Long strings (full file path)
const LONG_HAYSTACK = "/Users/developer/projects/my-awesome-project/src/components/authentication/login/LoginForm.tsx";
const LONG_NEEDLE = "logform";

// Very long needle (stress test)
const STRESS_HAYSTACK = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" ** 4;
const STRESS_NEEDLE = "aeiouAEIOU12345";

// Worst case: needle chars spread far apart
const WORST_HAYSTACK = "a" ++ ("x" ** 100) ++ "b" ++ ("y" ** 100) ++ "c" ++ ("z" ** 100) ++ "d";
const WORST_NEEDLE = "abcd";

// No match case
const NOMATCH_HAYSTACK = "hello world this is a test string";
const NOMATCH_NEEDLE = "xyz123";

// Prefilter specific: long string with target at end
const PREFILTER_HAYSTACK = ("x" ** 500) ++ "needle" ++ ("y" ** 500);
const PREFILTER_NEEDLE = "needle";

// Long haystack for char search
const LONG_SEARCH_HAYSTACK = "a" ** 1000 ++ "z";

/// Helper to create ASCII Utf32Str without allocation
fn asciiStr(comptime s: []const u8) Utf32Str {
    return .{ .ascii = s };
}

// Global matcher for benchmarks - avoids allocation overhead in measurements
var global_matcher: Matcher = undefined;
var matcher_initialized = false;

fn getGlobalMatcher() *Matcher {
    if (!matcher_initialized) {
        global_matcher = Matcher.initDefault(std.heap.page_allocator) catch unreachable;
        matcher_initialized = true;
    }
    return &global_matcher;
}

// Runtime buffers to prevent compiler from optimizing out operations on comptime strings
var runtime_short_haystack: [SHORT_HAYSTACK.len]u8 = SHORT_HAYSTACK.*;
var runtime_medium_haystack: [MEDIUM_HAYSTACK.len]u8 = MEDIUM_HAYSTACK.*;
var runtime_long_haystack: [LONG_HAYSTACK.len]u8 = LONG_HAYSTACK.*;
var runtime_long_search: [LONG_SEARCH_HAYSTACK.len]u8 = LONG_SEARCH_HAYSTACK.*;
var runtime_nomatch_haystack: [NOMATCH_HAYSTACK.len]u8 = NOMATCH_HAYSTACK.*;
var runtime_prefilter_haystack: [PREFILTER_HAYSTACK.len]u8 = PREFILTER_HAYSTACK.*;

var runtime_short_needle: [SHORT_NEEDLE.len]u8 = SHORT_NEEDLE.*;
var runtime_medium_needle: [MEDIUM_NEEDLE.len]u8 = MEDIUM_NEEDLE.*;
var runtime_long_needle: [LONG_NEEDLE.len]u8 = LONG_NEEDLE.*;
var runtime_nomatch_needle: [NOMATCH_NEEDLE.len]u8 = NOMATCH_NEEDLE.*;
var runtime_prefilter_needle: [PREFILTER_NEEDLE.len]u8 = PREFILTER_NEEDLE.*;

// For case insensitive comparison benchmarks
var case_upper: [35]u8 = "SRC/COMPONENTS/UI/BUTTON/BUTTON.TSX".*;
var case_lower: [35]u8 = "src/components/ui/button/button.tsx".*;
var case_short_a: [5]u8 = "HELLO".*;
var case_short_b: [5]u8 = "hello".*;
var case_medium_a: [16]u8 = "TheQuickBrownFox".*;
var case_medium_b: [16]u8 = "thequickbrownfox".*;

fn runtimeStr(s: []u8) Utf32Str {
    return .{ .ascii = s };
}

pub fn main() !void {
    std.debug.print("\n=== Nom Fuzzy Matcher Benchmarks ===\n\n", .{});
    std.debug.print("Iterations per benchmark: {}\n\n", .{BENCH_ITERATIONS});

    // ============================================================
    // Prefilter Benchmarks (direct function calls) - SIMD candidates
    // ============================================================
    std.debug.print("--- Prefilter (ASCII) - SIMD Candidate ---\n", .{});

    printResult(benchmark("prefilter: short (8 chars)", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            const cfg = Config.default();
            const result = prefilter.prefilterAscii(&cfg, &runtime_short_haystack, &runtime_short_needle, false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    printResult(benchmark("prefilter: medium (36 chars)", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            const cfg = Config.default();
            const result = prefilter.prefilterAscii(&cfg, &runtime_medium_haystack, &runtime_medium_needle, false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    printResult(benchmark("prefilter: long (96 chars)", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            const cfg = Config.default();
            const result = prefilter.prefilterAscii(&cfg, &runtime_long_haystack, &runtime_long_needle, false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    printResult(benchmark("prefilter: 1006 chars", BENCH_ITERATIONS, struct {
        fn run() usize {
            const cfg = Config.default();
            const result = prefilter.prefilterAscii(&cfg, &runtime_prefilter_haystack, &runtime_prefilter_needle, false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    printResult(benchmark("prefilter: 1001 chars (target at end)", BENCH_ITERATIONS, struct {
        fn run() usize {
            const cfg = Config.default();
            const result = prefilter.prefilterAscii(&cfg, &runtime_long_search, "z", false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    printResult(benchmark("prefilter: no match", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            const cfg = Config.default();
            const result = prefilter.prefilterAscii(&cfg, &runtime_nomatch_haystack, &runtime_nomatch_needle, false);
            return if (result) |r| r.start else std.math.maxInt(usize);
        }
    }.run));

    printResult(benchmark("prefilter: case-sensitive short", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            var cfg = Config.default();
            cfg.ignore_case = false;
            const result = prefilter.prefilterAscii(&cfg, &runtime_short_haystack, &runtime_short_needle, false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    printResult(benchmark("prefilter: case-sensitive medium", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            var cfg = Config.default();
            cfg.ignore_case = false;
            const result = prefilter.prefilterAscii(&cfg, &runtime_medium_haystack, &runtime_medium_needle, false);
            return if (result) |r| r.start else 0;
        }
    }.run));

    // ============================================================
    // memchr-style search comparison (what prefilter uses internally)
    // ============================================================
    std.debug.print("\n--- Character Search (std.mem) ---\n", .{});

    printResult(benchmark("std.mem.indexOfScalar: short (8)", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            return std.mem.indexOfScalar(u8, &runtime_short_haystack, 'z') orelse std.math.maxInt(usize);
        }
    }.run));

    printResult(benchmark("std.mem.indexOfScalar: medium (36)", BENCH_ITERATIONS * 10, struct {
        fn run() usize {
            return std.mem.indexOfScalar(u8, &runtime_medium_haystack, 'x') orelse std.math.maxInt(usize);
        }
    }.run));

    printResult(benchmark("std.mem.indexOfScalar: 1001 chars", BENCH_ITERATIONS, struct {
        fn run() usize {
            return std.mem.indexOfScalar(u8, &runtime_long_search, 'z') orelse std.math.maxInt(usize);
        }
    }.run));

    printResult(benchmark("std.mem.lastIndexOfScalar: 1001 chars", BENCH_ITERATIONS, struct {
        fn run() usize {
            return std.mem.lastIndexOfScalar(u8, &runtime_long_search, 'a') orelse std.math.maxInt(usize);
        }
    }.run));

    // ============================================================
    // Fuzzy Match Benchmarks (full matching)
    // ============================================================
    std.debug.print("\n--- Fuzzy Match (full) ---\n", .{});

    const matcher = getGlobalMatcher();

    printResult(benchmark("fuzzy: short string (8 chars)", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_short_haystack);
            const n = runtimeStr(&runtime_short_needle);
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("fuzzy: medium string (36 chars)", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = runtimeStr(&runtime_medium_needle);
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("fuzzy: long string (96 chars)", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_long_haystack);
            const n = runtimeStr(&runtime_long_needle);
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("fuzzy: stress (248 chars, 15 needle)", BENCH_ITERATIONS / 10, struct {
        fn run() u16 {
            const h = asciiStr(STRESS_HAYSTACK);
            const n = asciiStr(STRESS_NEEDLE);
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("fuzzy: worst case spread (305 chars)", BENCH_ITERATIONS / 10, struct {
        fn run() u16 {
            const h = asciiStr(WORST_HAYSTACK);
            const n = asciiStr(WORST_NEEDLE);
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("fuzzy: no match", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_nomatch_haystack);
            const n = runtimeStr(&runtime_nomatch_needle);
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    // ============================================================
    // Substring Match Benchmarks
    // ============================================================
    std.debug.print("\n--- Substring Match ---\n", .{});

    printResult(benchmark("substring: short string", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_short_haystack);
            const n = asciiStr("main");
            return getGlobalMatcher().substringMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("substring: medium string", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = runtimeStr(&runtime_medium_needle);
            return getGlobalMatcher().substringMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("substring: 1006 chars", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_prefilter_haystack);
            const n = runtimeStr(&runtime_prefilter_needle);
            return getGlobalMatcher().substringMatch(h, n) orelse 0;
        }
    }.run));

    // ============================================================
    // Single Character Match (very common case)
    // ============================================================
    std.debug.print("\n--- Single Character Match ---\n", .{});

    printResult(benchmark("single char fuzzy: medium", BENCH_ITERATIONS * 10, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = asciiStr("b");
            return getGlobalMatcher().fuzzyMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("single char substring: medium", BENCH_ITERATIONS * 10, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = asciiStr("b");
            return getGlobalMatcher().substringMatch(h, n) orelse 0;
        }
    }.run));

    // ============================================================
    // Exact/Prefix/Postfix Match
    // ============================================================
    std.debug.print("\n--- Exact/Prefix/Postfix Match ---\n", .{});

    printResult(benchmark("exact: medium string", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = runtimeStr(&runtime_medium_haystack);
            return getGlobalMatcher().exactMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("prefix: medium string", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = asciiStr("src/comp");
            return getGlobalMatcher().prefixMatch(h, n) orelse 0;
        }
    }.run));

    printResult(benchmark("postfix: medium string", BENCH_ITERATIONS, struct {
        fn run() u16 {
            const h = runtimeStr(&runtime_medium_haystack);
            const n = asciiStr(".tsx");
            return getGlobalMatcher().postfixMatch(h, n) orelse 0;
        }
    }.run));

    // ============================================================
    // Case-insensitive comparison (SIMD candidate)
    // ============================================================
    std.debug.print("\n--- Case-Insensitive Compare (SIMD Candidate) ---\n", .{});

    printResult(benchmark("ascii eql ignore case: 5 chars", BENCH_ITERATIONS * 10, struct {
        fn run() bool {
            return asciiEqualIgnoreCase(&case_short_a, &case_short_b);
        }
    }.run));

    printResult(benchmark("ascii eql ignore case: 16 chars", BENCH_ITERATIONS * 10, struct {
        fn run() bool {
            return asciiEqualIgnoreCase(&case_medium_a, &case_medium_b);
        }
    }.run));

    printResult(benchmark("ascii eql ignore case: 35 chars", BENCH_ITERATIONS * 10, struct {
        fn run() bool {
            return asciiEqualIgnoreCase(&case_upper, &case_lower);
        }
    }.run));

    std.debug.print("\n=== Benchmarks Complete ===\n\n", .{});

    _ = matcher;
}

// Copy from matcher.zig for benchmarking
fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}
