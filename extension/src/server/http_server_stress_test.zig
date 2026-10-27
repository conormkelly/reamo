//! Connection churn stress test: a real HttpServer on loopback, hammered by
//! concurrent WebSocket upgrades/closes and `Connection: close` HTTP requests.
//!
//! Pins the httpz worker's connection teardown, which is only exercised by
//! real concurrency: overlapping handovers and WebSocket closes once corrupted
//! the worker's handover list, wedging the server or panicking its event loop
//! ("access of union field 'http' while field 'websocket' is active").
//!
//! Opt-in, since it takes seconds and binds a port:
//!   REAMO_STRESS_SECS=10 zig build test -Doptimize=ReleaseSafe
const std = @import("std");
const posix = std.posix;
const http_server = @import("http_server.zig");
const ws_server = @import("ws_server.zig");

const PORT: u16 = 19611;
const THREADS = 6;

fn connect() !std.net.Stream {
    const addr = try std.net.Address.parseIp4("127.0.0.1", PORT);
    const s = try std.net.tcpConnectToAddress(addr);
    errdefer s.close();
    const tv = posix.timeval{ .sec = 2, .usec = 0 };
    try posix.setsockopt(s.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    return s;
}

const upgrade_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:19611\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

fn openWs() !std.net.Stream {
    const s = try connect();
    errdefer s.close();
    _ = try posix.write(s.handle, upgrade_req);
    var buf: [512]u8 = undefined;
    const n = try posix.read(s.handle, &buf);
    if (!std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 101")) return error.BadUpgrade;
    return s;
}

/// Send a masked `{"type":"ping"}` text frame and wait for any reply.
fn wsPing(s: std.net.Stream) !void {
    const payload = "{\"type\":\"ping\"}";
    const mask = [4]u8{ 1, 2, 3, 4 };
    var frame: [6 + payload.len]u8 = undefined;
    frame[0] = 0x81;
    frame[1] = 0x80 | @as(u8, payload.len);
    @memcpy(frame[2..6], &mask);
    for (payload, 0..) |c, i| frame[6 + i] = c ^ mask[i % 4];
    _ = try posix.write(s.handle, &frame);
    var buf: [256]u8 = undefined;
    if (try posix.read(s.handle, &buf) == 0) return error.Eof;
}

fn httpClose() !void {
    const s = try connect();
    defer s.close();
    _ = try posix.write(s.handle, "GET /api/ping HTTP/1.1\r\nHost: 127.0.0.1:19611\r\nConnection: close\r\n\r\n");
    var buf: [1024]u8 = undefined;
    while (try posix.read(s.handle, &buf) != 0) {}
}

const Stats = struct {
    ops: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
};

fn churn(stats: *Stats, seed: u64, deadline_ms: i64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    while (std.time.milliTimestamp() < deadline_ms) {
        const ok = switch (r.uintLessThan(u8, 3)) {
            0 => blk: {
                const s = openWs() catch break :blk false;
                defer s.close();
                if (r.boolean()) wsPing(s) catch break :blk false;
                break :blk true;
            },
            1 => blk: {
                httpClose() catch break :blk false;
                break :blk true;
            },
            else => blk: {
                // Two upgrades back-to-back so their handovers share a signal batch.
                const a = openWs() catch break :blk false;
                const b = openWs() catch {
                    a.close();
                    break :blk false;
                };
                if (r.boolean()) {
                    b.close();
                    a.close();
                } else {
                    a.close();
                    b.close();
                }
                break :blk true;
            },
        };
        _ = stats.ops.fetchAdd(1, .monotonic);
        if (!ok) _ = stats.errors.fetchAdd(1, .monotonic);
    }
}

test "server survives concurrent WebSocket upgrade/close churn without wedging or leaking clients" {
    const secs_str = std.process.getEnvVarOwned(std.testing.allocator, "REAMO_STRESS_SECS") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer std.testing.allocator.free(secs_str);
    const secs = try std.fmt.parseInt(i64, secs_str, 10);

    const allocator = std.heap.page_allocator;
    var state = ws_server.SharedState.init(allocator);
    defer state.deinit();
    var srv = try http_server.HttpServer.init(allocator, &state, PORT, null, null);
    defer srv.deinit();
    try srv.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    var stats = Stats{};
    const deadline = std.time.milliTimestamp() + secs * std.time.ms_per_s;
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, churn, .{ &stats, i * 7919 + 1, deadline });
    for (threads) |t| t.join();

    // A wedged worker stops completing handovers: requests time out.
    try std.testing.expectEqual(@as(usize, 0), stats.errors.load(.monotonic));
    try std.testing.expect(stats.ops.load(.monotonic) > 0);

    // Every client has closed; the server must notice them all.
    var waited_ms: u32 = 0;
    while (state.clientCount() != 0 and waited_ms < 3000) : (waited_ms += 50) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 0), state.clientCount());

    // And it still accepts new connections.
    const s = try openWs();
    s.close();
}
