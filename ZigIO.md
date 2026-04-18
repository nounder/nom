# Zig 0.16.0 — std.Io Reference

A working reference for the new I/O interface introduced across Zig 0.15.1 and 0.16.0. The headline change: **all I/O now flows through an explicit `Io` instance**, and the stream types (`Reader`, `Writer`) are concrete, non-generic, buffer-owning interfaces.

### Primary sources

- Release notes:
  [0.16.0](https://ziglang.org/download/0.16.0/release-notes.html) · [0.15.1](https://ziglang.org/download/0.15.1/release-notes.html)
- Standard library docs (0.16.0): <https://ziglang.org/documentation/0.16.0/std/>
  - Docs are a client-rendered SPA — deep-link via the fragment, e.g. `#std.Io.Reader`.
- Language reference: <https://ziglang.org/documentation/0.16.0/>

> **URL pattern:** `https://ziglang.org/documentation/0.16.0/std/#<fully.qualified.name>`
> — the fragment is interpreted client-side, so these links open the specific decl.

---

## 1. The big picture

### Two major layers

1. **[`std.Io`](https://ziglang.org/documentation/0.16.0/std/#std.Io)** (0.16.0): A first-class, pluggable *runtime* interface. All file, network, process, time, randomness, and synchronization APIs require an `Io` instance. Implementations:
   - [`Io.Threaded`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Threaded) — default, works with `-fsingle-threaded` or multi-threaded
   - [`Io.Evented`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Evented) — WIP userspace stack-switching
   - [`Io.Uring`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Uring) — Linux io_uring PoC
   - [`Io.Kqueue`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Kqueue) — macOS PoC
   - [`Io.Dispatch`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Dispatch) — Grand Central Dispatch
   - [`Io.failing`](https://ziglang.org/documentation/0.16.0/std/#std.Io.failing) — no-op

2. **[`std.Io.Reader`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader) / [`std.Io.Writer`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer)** (0.15.1): Concrete, non-generic stream interfaces. Buffer lives *in* the interface, not the implementation. Vtable dispatch on cold path; hot path operates directly on the buffer.

### Why the redesign

- **No more `anytype` generic poisoning** — consumers take `*std.Io.Reader` / `*std.Io.Writer`.
- **Buffer in the interface** — one layer instead of `Buffered(File).Reader` nesting.
- **Rich primitives** — vectored IO, byte splatting, `sendFile` (zero-copy), `peek`.
- **Precise error sets** — no `anyerror`-ish passthroughs.

---

## 2. The "juicy main"

Docs: [`std.process.Init`](https://ziglang.org/documentation/0.16.0/std/#std.process.Init)

New entry-point signature provides pre-initialized process resources:

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;                     // general-purpose allocator
    const arena = init.arena;                 // *ArenaAllocator — lives for process
    const io = init.io;                       // Io — default implementation
    const environ_map = init.environ_map;     // *Environ.Map
    // `init.preop` — parent-provided named files
}
```

If you need an `Io` outside `main`:

```zig
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

In tests:

```zig
const io = std.testing.io;
```

---

## 3. std.Io.Writer

Docs: [`std.Io.Writer`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer) · [`Writer.Error`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.Error)

### Concrete type, buffer-owning

A `*std.Io.Writer` wraps a caller-provided buffer plus a vtable. The hot path is inline buffer append; flush drains via the vtable.

### Getting a writer

**stdout / stderr / stdin** — `std.debug.getStdOut()` etc. are gone. Use [`std.fs.File.stdout()`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.stdout) and attach a writer:

```zig
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout: *std.Io.Writer = &stdout_writer.interface;

try stdout.print("Run `zig build test` to run the tests.\n", .{});
try stdout.flush();   // CRITICAL — buffered writers don't auto-flush
```

**Files**:

```zig
const file = try cwd.openFile("data.bin", .{});
var buf: [4096]u8 = undefined;
var fw = file.writer(&buf);
const w: *std.Io.Writer = &fw.interface;
```

### Core Writer methods

| Method | Purpose | Doc |
|---|---|---|
| `writeAll(bytes)` | Write entire slice | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.writeAll) |
| `writeByte(b)` | Write single byte | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.writeByte) |
| `writeInt(T, val, endian)` | Write typed integer | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.writeInt) |
| `print(fmt, args)` | Formatted print (replaces old `fmt.format`) | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.print) |
| `flush()` | Drain buffered data to downstream | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.flush) |
| `splatByteAll(byte, n)` | Repeat byte N times (O(M) over M streams, not O(M·N)) | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.splatByteAll) |
| `splatNumber(val, n)` | Repeat numeric pattern | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.splatNumber) |
| `sendFile(file_reader, limit)` | Zero-copy file → writer (uses `sendfile()` where available) | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.sendFile) |
| `sendFileAll(file_reader)` | Complete `sendFile` | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.sendFileAll) |

### Specialized writers

**[`Writer.Allocating`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.Allocating)** — grows a managed buffer; subsumes old `CountingWriter`:

```zig
var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
const w: *std.Io.Writer = &aw.writer;
try w.print("hello {s}", .{"world"});
const bytes = aw.written();   // slice into owned buffer
const n = aw.writer.end;      // bytes written
```

**[`Writer.Discarding`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.Discarding)** — sink that counts and drops; replaces `CountingWriter` for throwaway:

```zig
var dw: std.Io.Writer.Discarding = .init;
const w: *std.Io.Writer = &dw.writer;
try w.writeAll("drop me");
const total = dw.count;
```

**[`Writer.fixed`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.fixed)** — wraps a fixed stack buffer (replaces bounded-array buffering):

```zig
var buf: [256]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
try w.print("n={d}", .{42});
const written = buf[0..w.end];
```

### Adapting an old-API writer

```zig
fn foo(old_writer: anytype) !void {
    var adapter = old_writer.adaptToNewApi(&.{});
    const w: *std.Io.Writer = &adapter.new_interface;
    try w.print("{s}", .{"example"});
}
```

---

## 4. std.Io.Reader

Docs: [`std.Io.Reader`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader) · [`Reader.Error`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.Error)

### Core Reader methods

| Method | Purpose | Doc |
|---|---|---|
| `readSliceShort(dst)` | Read up to `dst.len` bytes; may return fewer | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.readSliceShort) |
| `readSliceAll(dst)` | Read exactly `dst.len` or error | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.readSliceAll) |
| `readByte()` | One byte | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.readByte) |
| `readInt(T, endian)` | Typed integer | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.readInt) |
| `readVarInt(T, endian, max_bytes)` | Variable-length int | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.readVarInt) |
| `takeBuffered()` | Borrow current buffer slice without consuming | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.takeBuffered) |
| `peek(n)` | Inspect next N bytes without advance | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.peek) |
| `takeDelimiterExclusive(delim)` | Slice up to (but not including) delimiter | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.takeDelimiterExclusive) |
| `discardAll(n)` | Skip N bytes efficiently (decoders can frame-skip) | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.discardAll) |
| `stream(writer, limit)` | Pump exact N bytes to writer | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.stream) |
| `streamExact(writer, n)` | Same, with strict length | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.streamExact) |
| `sendFile(writer, limit)` | Zero-copy reader → writer | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.sendFile) |
| `sendFileAll(writer)` | Complete sendFile | [↗](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.sendFileAll) |

### Line-by-line read

```zig
while (reader.takeDelimiterExclusive('\n')) |line| {
    // consume `line` — delimiter already stripped
} else |err| switch (err) {
    error.EndOfStream, error.StreamTooLong, error.ReadFailed => |e| return e,
}
```

### [`Reader.fixed`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.fixed) — read from an in-memory slice

```zig
var r = std.Io.Reader.fixed(bytes);
const b = try r.readByte();
```

### File.Reader memoization

[`std.fs.File.Reader`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.Reader) caches `stat()` results, seek position, and capability flags (positional vs streaming, fd-to-fd `sendfile` support) to avoid redundant syscalls on sequential reads:

```zig
var buf: [4096]u8 = undefined;
var fr = file.reader(&buf);
const r: *std.Io.Reader = &fr.interface;
```

---

## 5. Formatted printing

Docs: [`std.fmt`](https://ziglang.org/documentation/0.16.0/std/#std.fmt) · [`std.fmt.Alt`](https://ziglang.org/documentation/0.16.0/std/#std.fmt.Alt) · [`std.fmt.Options`](https://ziglang.org/documentation/0.16.0/std/#std.fmt.Options)

### New format method signature

```zig
// OLD (removed)
pub fn format(
    self: @This(),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void { ... }

// NEW
pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void { ... }
```

### `{}` no longer auto-dispatches to `format`

Using `{}` on a type with a `format()` method is now a compile error ("ambiguous format string"). Use `{f}`:

```zig
// wrong in 0.15+
std.debug.print("{}",  .{std.zig.fmtId("example")});
// right
std.debug.print("{f}", .{std.zig.fmtId("example")});
```

Use `-freference-trace` to surface all offenders.

### Picking an alternate formatter per call site

`std.fmt.FormatOptions` is gone. Three patterns:

**(a) Named alt method + `std.fmt.alt`:**

```zig
pub fn formatB(foo: Foo, w: *std.Io.Writer) std.Io.Writer.Error!void { ... }

// call:
try w.print("{f}", .{std.fmt.alt(Foo, .formatB)});
```

**(b) Wrapper struct via `std.fmt.Alt`:**

```zig
pub fn bar(foo: Foo, context: i32) std.fmt.Alt(F, F.baz) {
    return .{ .data = .{ .context = context } };
}
const F = struct {
    context: i32,
    pub fn baz(f: F, w: *std.Io.Writer) std.Io.Writer.Error!void { ... }
};

// call:
try w.print("{f}", .{foo.bar(1234)});
```

**(c) Struct whose `format` closes over config:**

```zig
pub fn bar(foo: Foo, context: i32) F {
    return .{ .context = context };
}
const F = struct {
    context: i32,
    pub fn format(f: F, w: *std.Io.Writer) std.Io.Writer.Error!void { ... }
};

// call:
try w.print("{f}", .{foo.bar(1234)});
```

### New / changed format specifiers

| Old | New |
|---|---|
| `fmtId`, `fmt.Formatter` dispatch | `{f}` explicit |
| `fmtSliceHexLower` | `{x}` |
| `fmtSliceHexUpper` | `{X}` |
| `fmtIntSizeDec` | `{B}` |
| `fmtIntSizeBin` | `{Bi}` |
| `fmtDuration` / `fmtDurationSigned` | `{D}` |
| `@tagName` / `@errorName` inline | `{t}` |
| custom numeric format | `{d}` → calls `formatNumber()` |
| — | `{b64}` for base64 |
| Unicode alignment | removed — ASCII / bytes only |

### Renames

- `fmt.Formatter` → `fmt.Alt`
- `fmt.format` → `std.Io.Writer.print`
- `fmt.FormatOptions` → `fmt.Options`
- `fmt.bufPrintZ` → `fmt.bufPrintSentinel`
- `fmtSliceEscapeLower/Upper` → `std.ascii.hexEscape`
- `std.zig.fmtEscapes` → `std.zig.fmtString`

---

## 6. File system — `std.Io.Dir` / `std.Io.File`

Docs: [`std.Io.Dir`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Dir) · [`std.Io.File`](https://ziglang.org/documentation/0.16.0/std/#std.Io.File) · [`std.Io.File.Permissions`](https://ziglang.org/documentation/0.16.0/std/#std.Io.File.Permissions)

Every fs call now takes `io`.

### Open & close

```zig
// old
const f = try std.fs.cwd().openFile("x", .{});
defer f.close();

// new
const cwd = std.Io.Dir.cwd();
const f = try cwd.openFile(io, "x", .{});
defer f.close(io);
```

### Method renames (non-exhaustive)

| Old | New |
|---|---|
| `fs.Dir` | `std.Io.Dir` |
| `fs.File` | `std.Io.File` |
| `fs.cwd` | `std.Io.Dir.cwd` |
| `fs.Dir.makeDir` | `std.Io.Dir.createDir` |
| `fs.Dir.makePath` | `std.Io.Dir.createDirPath` |
| `fs.File.setEndPos` | `std.Io.File.setLength` |
| `fs.File.getEndPos` | `std.Io.File.length` |
| `fs.File.read` | `std.Io.File.readStreaming` |
| `fs.File.write` | `std.Io.File.writeStreaming` |
| `fs.File.pread`/`preadv`/`preadAll` | `std.Io.File.readPositional[All]` |
| `fs.File.pwrite`/`pwritev`/`pwriteAll` | `std.Io.File.writePositional[All]` |
| `fs.File.seekTo` | `Reader.seekTo` / `Writer.seekTo` |
| `fs.File.seekBy` | `Reader.seekBy` |
| `fs.File.getPos` | `Reader.logicalPos` / `Writer.logicalPos` |
| `fs.File.chmod` | `setPermissions` |
| `fs.File.chown` | `setOwner` |
| `fs.File.updateTimes` | `setTimestamps[Now]` |
| `fs.File.Mode` | `std.Io.File.Permissions` |
| `fs.realpath[Alloc]` | `std.Io.Dir.realPathFileAbsolute[Alloc]` |
| `fs.Dir.realpath[Alloc]` | `std.Io.Dir.realPathFile[Alloc]` |
| `fs.rename` | `std.Io.Dir.rename` |
| `fs.Dir.atomicSymLink` | `symLinkAtomic` |
| `fs.path` | `std.Io.Dir.path` |

### Removed

- `fs.File.reader` → `fs.File.deprecatedReader` (new: `.reader(&buf)`)
- `fs.File.writer` → `fs.File.deprecatedWriter` (new: `.writer(&buf)`)
- `fs.File.readToEndAlloc` — read via reader interface
- `fs.File.writeFileAll` — write via writer interface
- All `…Z` and `…W` path variants
- All `…Absolute` variants (use `Dir.cwd()` plus relative)
- `fs.File.isCygwinPty`
- `fs.File.adaptToNewApi` / `Dir.adaptFromNewApi`

### Error renames

| Old | New |
|---|---|
| `error.RenameAcrossMountPoints` | `error.CrossDevice` |
| `error.NotSameFileSystem` | `error.CrossDevice` |
| `error.SharingViolation` | `error.FileBusy` |
| `error.EnvironmentVariableNotFound` | `error.EnvironmentVariableMissing` |

`std.Io.Dir.rename` now returns `error.DirNotEmpty` (not `error.PathAlreadyExists`).

### [`File.MemoryMap`](https://ziglang.org/documentation/0.16.0/std/#std.Io.File.MemoryMap)

Semantics tightened: pointer contents are synchronized **only at explicit sync points**. Enables fallback and evented-io implementations.

---

## 7. Networking — `std.Io.net`

Docs: [`std.Io.net`](https://ziglang.org/documentation/0.16.0/std/#std.Io.net) · [`std.http`](https://ziglang.org/documentation/0.16.0/std/#std.http) · [`std.http.Client`](https://ziglang.org/documentation/0.16.0/std/#std.http.Client) · [`std.http.Server`](https://ziglang.org/documentation/0.16.0/std/#std.http.Server)

### HTTP HEAD request (end-to-end example)

```zig
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const host_name: Io.net.HostName = try .init(args[1]);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var request = try http_client.request(.HEAD, .{
        .scheme = "http",
        .host = .{ .percent_encoded = host_name.bytes },
        .port = 80,
        .path = .{ .percent_encoded = "/" },
    }, .{});
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    const response = try request.receiveHead(&redirect_buffer);
    std.log.info("received {d} {s}", .{ response.head.status, response.head.reason });
}
```

Benefits of the new stack: async DNS, racing TCP attempts with cancel-on-first-success, works under `-fsingle-threaded`, no `ws2_32.dll` dependency on Windows.

### HTTP client body reading

**Old:**
```zig
var server_header_buffer: [1024]u8 = undefined;
var req = try client.open(.GET, uri, .{
    .server_header_buffer = &server_header_buffer,
});
defer req.deinit();
try req.send();
try req.wait();
const body_reader = try req.reader();
var it = req.response.iterateHeaders();
while (it.next()) |header| { _ = header.name; _ = header.value; }
```

**New:**
```zig
var req = try client.request(.GET, uri, .{});
defer req.deinit();
try req.sendBodiless();
var response = try req.receiveHead(&.{});

// IMPORTANT: response.head strings become invalid after reader() is called
var it = response.head.iterateHeaders();
while (it.next()) |header| { _ = header.name; _ = header.value; }

var reader_buffer: [100]u8 = undefined;
const body_reader = response.reader(&reader_buffer);
```

### HTTP server — now transport-agnostic

```zig
var recv_buffer: [4000]u8 = undefined;
var send_buffer: [4000]u8 = undefined;
var conn_reader = connection.stream.reader(&recv_buffer);
var conn_writer = connection.stream.writer(&send_buffer);
var server = std.http.Server.init(
    conn_reader.interface(),
    &conn_writer.interface,
);
```

No arbitrary header-count cap; reusable over any transport.

### Sockets

- `Io.net.Socket.createPair` — new.
- `Io.Evented` has no networking yet; non-IP networking unavailable.

---

## 8. TLS

Docs: [`std.crypto.tls.Client`](https://ziglang.org/documentation/0.16.0/std/#std.crypto.tls.Client)

`std.crypto.tls.Client` now decoupled from `std.net` / `std.fs` — it takes plain reader/writer interfaces:

```zig
var tls_client = std.crypto.tls.Client.init(reader_interface, writer_interface);
```

---

## 9. Compression — `std.compress.flate`

Docs: [`std.compress.flate`](https://ziglang.org/documentation/0.16.0/std/#std.compress.flate) · [`flate.Decompress`](https://ziglang.org/documentation/0.16.0/std/#std.compress.flate.Decompress)

### Decompression (new I/O style)

```zig
var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &decompress_buffer);
const decompress_reader: *std.Io.Reader = &decompress.reader;
```

### Pipe-only decompression (no window buffer needed)

```zig
var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &.{});
const n = try decompress.streamRemaining(writer);
```

### Compression (0.16.0 rewrite)

Three writer flavors:

- **default** — full deflate, history in writer buffer, chained hash table
- **`Raw`** — store blocks only
- **`Huffman`** — Huffman-only

Perf vs zlib: default ~9.7% faster, best level ~0.8% faster; ~1% worse ratio at default, ~0.77% worse at best. No checksum — compute CRC/Adler out-of-band.

---

## 10. Process API

Docs: [`std.process`](https://ziglang.org/documentation/0.16.0/std/#std.process) · [`std.process.spawn`](https://ziglang.org/documentation/0.16.0/std/#std.process.spawn) · [`std.process.run`](https://ziglang.org/documentation/0.16.0/std/#std.process.run) · [`std.process.Init`](https://ziglang.org/documentation/0.16.0/std/#std.process.Init)

### Spawning a child

**Old:**
```zig
var child = std.process.Child.init(argv, gpa);
child.stdin_behavior = .Pipe;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
try child.spawn(io);
```

**New:**
```zig
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
    .stdout = .pipe,
    .stderr = .pipe,
});
```

### Renames

| Old | New |
|---|---|
| `std.process.Child.init` | `std.process.spawn` |
| `std.process.Child.run` | `std.process.run` |
| `std.process.execv` | `std.process.replace` |
| `fs.openSelfExe` | `std.process.openExecutable` |
| `fs.selfExePath[Alloc]` | `std.process.executablePath[Alloc]` |
| `fs.selfExeDirPath[Alloc]` | `std.process.executableDirPath[Alloc]` |
| `fs.Dir.setAsCwd` | `std.process.setCurrentDir` |

---

## 11. Time — type-safe clocks

All new:

- [`std.Io.Clock`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Clock)
- [`std.Io.Duration`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Duration)
- [`std.Io.Timestamp`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Timestamp) (was `std.time.Instant`)
- [`std.Io.Timeout`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Timeout)

---

## 12. Async tasks via `Io`

Docs: [`std.Io.Future`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Future) · [`std.Io.Group`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Group)

### `io.async` / `io.concurrent`

```zig
var foo_future = io.async(foo, .{args});
defer if (foo_future.cancel(io)) |resource| resource.deinit() else |_| {}

const foo_result = try foo_future.await(io);
```

- `io.async()` — portable; always works
- `io.concurrent()` — may fail with `error.ConcurrencyUnavailable` if single-threaded + no concurrent impl

### Groups — O(1) overhead over many tasks

```zig
var group: Io.Group = .init;
defer group.cancel(io);

for (&array) |elem|
    group.async(io, sleepAppend, .{ io, &sorted, &index, elem });

try group.await(io);
```

### Cancelation

```zig
io.checkCancel();             // cooperative check point
io.recancel();                // rearm after consuming a cancel
io.swapCancelProtection();    // make this scope uncancelable
```

Spelling note from the docs: "single 'l'" — `cancel`, `canceled`, `cancelation`.

### Batch / Operation layer

Lower-level primitives:
- `FileReadStreaming`
- `FileWriteStreaming`
- `DeviceIoControl`
- `NetReceive`

---

## 13. Randomness

Docs: [`std.Random`](https://ziglang.org/documentation/0.16.0/std/#std.Random) · [`std.Random.IoSource`](https://ziglang.org/documentation/0.16.0/std/#std.Random.IoSource)

### Buffer fill

```zig
// old
var buf: [123]u8 = undefined;
std.crypto.random.bytes(&buf);

// new
var buf: [123]u8 = undefined;
io.random(&buf);
```

### `std.Random` interface

```zig
// old
const rng = std.crypto.random;

// new
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();
```

### Secure randomness — explicit two-API split

```zig
/// May store state; thread-safe; fast path.
pub fn random(io: Io, buffer: []u8) void;

/// Never stores in process memory; syscall every call; no fallback.
pub const RandomSecureError = error{EntropyUnavailable} || Cancelable;
pub fn randomSecure(io: Io, buffer: []u8) RandomSecureError!void;
```

Replaces the old `crypto_always_getrandom` / `crypto_fork_safety` build options.

---

## 14. Synchronization primitives

All moved under `std.Io` and now `io`-aware (participate in cancelation and chosen runtime):

| Old | New |
|---|---|
| `std.Thread.ResetEvent` | [`std.Io.Event`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Event) |
| `std.Thread.WaitGroup` | [`std.Io.Group`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Group) |
| `std.Thread.Futex` | [`std.Io.Futex`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Futex) |
| `std.Thread.Mutex` | [`std.Io.Mutex`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Mutex) |
| `std.Thread.Condition` | [`std.Io.Condition`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Condition) |
| `std.Thread.Semaphore` | [`std.Io.Semaphore`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Semaphore) |
| `std.Thread.RwLock` | [`std.Io.RwLock`](https://ziglang.org/documentation/0.16.0/std/#std.Io.RwLock) |

Lock-free atomics do **not** need `Io`.

---

## 15. Stack traces

Docs: [`std.debug`](https://ziglang.org/documentation/0.16.0/std/#std.debug)

```zig
pub fn captureCurrentStackTrace(options: StackUnwindOptions, addr_buf: []usize) StackTrace;

pub noinline fn writeCurrentStackTrace(
    options: StackUnwindOptions,
    t: Io.Terminal,
) Writer.Error!void;

pub fn dumpCurrentStackTrace(options: StackUnwindOptions) void;

pub const StackUnwindOptions = struct {
    first_address: ?usize = null,        // skip frames until this address
    context: ?CpuContextPtr = null,      // unwind from signal-handler context
    allow_unsafe_unwind: bool = false,   // allow unsafe fallback
};
```

Deprecated: `captureStackTrace`, `dumpStackTraceFromBase`, `walkStackWindows`, `writeStackTraceWindows`. `std.debug.StackIterator` is no longer public.

---

## 16. Deleted / removed

Structures subsumed by the new interfaces:

- `std.io.GenericReader` / `GenericWriter` / `AnyReader` / `AnyWriter`
- `std.io.SeekableStream`
- `std.io.BitReader` / `BitWriter`
- `std.Io.LimitedReader`
- `std.Io.BufferedReader` *(buffer is built into Reader now)*
- `std.Io.CountingReader`
- `std.fifo` (entire module) — `LinearFifo` included
- `std.RingBuffer`
- `std.compress.flate.CircularBuffer`

Also gone:

- `SegmentedList`, `meta.declList`, `Thread.Mutex.Recursive`, `std.once`
- `fs.getAppDataDir`
- Windows `DynLib`
- Most of `std.posix` / `std.os.windows` medium-level wrappers — go higher (`std.Io`) or lower (`std.posix.system`)

Collection change: `BitSet`, `EnumSet` now use decl literals instead of `initEmpty`/`initFull`.

---

## 17. Quick migration cheat-sheet

```zig
// stdout
var buf: [4096]u8 = undefined;
var w = std.fs.File.stdout().writer(&buf);
const stdout = &w.interface;
try stdout.print("{s}\n", .{"hi"});
try stdout.flush();

// stderr
var ebuf: [4096]u8 = undefined;
var ew = std.fs.File.stderr().writer(&ebuf);
const stderr = &ew.interface;

// stdin
var rbuf: [4096]u8 = undefined;
var r = std.fs.File.stdin().reader(&rbuf);
const stdin = &r.interface;

// read whole file into allocating writer
var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
var fr = file.reader(&[_]u8{});
try fr.interface.sendFileAll(&aw.writer);
const contents = aw.written();

// line loop
while (stdin.takeDelimiterExclusive('\n')) |line| {
    // ...
} else |err| switch (err) {
    error.EndOfStream => {},
    else => |e| return e,
}

// format a struct
pub fn format(self: Foo, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("Foo({d})", .{self.n});
}
// caller:
try stdout.print("{f}\n", .{foo});
```

---

## 18. Gotchas

- **Flush buffered writers.** No automatic drain on scope exit.
- **`{}` + `format` method is now a compile error.** Use `{f}`.
- **HTTP response head strings are invalidated** once you call `response.reader(...)`. Copy anything you need from headers first.
- **`close(io)` everywhere** — file-system handles need the `Io`.
- **`Io.Evented` has no networking (yet).**
- **Cancelation is single-`l`**: `cancel`, `canceled`, `cancelation`.
- `DynLib` is gone on Windows; `getAppDataDir` is gone everywhere.

---

## 19. Cross-reference index

### Release notes (source anchors)

- [0.16.0 — full release notes](https://ziglang.org/download/0.16.0/release-notes.html)
- [0.15.1 — full release notes](https://ziglang.org/download/0.15.1/release-notes.html) (where Reader/Writer landed)

### Core namespaces

- [`std.Io`](https://ziglang.org/documentation/0.16.0/std/#std.Io) — root namespace for the runtime interface
- [`std.Io.Reader`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader)
- [`std.Io.Writer`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer)
- [`std.Io.Dir`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Dir)
- [`std.Io.File`](https://ziglang.org/documentation/0.16.0/std/#std.Io.File)
- [`std.Io.net`](https://ziglang.org/documentation/0.16.0/std/#std.Io.net)
- [`std.fs.File`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File)
- [`std.fmt`](https://ziglang.org/documentation/0.16.0/std/#std.fmt)
- [`std.process`](https://ziglang.org/documentation/0.16.0/std/#std.process)
- [`std.http`](https://ziglang.org/documentation/0.16.0/std/#std.http)
- [`std.compress.flate`](https://ziglang.org/documentation/0.16.0/std/#std.compress.flate)
- [`std.crypto.tls`](https://ziglang.org/documentation/0.16.0/std/#std.crypto.tls)
- [`std.Random`](https://ziglang.org/documentation/0.16.0/std/#std.Random)
- [`std.debug`](https://ziglang.org/documentation/0.16.0/std/#std.debug)
- [`std.testing`](https://ziglang.org/documentation/0.16.0/std/#std.testing)

### Io runtime implementations

- [`Io.Threaded`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Threaded)
- [`Io.Evented`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Evented)
- [`Io.Uring`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Uring)
- [`Io.Kqueue`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Kqueue)
- [`Io.Dispatch`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Dispatch)
- [`Io.failing`](https://ziglang.org/documentation/0.16.0/std/#std.Io.failing)

### Reader / Writer variants

- [`Reader.fixed`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader.fixed)
- [`Writer.fixed`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.fixed)
- [`Writer.Allocating`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.Allocating)
- [`Writer.Discarding`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer.Discarding)
- [`fs.File.Reader`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.Reader)
- [`fs.File.Writer`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.Writer)
- [`fs.File.stdout`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.stdout)
- [`fs.File.stderr`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.stderr)
- [`fs.File.stdin`](https://ziglang.org/documentation/0.16.0/std/#std.fs.File.stdin)

### Concurrency & sync

- [`std.Io.Future`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Future)
- [`std.Io.Group`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Group)
- [`std.Io.Event`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Event)
- [`std.Io.Mutex`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Mutex)
- [`std.Io.Condition`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Condition)
- [`std.Io.Semaphore`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Semaphore)
- [`std.Io.RwLock`](https://ziglang.org/documentation/0.16.0/std/#std.Io.RwLock)
- [`std.Io.Futex`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Futex)

### Time

- [`std.Io.Clock`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Clock)
- [`std.Io.Duration`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Duration)
- [`std.Io.Timestamp`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Timestamp)
- [`std.Io.Timeout`](https://ziglang.org/documentation/0.16.0/std/#std.Io.Timeout)

### Formatting

- [`std.fmt.Alt`](https://ziglang.org/documentation/0.16.0/std/#std.fmt.Alt)
- [`std.fmt.alt`](https://ziglang.org/documentation/0.16.0/std/#std.fmt.alt)
- [`std.fmt.Options`](https://ziglang.org/documentation/0.16.0/std/#std.fmt.Options)
- [`std.fmt.bufPrintSentinel`](https://ziglang.org/documentation/0.16.0/std/#std.fmt.bufPrintSentinel)
- [`std.ascii.hexEscape`](https://ziglang.org/documentation/0.16.0/std/#std.ascii.hexEscape)

### Process

- [`std.process.Init`](https://ziglang.org/documentation/0.16.0/std/#std.process.Init)
- [`std.process.spawn`](https://ziglang.org/documentation/0.16.0/std/#std.process.spawn)
- [`std.process.run`](https://ziglang.org/documentation/0.16.0/std/#std.process.run)
- [`std.process.replace`](https://ziglang.org/documentation/0.16.0/std/#std.process.replace)
- [`std.process.executablePath`](https://ziglang.org/documentation/0.16.0/std/#std.process.executablePath)
- [`std.process.setCurrentDir`](https://ziglang.org/documentation/0.16.0/std/#std.process.setCurrentDir)
