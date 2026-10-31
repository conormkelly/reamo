//! The server must shut down cleanly while a WebSocket upgrade is in flight:
//! REAPER can quit, or the extension unload, at the moment a phone connects.
//!
//! An upgraded connection waits in the httpz worker's handover list until the
//! worker's event loop picks it up. Stopping the server right after the
//! upgrade leaves it there, so each iteration stops the server as soon as the
//! WebSocket handler has run. A double close of the socket panics on EBADF.
const std = @import("std");
const posix = std.posix;
const http_server = @import("http_server.zig");
const ws_server = @import("ws_server.zig");

const PORT: u16 = 19613;
const ITERATIONS = 100;

const upgrade_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:19613\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

/// Uses send/recv, which go through Winsock on Windows; std.net.Stream's
/// read/write call ReadFile/WriteFile, which reject Zig's overlapped sockets.
fn openWs() !std.net.Stream {
    const addr = try std.net.Address.parseIp4("127.0.0.1", PORT);
    const s = try std.net.tcpConnectToAddress(addr);
    errdefer s.close();
    _ = try posix.send(s.handle, upgrade_req, 0);
    var buf: [512]u8 = undefined;
    const n = try posix.recv(s.handle, &buf, 0);
    if (!std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 101")) return error.BadUpgrade;
    return s;
}

test "server stops cleanly right after accepting a WebSocket upgrade" {
    const allocator = std.heap.page_allocator;
    for (0..ITERATIONS) |_| {
        var state = ws_server.SharedState.init(allocator);
        defer state.deinit();
        var srv = try http_server.HttpServer.init(allocator, &state, PORT, null, null);
        try srv.start();

        const client = openWs() catch |err| {
            srv.deinit();
            return err;
        };
        defer client.close();

        var waited_ms: u32 = 0;
        while (state.clientCount() != 1 and waited_ms < 3000) : (waited_ms += 1) {
            std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expectEqual(@as(usize, 1), state.clientCount());

        srv.deinit();
    }
}
