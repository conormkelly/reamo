const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform getenv. std.posix.getenv is unavailable on Windows
/// (environment strings are WTF-16). Returns null on Windows.
fn getEnv(key: []const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    return std.posix.getenv(key);
}

// ============================================================================
// Custom Panic Handler (Zig 0.15 API)
// ============================================================================

/// Custom panic implementation that flushes the ring buffer before aborting.
/// This ensures we have context about what led to the crash.
fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    // Log the panic message
    log(.err, "PANIC: {s}", .{msg});

    // Flush ring buffer to file
    flushRingBuffer();

    // Call default panic behavior (prints stack trace and aborts)
    std.debug.defaultPanic(msg, ret_addr);
}

/// Export panic handler namespace for Zig 0.15
pub const panic = std.debug.FullPanic(panicImpl);

/// Log levels for runtime configuration
pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn fromString(s: []const u8) Level {
        if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "err")) return .err;
        if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warn;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
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
};

/// Ring buffer entry for crash recovery
const RingEntry = struct {
    timestamp_ms: i64 = 0,
    level: Level = .info,
    message: [240]u8 = undefined,
    len: u8 = 0,

    fn write(self: *RingEntry, timestamp: i64, level: Level, msg: []const u8) void {
        self.timestamp_ms = timestamp;
        self.level = level;
        const copy_len = @min(msg.len, self.message.len);
        @memcpy(self.message[0..copy_len], msg[0..copy_len]);
        self.len = @intCast(copy_len);
    }

    fn getMessage(self: *const RingEntry) []const u8 {
        return self.message[0..self.len];
    }
};

/// Pre-allocated ring buffer for crash recovery (no allocation needed)
const RING_SIZE = 64;
var crash_ring: [RING_SIZE]RingEntry = [_]RingEntry{.{}} ** RING_SIZE;
var ring_head: usize = 0;

/// Global logger state
var log_file: ?std.fs.File = null;
var log_level: Level = .info;
var initialized: bool = false;
var log_path_buf: [512]u8 = undefined;
var log_path_len: usize = 0;

/// Maximum log file size before rotation (1MB)
const MAX_LOG_SIZE: u64 = 1024 * 1024;
/// Number of rotated files to keep
const MAX_ROTATIONS: u8 = 3;

/// Initialize the logger with REAPER's resource path
/// Call this early in extension startup
pub fn init(resource_path: ?[]const u8) void {
    if (initialized) return;

    // Read log level from environment (not available on Windows — WTF-16 strings)
    if (getEnv("REAMO_LOG_LEVEL")) |level_str| {
        log_level = Level.fromString(level_str);
    }

    // Build log path: {resource_path}/Logs/reamo.log
    const res_path = resource_path orelse {
        // No resource path - log to stderr only
        initialized = true;
        return;
    };

    var fbs = std.io.fixedBufferStream(&log_path_buf);
    const writer = fbs.writer();
    writer.print("{s}/Logs/reamo.log", .{res_path}) catch {
        initialized = true;
        return;
    };
    log_path_len = fbs.pos;

    // Ensure Logs directory exists
    var dir_path_buf: [512]u8 = undefined;
    var dir_fbs = std.io.fixedBufferStream(&dir_path_buf);
    dir_fbs.writer().print("{s}/Logs", .{res_path}) catch {
        initialized = true;
        return;
    };
    const dir_path = dir_path_buf[0..dir_fbs.pos];

    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {}, // OK
        else => {
            initialized = true;
            return;
        },
    };

    // Check if rotation needed before opening
    rotateIfNeeded();

    // Open log file for append
    const path = log_path_buf[0..log_path_len];
    log_file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |e| blk: {
        if (e == error.FileNotFound) {
            break :blk std.fs.createFileAbsolute(path, .{}) catch null;
        }
        break :blk null;
    };

    if (log_file) |f| {
        f.seekFromEnd(0) catch {};
        writeHeader(f);
    }

    initialized = true;
}

fn writeHeader(f: std.fs.File) void {
    const header = "=== Reamo Extension Log ===\n";
    _ = f.write(header) catch {};
}

/// Rotate log files if current one exceeds size limit
fn rotateIfNeeded() void {
    if (log_path_len == 0) return;

    const path = log_path_buf[0..log_path_len];
    const stat = std.fs.cwd().statFile(path) catch return;

    if (stat.size < MAX_LOG_SIZE) return;

    // Close current file
    if (log_file) |f| {
        f.close();
        log_file = null;
    }

    // Rotate: reamo.log.3 -> delete, .2 -> .3, .1 -> .2, .log -> .1
    var i: u8 = MAX_ROTATIONS;
    while (i > 0) : (i -= 1) {
        var old_path: [520]u8 = undefined;
        var new_path: [520]u8 = undefined;

        if (i == MAX_ROTATIONS) {
            // Delete oldest
            const old_slice = std.fmt.bufPrint(&old_path, "{s}.{d}", .{ path, i }) catch continue;
            std.fs.deleteFileAbsolute(old_slice) catch {};
        } else {
            // Rename .N to .N+1
            const old_slice = std.fmt.bufPrint(&old_path, "{s}.{d}", .{ path, i }) catch continue;
            const new_slice = std.fmt.bufPrint(&new_path, "{s}.{d}", .{ path, i + 1 }) catch continue;
            std.fs.renameAbsolute(old_slice, new_slice) catch {};
        }
    }

    // Rename current .log to .1
    var first_rotation: [520]u8 = undefined;
    const first_slice = std.fmt.bufPrint(&first_rotation, "{s}.1", .{path}) catch return;
    std.fs.renameAbsolute(path, first_slice) catch {};
}

/// Shutdown the logger (called on extension unload)
pub fn deinit() void {
    if (log_file) |f| {
        const footer = "=== Extension Unloaded ===\n\n";
        _ = f.write(footer) catch {};
        f.close();
        log_file = null;
    }
    initialized = false;
}

/// Get current timestamp in milliseconds
fn getTimestampMs() i64 {
    return @divFloor(std.time.milliTimestamp(), 1);
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
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;

    const timestamp = getTimestampMs();

    // Format message
    // AUDIT: Silent catch return is intentional - can't log a logging failure.
    // Ring buffer provides crash recovery for truncated messages.
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    // Add to ring buffer (always, for crash recovery)
    crash_ring[ring_head].write(timestamp, level, msg);
    ring_head = (ring_head + 1) % RING_SIZE;

    // Format full log line
    var line_buf: [612]u8 = undefined;
    var ts_buf: [28]u8 = undefined;
    const ts = formatTimestamp(&ts_buf, timestamp);

    const line = std.fmt.bufPrint(&line_buf, "[{s}] {s} {s}\n", .{ ts, level.asText(), msg }) catch return;

    // Write to file (silent catch - no meaningful recovery for file write failure)
    if (log_file) |f| {
        _ = f.write(line) catch {};
    }

    // Also write to stderr in debug builds
    if (builtin.mode == .Debug) {
        std.debug.print("{s}", .{line});
    }
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

/// Flush ring buffer to file (call from panic handler)
pub fn flushRingBuffer() void {
    const f = log_file orelse return;

    _ = f.write("\n=== CRASH RING BUFFER ===\n") catch return;

    // Write entries in order (oldest to newest)
    var i: usize = 0;
    while (i < RING_SIZE) : (i += 1) {
        const idx = (ring_head + i) % RING_SIZE;
        const entry = &crash_ring[idx];
        if (entry.len == 0) continue;

        var ts_buf: [28]u8 = undefined;
        const ts = formatTimestamp(&ts_buf, entry.timestamp_ms);

        var line_buf: [300]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[{s}] {s} {s}\n", .{
            ts,
            entry.level.asText(),
            entry.getMessage(),
        }) catch continue;

        _ = f.write(line) catch {};
    }

    _ = f.write("=== END RING BUFFER ===\n") catch {};
}

/// Get the log file path (for error messages)
pub fn getLogPath() ?[]const u8 {
    if (log_path_len == 0) return null;
    return log_path_buf[0..log_path_len];
}

// ============================================================================
// Tests
// ============================================================================

test "Level.fromString" {
    try std.testing.expectEqual(Level.err, Level.fromString("error"));
    try std.testing.expectEqual(Level.err, Level.fromString("err"));
    try std.testing.expectEqual(Level.warn, Level.fromString("warn"));
    try std.testing.expectEqual(Level.warn, Level.fromString("warning"));
    try std.testing.expectEqual(Level.info, Level.fromString("info"));
    try std.testing.expectEqual(Level.debug, Level.fromString("debug"));
    try std.testing.expectEqual(Level.info, Level.fromString("unknown")); // default
}

test "formatTimestamp" {
    var buf: [28]u8 = undefined;

    // 10.04.2026 13:30:45.678 (Unix epoch ms for that datetime in UTC)
    const ts: i64 = 1775827845678;
    const result = formatTimestamp(&buf, ts);
    try std.testing.expectEqualStrings("10.04.2026 13:30:45.678", result);
}

test "RingEntry write and read" {
    var entry = RingEntry{};
    entry.write(12345, .warn, "test message");

    try std.testing.expectEqual(@as(i64, 12345), entry.timestamp_ms);
    try std.testing.expectEqual(Level.warn, entry.level);
    try std.testing.expectEqualStrings("test message", entry.getMessage());
}

test "RingEntry truncates long messages" {
    var entry = RingEntry{};
    const long_msg = "x" ** 300; // longer than 240
    entry.write(0, .info, long_msg);

    try std.testing.expectEqual(@as(u8, 240), entry.len);
}
