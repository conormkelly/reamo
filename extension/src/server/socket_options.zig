//! Setting options on a connection's socket without risking a panic.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Error = posix.SetSockOptError || error{ ConnectionResetByPeer, NotOpenForWriting };

/// setsockopt on a connection's socket. macOS fails any setsockopt on a
/// socket its peer has already reset (one shut down both ways) with EINVAL,
/// which Zig 0.15's posix.setsockopt treats as unreachable: a phone dropping
/// at the wrong moment would panic REAPER. Here that is
/// error.ConnectionResetByPeer, and EBADF and ENOTSOCK are errors too.
/// Windows goes through posix.setsockopt, which has no such case.
pub fn setConnectionOption(socket: posix.socket_t, level: i32, name: u32, value: []const u8) Error!void {
    if (comptime builtin.os.tag == .windows) return posix.setsockopt(socket, level, name, value);
    switch (posix.errno(posix.system.setsockopt(socket, level, name, value.ptr, @intCast(value.len)))) {
        .SUCCESS => {},
        .INVAL => return error.ConnectionResetByPeer,
        .BADF => return error.NotOpenForWriting,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const ChildOutcome = union(enum) { exited: u8, signaled: u32 };

/// Run `body` in a forked child, so that a panic fails the test rather than
/// the test run. The child exits 0 if `body` returns without error.
fn runInChild(comptime body: fn () anyerror!void) !ChildOutcome {
    const pid = try posix.fork();
    if (pid == 0) {
        body() catch posix.exit(1);
        posix.exit(0);
    }
    const status = posix.waitpid(pid, 0).status;
    if (posix.W.IFSIGNALED(status)) return .{ .signaled = posix.W.TERMSIG(status) };
    return .{ .exited = posix.W.EXITSTATUS(status) };
}

/// A TCP connection whose client reset it before it was accepted: the
/// server's end.
fn serverSocketReset() !posix.socket_t {
    const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(listener);
    var address = try std.net.Address.parseIp("127.0.0.1", 0);
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1);
    var len: posix.socklen_t = address.getOsSockLen();
    try posix.getsockname(listener, &address.any, &len);
    const client = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.connect(client, &address.any, address.getOsSockLen());
    const linger = extern struct { onoff: c_int, linger: c_int }{ .onoff = 1, .linger = 0 };
    _ = posix.system.setsockopt(client, posix.SOL.SOCKET, posix.SO.LINGER, std.mem.asBytes(&linger), @sizeOf(@TypeOf(linger)));
    posix.close(client);
    std.Thread.sleep(20 * std.time.ns_per_ms);
    return posix.accept(listener, null, null, 0);
}

test "setConnectionOption: a socket its peer has already reset is an error on macOS, not a panic" {
    // As when a phone drops between connecting and its WebSocket handler
    // enlarging the send buffer.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        fn body() !void {
            const socket = try serverSocketReset();
            const size: c_int = 4 * 1024 * 1024;
            const result = setConnectionOption(socket, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&size));
            if (comptime builtin.os.tag.isDarwin()) {
                if (result) |_| return error.ExpectedAnError else |err| if (err != error.ConnectionResetByPeer) return err;
            } else {
                // Linux sets options on a reset socket without complaint.
                try result;
            }
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}
