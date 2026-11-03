//! A WebSocket that doesn't say hello in time is ended, and gives its
//! connection slot back.
//!
//! The server's connection slots (httpz max_conn) are shared by HTTP and
//! WebSocket, and a WebSocket holds one until it closes. Without a deadline,
//! sockets that upgrade and then say nothing would hold every slot, and no
//! phone could connect. The main thread ends them through
//! SharedState.endClientsPastHelloDeadline.
const std = @import("std");
const posix = std.posix;
const http_server = @import("http_server.zig");
const ws_server = @import("ws_server.zig");

const PORT: u16 = 19614;
const TOKEN = "0123456789abcdef0123456789abcdef";
const SHORT_DEADLINE_NS = 20 * std.time.ns_per_ms;

const upgrade_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:19614\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

const Server = struct {
    state: ws_server.SharedState,
    srv: http_server.HttpServer,

    fn start(self: *Server) !void {
        self.state = ws_server.SharedState.init(std.heap.page_allocator);
        self.state.setToken(TOKEN);
        self.srv = try http_server.HttpServer.init(std.heap.page_allocator, &self.state, PORT, null, null);
        try self.srv.start();
    }

    fn stop(self: *Server) void {
        self.srv.deinit();
        self.state.deinit();
    }

    fn waitForClients(self: *Server, n: usize) !void {
        var waited_ms: u32 = 0;
        while (self.state.clientCount() != n) : (waited_ms += 1) {
            if (waited_ms > 3000) return error.ClientCountNeverReached;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    /// Two sweeps, the second once a deadline of SHORT_DEADLINE_NS has passed
    /// since the first noticed the sockets.
    fn sweepPastShortDeadline(self: *Server) !void {
        self.state.endClientsPastHelloDeadline(try std.time.Instant.now(), SHORT_DEADLINE_NS);
        std.Thread.sleep(2 * SHORT_DEADLINE_NS);
        self.state.endClientsPastHelloDeadline(try std.time.Instant.now(), SHORT_DEADLINE_NS);
    }
};

/// Uses send/recv, which go through Winsock on Windows; std.net.Stream's
/// read/write call ReadFile/WriteFile, which reject Zig's overlapped sockets.
fn openWs() !std.net.Stream {
    const addr = try std.net.Address.parseIp4("127.0.0.1", PORT);
    const s = try std.net.tcpConnectToAddress(addr);
    errdefer s.close();
    setRecvTimeoutMs(s, 2000);
    _ = try posix.send(s.handle, upgrade_req, 0);
    var buf: [512]u8 = undefined;
    const n = try posix.recv(s.handle, &buf, 0);
    if (!std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 101")) return error.BadUpgrade;
    return s;
}

fn setRecvTimeoutMs(s: std.net.Stream, ms: u32) void {
    const builtin = @import("builtin");
    const timeout = if (builtin.os.tag == .windows)
        std.mem.toBytes(ms)
    else
        std.mem.toBytes(posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) });
    posix.setsockopt(s.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout) catch {};
}

/// A client's text frame: masked, as RFC 6455 requires (with a zero key).
fn sendText(s: std.net.Stream, text: []const u8) !void {
    std.debug.assert(text.len < 126);
    var frame: [6 + 125]u8 = undefined;
    frame[0] = 0x81;
    frame[1] = 0x80 | @as(u8, @intCast(text.len));
    @memset(frame[2..6], 0);
    @memcpy(frame[6..][0..text.len], text);
    _ = try posix.send(s.handle, frame[0 .. 6 + text.len], 0);
}

/// The receive timeout passes with nothing received (not even the end).
fn expectNothingFor200Ms(s: std.net.Stream) !void {
    setRecvTimeoutMs(s, 200);
    var buf: [16]u8 = undefined;
    const n = posix.recv(s.handle, &buf, 0) catch |err| switch (err) {
        // A receive timeout: WouldBlock on POSIX, ConnectionTimedOut on Windows.
        error.WouldBlock, error.ConnectionTimedOut => return,
        else => return err,
    };
    std.debug.print("expected nothing, got {d} bytes: {any}\n", .{ n, buf[0..n] });
    return error.UnexpectedData;
}

/// Server frames, in order, however the reads split them.
const FrameReader = struct {
    s: std.net.Stream,
    buf: [512]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    /// The next frame's opcode and payload, valid until the next call.
    fn next(self: *FrameReader) !struct { u8, []const u8 } {
        while (true) {
            const have = self.buf[self.start..self.end];
            if (have.len >= 2) {
                const len: usize = have[1] & 0x7f;
                std.debug.assert(len < 126);
                if (have.len >= 2 + len) {
                    self.start += 2 + len;
                    return .{ have[0] & 0x0f, have[2 .. 2 + len] };
                }
            }
            if (self.start > 0) {
                std.mem.copyForwards(u8, &self.buf, have);
                self.end = have.len;
                self.start = 0;
            }
            const n = try posix.recv(self.s.handle, self.buf[self.end..], 0);
            if (n == 0) return error.EndOfStream;
            self.end += n;
        }
    }
};

test "a WebSocket that never says hello is ended with 4003 at the deadline, pings or not, and gives its slot back" {
    var server: Server = undefined;
    try server.start();
    defer server.stop();

    const client = try openWs();
    defer client.close();
    try server.waitForClients(1);
    // A message other than hello doesn't count as one.
    try sendText(client, "{\"type\":\"ping\"}");

    try server.sweepPastShortDeadline();
    // A valid hello arriving now, before the worker has closed the
    // connection, is too late: it isn't answered or let in. (Client 1: the
    // first in a fresh SharedState.)
    try std.testing.expect(!server.state.takeHelloInTime(1));

    var frames = FrameReader{ .s = client };
    while (true) {
        const opcode, const payload = try frames.next();
        if (opcode == 0x1) continue; // NOT_AUTHENTICATED, for the ping
        try std.testing.expectEqual(@as(u8, 0x8), opcode);
        try std.testing.expectEqual(@as(u16, 4003), std.mem.readInt(u16, payload[0..2], .big));
        break;
    }
    // The connection is gone on the server's side too: its slot is free.
    try server.waitForClients(0);
}

test "a WebSocket that says hello before the deadline is kept" {
    var server: Server = undefined;
    try server.start();
    defer server.stop();

    const client = try openWs();
    defer client.close();
    try server.waitForClients(1);
    // The first sweep sees it before its hello, which starts its deadline.
    server.state.endClientsPastHelloDeadline(try std.time.Instant.now(), SHORT_DEADLINE_NS);
    try sendText(client, "{\"type\":\"hello\",\"protocolVersion\":1,\"token\":\"" ++ TOKEN ++ "\"}");
    var frames = FrameReader{ .s = client };
    const opcode, const payload = try frames.next();
    try std.testing.expectEqual(@as(u8, 0x1), opcode);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"hello\"") != null);

    std.Thread.sleep(2 * SHORT_DEADLINE_NS);
    server.state.endClientsPastHelloDeadline(try std.time.Instant.now(), SHORT_DEADLINE_NS);

    // Nothing more comes, and the server still has it.
    try std.testing.expectEqual(frames.start, frames.end);
    try expectNothingFor200Ms(client);
    try std.testing.expectEqual(@as(usize, 1), server.state.clientCount());
}

test "a WebSocket is never ended before its deadline" {
    var server: Server = undefined;
    try server.start();
    defer server.stop();

    const client = try openWs();
    defer client.close();
    try server.waitForClients(1);
    const long_deadline_ns = 60 * std.time.ns_per_s;
    server.state.endClientsPastHelloDeadline(try std.time.Instant.now(), long_deadline_ns);
    std.Thread.sleep(2 * SHORT_DEADLINE_NS);
    server.state.endClientsPastHelloDeadline(try std.time.Instant.now(), long_deadline_ns);

    try expectNothingFor200Ms(client);
    try std.testing.expectEqual(@as(usize, 1), server.state.clientCount());
}
