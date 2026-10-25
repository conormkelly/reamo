//! REAmo's log file: {REAPER resource path}/Logs/reamo.log.
//!
//! The log is what a user sends when something goes wrong, so it has to
//! describe the session it came from and survive a crash, and it must never
//! fill their disk:
//!
//! - Each file starts with a header naming the REAmo and REAPER versions,
//!   OS, CPU and log level, so a file read on its own is still useful.
//! - A file rotates when it reaches MAX_LOG_SIZE, checked on every write, and
//!   MAX_ROTATIONS old files are kept: the logs never use more than
//!   (MAX_ROTATIONS + 1) * MAX_LOG_SIZE bytes.
//! - A message identical to one written in the last minute (among the last
//!   few distinct ones) is counted, not written, and the count is written
//!   once a minute, so a condition that persists across timer ticks costs a
//!   line a minute, even when it logs two or three different lines a tick.
//! - A message too long for the line buffer is cut short and marked, never
//!   dropped.
//! - A panic writes the message, the stack and the most recent messages at
//!   every level, debug included, before REAPER goes down.
//!
//! Logging is safe from any thread: the WebSocket server logs from its
//! worker threads while the timer logs from REAPER's main thread.

const std = @import("std");
const builtin = @import("builtin");
const utf8 = @import("utf8.zig");

/// Log levels for runtime configuration
pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn fromString(s: []const u8) Level {
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        return .info; // default
    }

    pub fn asText(self: Level) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warn => "WARN ",
            .info => "INFO ",
            .debug => "DEBUG",
        };
    }

    fn name(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
        };
    }
};

/// The level a session starts at. A Debug (developer) build logs everything;
/// a release logs lifecycle events, problems and failures, so a user's log
/// is small and safe to share. REAMO_LOG_LEVEL overrides it, and the REAmo
/// menu's Debug Logging turns debug on until REAPER restarts.
pub const default_level: Level = if (builtin.mode == .Debug) .debug else .info;

/// Size at which the log rotates (1 MB).
pub const MAX_LOG_SIZE: u64 = 1024 * 1024;
/// Rotated files kept beside the live one: reamo.log.1 (newest) to .3.
pub const MAX_ROTATIONS: u8 = 3;
/// Longest message kept, in bytes; longer ones end in TRUNCATED_MARK.
const MSG_CAP = 512;
const TRUNCATED_MARK = " [cut]";
/// How often a run of repeated messages reports its count, and how long a
/// message must go unseen before it is written again in full.
const REPEAT_REPORT_MS: i64 = 60 * std.time.ms_per_s;
/// Distinct recent messages tracked for repeats.
const RECENT_SIZE = 8;
/// How much of a repeated message its count line quotes.
const REPEAT_QUOTE_LEN = 80;

/// A recently written message and how often it has repeated since.
const Recent = struct {
    hash: u64 = 0,
    level: Level = .info,
    quote: [REPEAT_QUOTE_LEN]u8 = undefined,
    quote_len: usize = 0,
    /// Copies not yet written.
    count: u32 = 0,
    /// When the count was last reported (or the message first written).
    since_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    used: bool = false,

    fn hashOf(level: Level, msg: []const u8) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(level));
        h.update(msg);
        return h.final();
    }
};

/// What the header of every log file says about the session.
pub const Session = struct {
    reamo_version: []const u8,
    /// GetAppVersion's text, e.g. "7.83/macOS-arm64"; null before the API loads.
    reaper_version: ?[]const u8 = null,
};

// ============================================================================
// Crash ring: the most recent messages at every level
// ============================================================================

const RingEntry = struct {
    timestamp_ms: i64 = 0,
    level: Level = .info,
    message: [240]u8 = undefined,
    len: u8 = 0,

    fn write(self: *RingEntry, timestamp: i64, level: Level, msg: []const u8) void {
        self.timestamp_ms = timestamp;
        self.level = level;
        const kept = utf8.prefix(msg, self.message.len);
        @memcpy(self.message[0..kept.len], kept);
        self.len = @intCast(kept.len);
    }

    fn getMessage(self: *const RingEntry) []const u8 {
        return self.message[0..self.len];
    }
};

const RING_SIZE = 64;

// ============================================================================
// Sink: one log file, its rotations, and repeat collapsing
// ============================================================================

/// The file side of the logger. Not thread-safe: the module-level functions
/// hold `mutex` around every call.
const Sink = struct {
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    file: ?std.fs.File = null,
    /// Bytes in the current file, so rotation needs no stat per write.
    size: u64 = 0,
    max_size: u64 = MAX_LOG_SIZE,
    level: Level = default_level,

    header_buf: [384]u8 = undefined,
    header_len: usize = 0,

    recent: [RECENT_SIZE]Recent = [_]Recent{.{}} ** RECENT_SIZE,

    ring: [RING_SIZE]RingEntry = [_]RingEntry{.{}} ** RING_SIZE,
    ring_head: usize = 0,

    fn path(self: *const Sink) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Open (or create) the log at `log_path` for appending, rotating it
    /// first if it is already full.
    fn open(self: *Sink, log_path: []const u8) void {
        if (log_path.len > self.path_buf.len) return;
        @memcpy(self.path_buf[0..log_path.len], log_path);
        self.path_len = log_path.len;
        if (std.fs.cwd().statFile(log_path)) |stat| {
            if (stat.size >= self.max_size) self.rotateFiles();
        } else |_| {}
        self.openCurrent();
    }

    fn openCurrent(self: *Sink) void {
        const p = self.path();
        // A log that can't be opened leaves REAmo running without one: there
        // is nowhere to report the failure to.
        const f = std.fs.cwd().createFile(p, .{ .truncate = false }) catch return;
        self.size = f.getEndPos() catch 0;
        f.seekTo(self.size) catch {};
        self.file = f;
        self.writeRaw(self.header_buf[0..self.header_len]);
    }

    /// reamo.log.N-1 -> .N, ..., reamo.log -> .1; the oldest is deleted.
    fn rotateFiles(self: *Sink) void {
        const p = self.path();
        var from_buf: [530]u8 = undefined;
        var to_buf: [530]u8 = undefined;
        var i: u8 = MAX_ROTATIONS;
        while (i > 0) : (i -= 1) {
            const to = std.fmt.bufPrint(&to_buf, "{s}.{d}", .{ p, i }) catch return;
            const from = if (i == 1) p else std.fmt.bufPrint(&from_buf, "{s}.{d}", .{ p, i - 1 }) catch return;
            // Renaming over an existing file replaces it on every platform;
            // a missing `from` just means fewer rotations exist yet.
            std.fs.cwd().rename(from, to) catch {};
        }
    }

    fn rotate(self: *Sink) void {
        if (self.file) |f| f.close();
        self.file = null;
        self.rotateFiles();
        self.openCurrent();
    }

    fn writeRaw(self: *Sink, bytes: []const u8) void {
        const f = self.file orelse return;
        // A failed write (disk full, file removed) loses this line only;
        // there is nowhere else to report it.
        f.writeAll(bytes) catch return;
        self.size += bytes.len;
    }

    fn writeLine(self: *Sink, timestamp: i64, level: Level, msg: []const u8) void {
        var ts_buf: [28]u8 = undefined;
        const ts = formatTimestamp(&ts_buf, timestamp);
        var line_buf: [MSG_CAP + 64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[{s}] {s} {s}\n", .{ ts, level.asText(), msg }) catch unreachable;
        self.writeRaw(line);
        if (builtin.mode == .Debug and !builtin.is_test) std.debug.print("{s}", .{line});
        if (self.size >= self.max_size) self.rotate();
    }

    fn reportRepeats(self: *Sink, entry: *Recent, timestamp: i64) void {
        entry.since_ms = timestamp;
        if (entry.count == 0) return;
        var buf: [REPEAT_QUOTE_LEN + 64]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "(repeated {d} more time{s}: {s})", .{
            entry.count,
            if (entry.count == 1) "" else "s",
            entry.quote[0..entry.quote_len],
        }) catch unreachable;
        entry.count = 0;
        self.writeLine(timestamp, entry.level, summary);
    }

    /// Report every pending repeat count (on close and on a crash).
    fn reportAllRepeats(self: *Sink, timestamp: i64) void {
        for (&self.recent) |*entry| {
            if (entry.used) self.reportRepeats(entry, timestamp);
        }
    }

    /// Record a formatted message: always into the crash ring, and into the
    /// file if `level` is enabled and it isn't a recent repeat.
    fn submit(self: *Sink, timestamp: i64, level: Level, msg: []const u8) void {
        self.ring[self.ring_head].write(timestamp, level, msg);
        self.ring_head = (self.ring_head + 1) % RING_SIZE;

        if (@intFromEnum(level) > @intFromEnum(self.level)) return;

        // Counts that have waited a minute are reported whatever arrives.
        for (&self.recent) |*entry| {
            if (entry.used and entry.count > 0 and timestamp - entry.since_ms >= REPEAT_REPORT_MS) {
                self.reportRepeats(entry, timestamp);
            }
        }

        const hash = Recent.hashOf(level, msg);
        var oldest: *Recent = &self.recent[0];
        for (&self.recent) |*entry| {
            if (entry.used and entry.hash == hash and timestamp - entry.last_seen_ms < REPEAT_REPORT_MS) {
                entry.count += 1;
                entry.last_seen_ms = timestamp;
                return;
            }
            if (!entry.used or entry.last_seen_ms < oldest.last_seen_ms) oldest = entry;
        }

        // A new message, or one unseen for a minute: write it in full, in
        // the slot of the least recently seen, reporting that one's count.
        if (oldest.used) self.reportRepeats(oldest, timestamp);
        self.writeLine(timestamp, level, msg);
        const quote = utf8.prefix(msg, REPEAT_QUOTE_LEN);
        oldest.* = .{ .hash = hash, .level = level, .quote_len = quote.len, .since_ms = timestamp, .last_seen_ms = timestamp, .used = true };
        @memcpy(oldest.quote[0..quote.len], quote);
    }

    fn writeRing(self: *Sink) void {
        self.writeRaw("=== Last messages at every level, oldest first ===\n");
        var i: usize = 0;
        while (i < RING_SIZE) : (i += 1) {
            const entry = &self.ring[(self.ring_head + i) % RING_SIZE];
            if (entry.len == 0) continue;
            var ts_buf: [28]u8 = undefined;
            var line_buf: [300]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "[{s}] {s} {s}\n", .{
                formatTimestamp(&ts_buf, entry.timestamp_ms),
                entry.level.asText(),
                entry.getMessage(),
            }) catch continue;
            self.writeRaw(line);
        }
        self.writeRaw("=== End of last messages ===\n");
    }

    fn close(self: *Sink, timestamp: i64) void {
        self.reportAllRepeats(timestamp);
        self.writeRaw("=== REAmo unloaded ===\n\n");
        if (self.file) |f| f.close();
        self.file = null;
    }
};

/// Format `fmt` into `buf`; a message that doesn't fit is cut on a character
/// boundary and ends in TRUNCATED_MARK.
fn formatMessage(buf: *[MSG_CAP]u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - TRUNCATED_MARK.len]);
    w.print(fmt, args) catch {
        const kept = utf8.trimIncompleteTail(w.buffered());
        @memcpy(buf[kept.len..][0..TRUNCATED_MARK.len], TRUNCATED_MARK);
        return buf[0 .. kept.len + TRUNCATED_MARK.len];
    };
    return w.buffered();
}

fn writeHeader(buf: []u8, session: Session, level: Level) []const u8 {
    return std.fmt.bufPrint(buf, "=== REAmo {s} | REAPER {s} | {s}-{s} | {s} | log level {s} | times are UTC ===\n", .{
        session.reamo_version,
        session.reaper_version orelse "unknown",
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.mode),
        level.name(),
    }) catch buf[0..0];
}

// ============================================================================
// Global logger
// ============================================================================

var mutex: std.Thread.Mutex = .{};
var sink: Sink = .{};
var initialized: bool = false;
/// The level the session started at, which turning debug off returns to.
var session_level: Level = default_level;

/// Open the log. REAMO_LOG_LEVEL (error, warn, info, debug) sets the level;
/// the default is info.
pub fn init(resource_path: ?[]const u8, session: Session) void {
    mutex.lock();
    defer mutex.unlock();
    if (initialized) return;
    initialized = true;

    if (envLevel()) |level| sink.level = level;
    session_level = sink.level;
    sink.header_len = writeHeader(&sink.header_buf, session, sink.level).len;

    // Without a resource path there is no log file; the crash ring still runs.
    const res_path = resource_path orelse return;
    var dir_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/Logs", .{res_path}) catch return;
    std.fs.cwd().makePath(dir) catch return;
    var path_buf: [512]u8 = undefined;
    const log_path = std.fmt.bufPrint(&path_buf, "{s}/reamo.log", .{dir}) catch return;
    sink.open(log_path);
}

/// Close the log (called on extension unload).
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    sink.close(std.time.milliTimestamp());
    initialized = false;
}

fn envLevel() ?Level {
    if (comptime builtin.os.tag == .windows) {
        const value = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("REAMO_LOG_LEVEL")) orelse return null;
        var ascii: [16]u8 = undefined;
        if (value.len > ascii.len) return null;
        for (value, 0..) |c, i| ascii[i] = if (c < 128) @intCast(c) else '?';
        return Level.fromString(ascii[0..value.len]);
    }
    const value = std.posix.getenv("REAMO_LOG_LEVEL") orelse return null;
    return Level.fromString(value);
}

/// Format timestamp as DD.MM.YYYY HH:MM:SS.mmm (UTC)
fn formatTimestamp(buf: []u8, timestamp_ms: i64) []const u8 {
    const ms: u32 = @intCast(@mod(timestamp_ms, 1000));
    const epoch_secs: u64 = @intCast(@divFloor(timestamp_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>2}.{d:0>2}.{d} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        @as(u32, md.day_index + 1),
        @as(u32, md.month.numeric()),
        yd.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        ms,
    }) catch buf[0..0];
}

/// Core logging function
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [MSG_CAP]u8 = undefined;
    const msg = formatMessage(&msg_buf, fmt, args);
    const timestamp = std.time.milliTimestamp();
    mutex.lock();
    defer mutex.unlock();
    sink.submit(timestamp, level, msg);
}

/// Convenience functions matching std.log interface
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// Whether debug messages reach the file.
pub fn debugEnabled() bool {
    mutex.lock();
    defer mutex.unlock();
    return sink.level == .debug;
}

/// Turn debug logging on, or back to the session's level, until REAPER
/// restarts. Never persisted: a user who switches it on to reproduce a
/// problem can't leave it on by mistake.
pub fn setDebug(on: bool) void {
    const level: Level = if (on) .debug else if (session_level == .debug) .info else session_level;
    const timestamp = std.time.milliTimestamp();
    mutex.lock();
    defer mutex.unlock();
    sink.level = level;
    var buf: [96]u8 = undefined;
    sink.submit(timestamp, .info, std.fmt.bufPrint(&buf, "Log level {s} until REAPER restarts", .{level.name()}) catch unreachable);
}

/// Text a client sent, for a log line: `{f}` writes at most 64 bytes of it,
/// with control characters escaped, so a client can't forge log lines or
/// push the rest of the line out of the 512-byte message.
pub fn untrusted(text: []const u8) Untrusted {
    return .{ .text = text, .shown = 64 };
}

/// Text that may hold anything (a library's message, say) with control
/// characters escaped, kept to the length of a log message.
pub fn escaped(text: []const u8) Untrusted {
    return .{ .text = text, .shown = MSG_CAP };
}

pub const Untrusted = struct {
    text: []const u8,
    shown: usize,

    pub fn format(self: Untrusted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const shown = utf8.prefix(self.text, self.shown);
        for (shown) |c| {
            if (c < 0x20 or c == 0x7f) try w.print("\\x{x:0>2}", .{c}) else try w.writeByte(c);
        }
        if (shown.len < self.text.len) try w.print("...(+{d} bytes)", .{self.text.len - shown.len});
    }
};

/// Get the log file path (for error messages)
pub fn getLogPath() ?[]const u8 {
    if (sink.path_len == 0) return null;
    return sink.path();
}

// ============================================================================
// Panic handler
// ============================================================================

/// Write the panic, the stack and the crash ring to the log, then hand over
/// to Zig's default handler (stderr trace, abort). REAPER's stderr is
/// usually nowhere a user can find, so the log is the crash report.
threadlocal var in_panic: bool = false;

fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    // A panic while writing the report (reading debug info from a corrupt
    // heap, say) goes straight to the default handler instead of recursing.
    if (in_panic) std.debug.defaultPanic(msg, ret_addr);
    in_panic = true;
    // A panic inside the logger on this thread would deadlock on lock();
    // writing unlocked risks interleaving with another thread, which is the
    // lesser harm when REAPER is about to go down.
    const locked = mutex.tryLock();
    writeCrashReport(msg, ret_addr);
    if (locked) mutex.unlock();
    std.debug.defaultPanic(msg, ret_addr);
}

fn writeCrashReport(msg: []const u8, ret_addr: ?usize) void {
    const now = std.time.milliTimestamp();
    sink.reportAllRepeats(now);
    var ts_buf: [28]u8 = undefined;
    var buf: [MSG_CAP + 128]u8 = undefined;
    sink.writeRaw(std.fmt.bufPrint(&buf, "\n[{s}] PANIC on thread {d}: {s}\n", .{
        formatTimestamp(&ts_buf, now),
        std.Thread.getCurrentId(),
        utf8.prefix(msg, MSG_CAP),
    }) catch "\nPANIC\n");

    // Raw return addresses first: they need no debug info. The address of
    // panicImpl anchors them, so they can be symbolized against the
    // release's own binary.
    sink.writeRaw(std.fmt.bufPrint(&buf, "Stack (panicImpl at 0x{x}):\n", .{@intFromPtr(&panicImpl)}) catch "Stack:\n");
    var addrs: [32]usize = undefined;
    var trace: std.builtin.StackTrace = .{ .index = 0, .instruction_addresses = &addrs };
    std.debug.captureStackTrace(null, &trace);
    for (addrs[0..@min(trace.index, addrs.len)]) |addr| {
        sink.writeRaw(std.fmt.bufPrint(&buf, "  0x{x}\n", .{addr}) catch continue);
    }

    // A symbolized trace, when this machine has the debug info for it.
    if (sink.file) |f| {
        var out_buf: [1024]u8 = undefined;
        var fw = f.writerStreaming(&out_buf);
        const w = &fw.interface;
        if (builtin.strip_debug_info) {
            w.writeAll("No symbolized stack: debug info stripped\n") catch {};
        } else if (std.debug.getSelfDebugInfo()) |info_ptr| {
            std.debug.writeCurrentStackTrace(w, info_ptr, .no_color, ret_addr orelse @returnAddress()) catch |e| {
                w.print("No symbolized stack: {s}\n", .{@errorName(e)}) catch {};
            };
        } else |e| {
            w.print("No symbolized stack: {s}\n", .{@errorName(e)}) catch {};
        }
        w.flush() catch {};
    }

    sink.writeRing();
}

/// Export panic handler namespace for Zig 0.15
pub const panic = std.debug.FullPanic(panicImpl);

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// A sink writing to `name` inside a fresh temporary directory.
const TestSink = struct {
    tmp: testing.TmpDir,
    sink: Sink,
    path_buf: [std.fs.max_path_bytes]u8,

    fn init(self: *TestSink, max_size: u64) !void {
        self.tmp = testing.tmpDir(.{});
        self.sink = .{ .max_size = max_size, .level = .info };
        self.sink.header_len = writeHeader(&self.sink.header_buf, .{ .reamo_version = "test", .reaper_version = "7.83/test" }, .info).len;
        const dir = try self.tmp.dir.realpath(".", &self.path_buf);
        var p: [std.fs.max_path_bytes]u8 = undefined;
        self.sink.open(try std.fmt.bufPrint(&p, "{s}/reamo.log", .{dir}));
    }

    fn deinit(self: *TestSink) void {
        if (self.sink.file) |f| f.close();
        self.tmp.cleanup();
    }

    fn read(self: *TestSink, name: []const u8, buf: []u8) ![]const u8 {
        return self.tmp.dir.readFile(name, buf);
    }
};

test "client text in a log line is cut short and can't start a line of its own" {
    var buf: [MSG_CAP]u8 = undefined;
    const msg = formatMessage(&buf, "unknown command '{f}'", .{untrusted("a\n[01.01.2026 00:00:00.000] ERROR forged" ++ "x" ** 100)});
    try testing.expect(std.mem.indexOfScalar(u8, msg, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, msg, "a\\x0a[01.01.2026") != null);
    try testing.expect(std.mem.endsWith(u8, msg, "bytes)'"));
}

test "Level.fromString" {
    try testing.expectEqual(Level.err, Level.fromString("error"));
    try testing.expectEqual(Level.err, Level.fromString("err"));
    try testing.expectEqual(Level.warn, Level.fromString("warn"));
    try testing.expectEqual(Level.warn, Level.fromString("warning"));
    try testing.expectEqual(Level.info, Level.fromString("info"));
    try testing.expectEqual(Level.debug, Level.fromString("debug"));
    try testing.expectEqual(Level.debug, Level.fromString("DEBUG"));
    try testing.expectEqual(Level.info, Level.fromString("unknown")); // default
}

test "formatTimestamp" {
    var buf: [28]u8 = undefined;

    // 10.04.2026 13:30:45.678 (Unix epoch ms for that datetime in UTC)
    const ts: i64 = 1775827845678;
    const result = formatTimestamp(&buf, ts);
    try testing.expectEqualStrings("10.04.2026 13:30:45.678", result);
}

test "RingEntry truncates long messages on a character boundary" {
    var entry = RingEntry{};
    entry.write(0, .info, "x" ** 239 ++ "é");
    try testing.expectEqual(@as(u8, 239), entry.len);
}

test "a message longer than the buffer is cut short and marked, not dropped" {
    var buf: [MSG_CAP]u8 = undefined;
    const long = "y" ** (MSG_CAP * 2);
    const msg = formatMessage(&buf, "name={s}", .{long});
    try testing.expect(msg.len <= MSG_CAP);
    try testing.expect(std.mem.startsWith(u8, msg, "name=yyy"));
    try testing.expect(std.mem.endsWith(u8, msg, TRUNCATED_MARK));
}

test "a cut message never ends inside a multi-byte character" {
    var buf: [MSG_CAP]u8 = undefined;
    const msg = formatMessage(&buf, "{s}", .{"é" ** MSG_CAP});
    const body = msg[0 .. msg.len - TRUNCATED_MARK.len];
    try testing.expect(std.unicode.utf8ValidateSlice(body));
}

test "each log file starts with the session header" {
    var t: TestSink = undefined;
    try t.init(MAX_LOG_SIZE);
    defer t.deinit();
    var buf: [1024]u8 = undefined;
    const text = try t.read("reamo.log", &buf);
    try testing.expect(std.mem.startsWith(u8, text, "=== REAmo test | REAPER 7.83/test | "));
    try testing.expect(std.mem.indexOf(u8, text, "log level info") != null);
}

test "messages below the level stay out of the file but reach the crash ring" {
    var t: TestSink = undefined;
    try t.init(MAX_LOG_SIZE);
    defer t.deinit();
    t.sink.submit(0, .debug, "tick detail");
    var buf: [1024]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try t.read("reamo.log", &buf), "tick detail") == null);
    try testing.expectEqualStrings("tick detail", t.sink.ring[0].getMessage());
}

test "a repeated message is written once and counted when another arrives" {
    var t: TestSink = undefined;
    try t.init(MAX_LOG_SIZE);
    defer t.deinit();
    for (0..1000) |i| t.sink.submit(@intCast(i), .warn, "buffer too small");
    t.sink.submit(1000, .info, "something else");
    var buf: [4096]u8 = undefined;
    const text = try t.read("reamo.log", &buf);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "] WARN  buffer too small"));
    try testing.expect(std.mem.indexOf(u8, text, "something else") != null);
    t.sink.reportAllRepeats(2000);
    const final = try t.read("reamo.log", &buf);
    try testing.expect(std.mem.indexOf(u8, final, "(repeated 999 more times: buffer too small)") != null);
}

test "two messages alternating every tick are each written once, then counted" {
    var t: TestSink = undefined;
    try t.init(MAX_LOG_SIZE);
    defer t.deinit();
    // A poll's own error, then the timer's line about the same failure.
    var ts: i64 = 0;
    while (ts < 5 * 60 * std.time.ms_per_s) : (ts += 33) {
        t.sink.submit(ts, .err, "Failed to poll skeleton: OutOfMemory");
        t.sink.submit(ts, .err, "processTimerCallback failed: OutOfMemory");
    }
    var buf: [8192]u8 = undefined;
    const text = try t.read("reamo.log", &buf);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "] ERROR Failed to poll skeleton"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "] ERROR processTimerCallback failed"));
    // One count line per message per minute.
    try testing.expect(std.mem.count(u8, text, "(repeated ") <= 2 * 5);
}

test "a message seen again after a quiet minute is written in full" {
    var t: TestSink = undefined;
    try t.init(MAX_LOG_SIZE);
    defer t.deinit();
    t.sink.submit(0, .info, "Client 1 authenticated");
    t.sink.submit(5 * 60 * std.time.ms_per_s, .info, "Client 1 authenticated");
    var buf: [4096]u8 = undefined;
    const text = try t.read("reamo.log", &buf);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "] INFO  Client 1 authenticated"));
}

test "a message repeating forever reports its count once a minute" {
    var t: TestSink = undefined;
    try t.init(MAX_LOG_SIZE);
    defer t.deinit();
    // 30 Hz for ten minutes.
    var ts: i64 = 0;
    while (ts < 10 * 60 * std.time.ms_per_s) : (ts += 33) t.sink.submit(ts, .warn, "stuck");
    var buf: [8192]u8 = undefined;
    const text = try t.read("reamo.log", &buf);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "] WARN  stuck"));
    const reports = std.mem.count(u8, text, "(repeated ");
    try testing.expect(reports >= 9 and reports <= 10);
}

test "the log rotates while running, not only at startup, and keeps a bounded number of files" {
    var t: TestSink = undefined;
    try t.init(4096);
    defer t.deinit();
    var msg_buf: [64]u8 = undefined;
    for (0..2000) |i| t.sink.submit(@intCast(i), .info, try std.fmt.bufPrint(&msg_buf, "distinct message {d}", .{i}));

    var buf: [8192]u8 = undefined;
    const live = try t.read("reamo.log", &buf);
    try testing.expect(live.len < 4096 + MSG_CAP + 64);
    try testing.expect(std.mem.startsWith(u8, live, "=== REAmo test"));
    try testing.expect(std.mem.indexOf(u8, live, "distinct message 1999") != null);

    for (1..MAX_ROTATIONS + 1) |n| {
        var name_buf: [32]u8 = undefined;
        const rotated = try t.read(try std.fmt.bufPrint(&name_buf, "reamo.log.{d}", .{n}), &buf);
        try testing.expect(std.mem.startsWith(u8, rotated, "=== REAmo test"));
    }
    var name_buf: [32]u8 = undefined;
    const too_many = try std.fmt.bufPrint(&name_buf, "reamo.log.{d}", .{MAX_ROTATIONS + 1});
    try testing.expectError(error.FileNotFound, t.tmp.dir.access(too_many, .{}));
}

test "a log already full at startup is rotated before writing" {
    var t: TestSink = undefined;
    try t.init(64);
    defer t.deinit();
    // init wrote a header longer than 64 bytes; reopening must rotate it away.
    const p = t.sink.path();
    var p_copy: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(p_copy[0..p.len], p);
    t.sink.file.?.close();
    t.sink.file = null;
    t.sink.open(p_copy[0..p.len]);
    try t.tmp.dir.access("reamo.log.1", .{});
}
