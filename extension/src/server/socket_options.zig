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

/// A `.setsockopt` reference in source: its line, and the innermost named
/// function it sits in ("" outside any).
const SetsockoptUse = struct { line: usize, function: []const u8 };

/// Every `.setsockopt` reference in `source` outside test blocks, with the
/// function it sits in. A source scan over Zig tokens (std.zig.Tokenizer),
/// so comments and strings are not code, spacing and newlines don't matter,
/// and any receiver counts: `posix.setsockopt(...)`, `p.setsockopt` after
/// `const p = std.posix;`, and `= posix.setsockopt;` aliases alike.
///
/// The function is tracked by brace depth: a `fn name` opens it at the
/// first `{` after its parameters that isn't a type's (`error{`, `struct {`,
/// ...), and it closes with that brace. Test blocks (`test ... { }`) are
/// skipped the same way, wherever they are in the file.
///
/// What it can't see: a name built at comptime (`@field(posix, "setsockopt")`),
/// a call through a function pointer obtained somewhere else, an
/// `@"setsockopt"` identifier, or a wrapper in another module (std itself,
/// or a dependency) that calls setsockopt on our behalf.
fn findSetsockopt(allocator: std.mem.Allocator, source: [:0]const u8, out: *std.ArrayList(SetsockoptUse)) !void {
    const Function = struct { name: []const u8, depth: usize };
    var functions: std.ArrayList(Function) = .empty;
    defer functions.deinit(allocator);

    var tokenizer = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var parens: usize = 0;
    // The depth a test block's closing brace returns to, while inside one.
    var in_test: ?usize = null;
    var test_pending = false;
    // A `fn name` whose body hasn't opened yet, and the paren depth it began at.
    var pending: ?Function = null;
    var prev: std.zig.Token.Tag = .invalid;
    var line: usize = 1;
    var scanned_to: usize = 0;

    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        defer prev = token.tag;
        switch (token.tag) {
            .keyword_test => if (in_test == null) {
                test_pending = true;
            },
            .l_brace => {
                if (test_pending) {
                    test_pending = false;
                    in_test = depth;
                } else if (pending) |p| if (parens == p.depth and !isTypeBrace(prev)) {
                    try functions.append(allocator, .{ .name = p.name, .depth = depth });
                    pending = null;
                };
                depth += 1;
            },
            .r_brace => {
                depth -|= 1;
                if (in_test) |d| if (depth == d) {
                    in_test = null;
                };
                while (functions.items.len > 0 and functions.items[functions.items.len - 1].depth >= depth) _ = functions.pop();
            },
            .l_paren => parens += 1,
            .r_paren => parens -|= 1,
            // A prototype (`extern fn x() void;`) or a function type: no body.
            .semicolon => if (pending) |p| if (parens == p.depth) {
                pending = null;
            },
            .identifier => {
                const name = source[token.loc.start..token.loc.end];
                if (prev == .keyword_fn) {
                    pending = .{ .name = name, .depth = parens };
                } else if (prev == .period and in_test == null and std.mem.eql(u8, name, "setsockopt")) {
                    line += std.mem.count(u8, source[scanned_to..token.loc.start], "\n");
                    scanned_to = token.loc.start;
                    const function = if (functions.items.len > 0) functions.items[functions.items.len - 1].name else "";
                    try out.append(allocator, .{ .line = line, .function = function });
                }
            },
            else => {},
        }
    }
}

fn isTypeBrace(prev: std.zig.Token.Tag) bool {
    return switch (prev) {
        .keyword_error, .keyword_struct, .keyword_enum, .keyword_union, .keyword_opaque => true,
        else => false,
    };
}

test "findSetsockopt: finds every spelling outside test blocks and knows its function" {
    const source =
        \\const std = @import("std");
        \\const p = std.posix;
        \\const alias = p.setsockopt;
        \\test "first" {
        \\    p.setsockopt(1, 2, 3, "");
        \\}
        \\fn afterTest() error{A}!void {
        \\    // p.setsockopt( in a comment
        \\    const s = "p.setsockopt(";
        \\    _ = s;
        \\    std.posix
        \\        . setsockopt (1, 2, 3, "");
        \\}
        \\const top = 1; // fn notAFunction() {
        \\const T = struct {
        \\    fn method() void {
        \\        _ = std.posix.system.setsockopt;
        \\    }
        \\};
        \\fn allowed() void {
        \\    p.setsockopt(1, 2, 3, "");
        \\}
    ;
    var found: std.ArrayList(SetsockoptUse) = .empty;
    defer found.deinit(std.testing.allocator);
    try findSetsockopt(std.testing.allocator, source, &found);
    try std.testing.expectEqual(4, found.items.len);
    try std.testing.expectEqual(3, found.items[0].line);
    try std.testing.expectEqualStrings("", found.items[0].function);
    try std.testing.expectEqual(12, found.items[1].line);
    try std.testing.expectEqualStrings("afterTest", found.items[1].function);
    try std.testing.expectEqual(17, found.items[2].line);
    try std.testing.expectEqualStrings("method", found.items[2].function);
    try std.testing.expectEqual(21, found.items[3].line);
    try std.testing.expectEqualStrings("allowed", found.items[3].function);
}

/// Where a `.setsockopt` may appear in REAmo's own code, outside tests.
/// Raw calls only, which return errors rather than panic.
const allowed_setsockopt = [_]struct { file: []const u8, function: []const u8 }{
    // The one place sockets get options.
    .{ .file = "server/socket_options.zig", .function = "setConnectionOption" },
    // Test helper (sets SO_LINGER on a test client through the raw call).
    .{ .file = "server/socket_options.zig", .function = "serverSocketReset" },
};

test "lint: sockets get options only through setConnectionOption" {
    // posix.setsockopt panics REAPER on macOS when a phone has reset the
    // connection, so outside the places above `.setsockopt` may not appear
    // at all. Test blocks, and files named *_test.zig, aside. Run from
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
        const source = try src.readFileAllocOptions(testing.allocator, entry.path, 16 * 1024 * 1024, null, .of(u8), 0);
        defer testing.allocator.free(source);
        scanned += 1;
        var found: std.ArrayList(SetsockoptUse) = .empty;
        defer found.deinit(testing.allocator);
        try findSetsockopt(testing.allocator, source, &found);
        for (found.items) |use| {
            const ok = for (allowed_setsockopt) |a| {
                if (std.mem.eql(u8, a.file, entry.path) and std.mem.eql(u8, a.function, use.function)) break true;
            } else false;
            if (ok) continue;
            std.debug.print("setsockopt outside setConnectionOption: src/{s}:{d} (in fn {s})\n", .{ entry.path, use.line, if (use.function.len > 0) use.function else "<none>" });
            failed = true;
        }
    }
    // The scan has to have found the code it guards.
    try testing.expect(scanned > 50);
    if (failed) return error.SetsockoptOutsideSetConnectionOption;
}
