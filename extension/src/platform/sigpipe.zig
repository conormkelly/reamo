/// SIGPIPE guard for socket writes inside the REAPER process.
///
/// On macOS and Linux, writing to a socket whose peer has gone away raises
/// SIGPIPE, and the default action terminates the process — REAPER itself,
/// since the extension runs in-process. A phone that drops off Wi-Fi mid-broadcast
/// is enough. No crash report is written for this kind of death.
///
/// The httpz and websocket.zig forks never raise SIGPIPE themselves: every
/// send passes MSG_NOSIGNAL, and Darwin sockets get SO_NOSIGPIPE when
/// accepted. This handler is the second layer, for any write those don't
/// cover. It can't be the only one: whatever else runs in REAPER can replace
/// it (Tracy's crash handler turns SIGPIPE into an abort).
///
/// macOS REAPER leaves SIGPIPE at its default action: its only handler is
/// installed lazily by WDL_SHM_Connection (bridged plugins). Linux REAPER
/// (6.0 and 7.83 checked) installs a no-op handler in main(), before any
/// plugin loads, so there this one stands aside. Zig installs a no-op handler
/// for executables in start.zig, but a shared library never runs that code,
/// so the extension has to do it.
///
/// A no-op handler is used rather than SIG_IGN — matching WDL and Zig's start.zig
/// — because ignored dispositions survive exec() into child processes REAPER
/// launches, while caught signals reset to the default. With the handler in
/// place the write fails with EPIPE (error.BrokenPipe) and the connection is
/// torn down through the normal error path.
///
/// Windows has no SIGPIPE; everything here is a no-op there.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const supported = builtin.os.tag != .windows;

/// Whether `install` put our handler in place. Read and written only from
/// REAPER's main thread (plugin entry and shutdown).
var g_installed: bool = false;

/// Install the no-op SIGPIPE handler, unless something in the process already
/// chose a non-default disposition (REAPER/WDL, another extension) — that
/// choice already prevents termination and is not ours to replace.
pub fn install() void {
    if (comptime !supported) return;
    var current: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.PIPE, null, &current);
    if (current.handler.handler != posix.SIG.DFL) return;

    const act: posix.Sigaction = .{
        .handler = .{ .handler = noopHandler },
        .mask = posix.sigemptyset(),
        // A signal delivered mid-syscall must not surface as EINTR elsewhere.
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
    g_installed = true;
}

/// Restore the default disposition if our handler is still the active one.
/// Must run before the library is unloaded: a handler pointing into unmapped
/// code would turn the next SIGPIPE into a crash. A handler someone else
/// installed after us is left alone.
pub fn uninstall() void {
    if (comptime !supported) return;
    if (!g_installed) return;
    g_installed = false;

    var current: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.PIPE, null, &current);
    if (current.handler.handler != noopHandler) return;

    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}

fn noopHandler(_: i32) callconv(.c) void {}

// ============================================================================
// Tests
//
// The Zig test runner is an executable, so start.zig has already replaced
// SIGPIPE's default action with a no-op handler. Each test forks and resets
// SIGPIPE to SIG_DFL in the child to reproduce REAPER's environment, which
// also keeps disposition changes out of the test runner itself.
// ============================================================================

const testing = std.testing;

fn currentHandler() ?posix.Sigaction.handler_fn {
    var old: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.PIPE, null, &old);
    return old.handler.handler;
}

fn setHandler(handler: ?posix.Sigaction.handler_fn) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}

/// Write to a socket whose peer is closed. Returns normally only if the write
/// fails with error.BrokenPipe; a SIGPIPE at default disposition never returns.
fn writeToClosedPeer() !void {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    defer posix.close(fds[0]);
    posix.close(fds[1]);
    _ = posix.write(fds[0], "peaks") catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
    return error.WriteSucceeded;
}

const ChildOutcome = union(enum) { exited: u8, signaled: u32 };

/// Run `body` in a forked child starting from SIGPIPE = SIG_DFL.
/// The child exits 0 if `body` returns without error, 1 otherwise.
fn runInChild(comptime body: fn () anyerror!void) !ChildOutcome {
    const pid = try posix.fork();
    if (pid == 0) {
        setHandler(posix.SIG.DFL);
        body() catch posix.exit(1);
        posix.exit(0);
    }
    const status = posix.waitpid(pid, 0).status;
    if (posix.W.IFSIGNALED(status)) return .{ .signaled = posix.W.TERMSIG(status) };
    return .{ .exited = posix.W.EXITSTATUS(status) };
}

test "a write to a closed peer kills the process when SIGPIPE is at its default action" {
    if (!supported) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        fn body() !void {
            try writeToClosedPeer();
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .signaled = posix.SIG.PIPE }, outcome);
}

test "install turns a write to a closed peer into error.BrokenPipe instead of process death" {
    if (!supported) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        fn body() !void {
            install();
            try writeToClosedPeer();
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

test "install uses a caught handler, not SIG_IGN, so processes REAPER launches keep default SIGPIPE" {
    if (!supported) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        fn body() !void {
            install();
            if (currentHandler() != noopHandler) return error.NotCaughtHandler;
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

test "install and uninstall leave a disposition chosen by someone else untouched" {
    if (!supported) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        fn body() !void {
            setHandler(posix.SIG.IGN);
            install();
            if (currentHandler() != posix.SIG.IGN) return error.InstallReplacedExisting;
            uninstall();
            if (currentHandler() != posix.SIG.IGN) return error.UninstallReplacedExisting;
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

test "uninstall restores the default action so no handler points into an unloaded library" {
    if (!supported) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        fn body() !void {
            install();
            if (currentHandler() == posix.SIG.DFL) return error.NotInstalled;
            uninstall();
            if (currentHandler() != posix.SIG.DFL) return error.NotRestored;
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}

test "uninstall leaves a handler installed after ours in place" {
    if (!supported) return error.SkipZigTest;
    const outcome = try runInChild(struct {
        var calls: u32 = 0;
        // Must not be an empty body: optimized builds fold identical
        // functions, which would give this noopHandler's address.
        fn other(_: i32) callconv(.c) void {
            calls += 1;
        }
        fn body() !void {
            install();
            setHandler(other);
            uninstall();
            if (currentHandler() != other) return error.ClobberedLaterHandler;
        }
    }.body);
    try testing.expectEqual(ChildOutcome{ .exited = 0 }, outcome);
}
