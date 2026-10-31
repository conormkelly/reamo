//! Every accepted WebSocket socket must have TCP_NODELAY set. With Nagle's
//! algorithm on, a small frame (a MIDI note, a fader move) can wait 40–200 ms
//! for the previous one's ACK.
//!
//! Runs a real HttpServer on loopback, upgrades one WebSocket, and asks the OS
//! about the server's side of that connection.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const http_server = @import("http_server.zig");
const ws_server = @import("ws_server.zig");

const PORT: u16 = 19612;

const upgrade_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:19612\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

/// Whether TCP_NODELAY is on. Winsock may report the option as one byte, and
/// std.posix.getsockopt assumes POSIX errno and a full-width result, so Windows
/// calls ws2_32 directly.
fn tcpNoDelay(handle: posix.socket_t) !bool {
    var value = [_]u8{0} ** 4;
    var len: usize = value.len;
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        var win_len: i32 = value.len;
        if (ws2_32.getsockopt(handle, ws2_32.IPPROTO.TCP, ws2_32.TCP.NODELAY, &value, &win_len) == ws2_32.SOCKET_ERROR) {
            std.debug.print("getsockopt(TCP_NODELAY) failed: {}\n", .{ws2_32.WSAGetLastError()});
            return error.GetSockOptFailed;
        }
        len = @intCast(win_len);
    } else {
        try posix.getsockopt(handle, posix.IPPROTO.TCP, posix.TCP.NODELAY, &value);
    }
    return !std.mem.allEqual(u8, value[0..len], 0);
}

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

test "accepted WebSocket sockets have TCP_NODELAY so small frames are not held back by Nagle" {
    const allocator = std.heap.page_allocator;
    var state = ws_server.SharedState.init(allocator);
    defer state.deinit();
    var srv = try http_server.HttpServer.init(allocator, &state, PORT, null, null);
    defer srv.deinit();
    try srv.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const client = try openWs();
    defer client.close();

    waitForClientCount(&state, 1);
    try std.testing.expectEqual(@as(usize, 1), state.clientCount());

    const server_side = blk: {
        state.client_rwlock.lockShared();
        defer state.client_rwlock.unlockShared();
        break :blk state.clients.values()[0].stream.handle;
    };
    try std.testing.expect(try tcpNoDelay(server_side));
}

fn waitForClientCount(state: *ws_server.SharedState, count: usize) void {
    var waited_ms: u32 = 0;
    while (state.clientCount() != count and waited_ms < 3000) : (waited_ms += 10) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

test "tcpNoDelay reports TCP_NODELAY off on a fresh socket and on once set" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.deinit();
    const client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();

    try std.testing.expect(!try tcpNoDelay(client.handle));
    try posix.setsockopt(client.handle, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    try std.testing.expect(try tcpNoDelay(client.handle));
}
