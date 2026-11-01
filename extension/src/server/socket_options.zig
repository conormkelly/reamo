//! Setting options on a connection's socket without risking a panic.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Error = posix.SetSockOptError || error{ InvalidArgument, ConnectionShutDown, NotOpenForWriting };

/// setsockopt on a connection's socket, without posix.setsockopt's
/// `unreachable`s. macOS fails any setsockopt on a socket that is shut down
/// both ways with EINVAL: one its peer has reset, which a phone can do at any
/// moment, or one REAmo has shut down. Zig 0.15's posix.setsockopt treats
/// EINVAL as unreachable, so that would panic REAPER.
///
/// EINVAL also means a bad option or value. The two are told apart by
/// whether the socket still has a peer (getpeername): if it does, the
/// argument was bad (error.InvalidArgument); if not, the connection is shut
/// down (error.ConnectionShutDown). That can't tell a peer's reset from our
/// own shutdown, and on Linux, which doesn't fail options on a shut-down
/// socket, a bad argument on a reset socket also reads as ConnectionShutDown.
/// Either way the connection is over. EBADF and ENOTSOCK are errors too.
/// Windows goes through posix.setsockopt, which returns errors there.
pub fn setConnectionOption(socket: posix.socket_t, level: i32, name: u32, value: []const u8) Error!void {
    if (comptime builtin.os.tag == .windows) return posix.setsockopt(socket, level, name, value);
    switch (posix.errno(posix.system.setsockopt(socket, level, name, value.ptr, @intCast(value.len)))) {
        .SUCCESS => {},
        .INVAL => return if (hasPeer(socket)) error.InvalidArgument else error.ConnectionShutDown,
        .BADF => return error.NotOpenForWriting,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Whether the socket is still connected to a peer. Not posix.getpeername:
/// macOS fails getpeername on a socket shut down both ways with EINVAL, which
/// posix.getpeername treats as unreachable.
fn hasPeer(socket: posix.socket_t) bool {
    var address: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    return posix.errno(posix.system.getpeername(socket, @ptrCast(&address), &len)) == .SUCCESS;
}

// ============================================================================
// Tests
//
// Each runs in a forked child, so that a panic (posix.setsockopt's
// unreachable) fails one test rather than the test run.
// ============================================================================

const testing = std.testing;

const test_child = @import("../platform/test_child.zig");
const ChildOutcome = test_child.Outcome;

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

test "setConnectionOption: a socket its peer has already reset is ConnectionShutDown on macOS, not a panic" {
    // As when a phone drops between connecting and its WebSocket handler
    // enlarging the send buffer.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const outcome = try test_child.run(struct {
        fn body() !void {
            const socket = try serverSocketReset();
            const size: c_int = 4 * 1024 * 1024;
            const result = setConnectionOption(socket, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&size));
            if (comptime builtin.os.tag.isDarwin()) {
                if (result) |_| return error.ExpectedAnError else |err| if (err != error.ConnectionShutDown) return err;
            } else {
                // Linux sets options on a reset socket without complaint.
                try result;
            }
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

test "setConnectionOption: a socket REAmo shut down is ConnectionShutDown on macOS, not a panic" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const outcome = try test_child.run(struct {
        fn body() !void {
            var pair: [2]posix.socket_t = undefined;
            if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SocketPair;
            try posix.shutdown(pair[0], .both);
            const size: c_int = 4 * 1024 * 1024;
            const result = setConnectionOption(pair[0], posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&size));
            if (comptime builtin.os.tag.isDarwin()) {
                if (result) |_| return error.ExpectedAnError else |err| if (err != error.ConnectionShutDown) return err;
            } else {
                try result;
            }
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

test "setConnectionOption: a bad argument on a connected socket is InvalidArgument, not a panic" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const outcome = try test_child.run(struct {
        fn body() !void {
            var pair: [2]posix.socket_t = undefined;
            if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SocketPair;
            // One byte where SO_SNDBUF needs an int.
            const result = setConnectionOption(pair[0], posix.SOL.SOCKET, posix.SO.SNDBUF, &[_]u8{1});
            if (result) |_| return error.ExpectedAnError else |err| if (err != error.InvalidArgument) return err;
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

/// Every `posix.setsockopt(` in `source` before its first top-level test,
/// outside setConnectionOption.
fn setsockoptCallsOutside(source: []const u8, out: *std.ArrayList(usize)) !void {
    var function: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.startsWith(u8, line, "test \"")) break;
        if (std.mem.indexOf(u8, line, "fn ")) |at| {
            const rest = line[at + 3 ..];
            if (std.mem.indexOfScalar(u8, rest, '(')) |end| function = rest[0..end];
        }
        if (std.mem.indexOf(u8, line, "posix.setsockopt(") == null) continue;
        if (!std.mem.eql(u8, function, "setConnectionOption")) try out.append(testing.allocator, number);
    }
}

test "lint: sockets get options only through setConnectionOption" {
    // posix.setsockopt panics REAPER on macOS when a phone has reset the
    // connection. REAmo's own code sets no listener options, so outside
    // setConnectionOption it may not appear at all, test code (files named
    // *_test.zig, and each file's tests) aside. A source scan, run from
    // `zig build test` in extension/.
    var src = std.fs.cwd().openDir("src", .{ .iterate = true }) catch |err| {
        std.debug.print("lint: can't open src/ from the test's working directory ({s}); run zig build test in extension/\n", .{@errorName(err)});
        return err;
    };
    defer src.close();
    var walker = try src.walk(testing.allocator);
    defer walker.deinit();
    var scanned: usize = 0;
    var failed = false;
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        const source = try src.readFileAlloc(testing.allocator, entry.path, 16 * 1024 * 1024);
        defer testing.allocator.free(source);
        scanned += 1;
        var found: std.ArrayList(usize) = .empty;
        defer found.deinit(testing.allocator);
        try setsockoptCallsOutside(source, &found);
        if (found.items.len > 0) {
            std.debug.print("posix.setsockopt outside setConnectionOption: src/{s}, lines {any}\n", .{ entry.path, found.items });
            failed = true;
        }
    }
    // The scan has to have found the code it guards.
    try testing.expect(scanned > 50);
    if (failed) return error.SetsockoptOutsideSetConnectionOption;
}
