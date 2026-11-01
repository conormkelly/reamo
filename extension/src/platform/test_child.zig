//! Tests only: run a body in a forked child, so that a panic or a fatal
//! signal fails the one test instead of ending the test run. POSIX only.
const std = @import("std");
const posix = std.posix;

pub const Outcome = union(enum) { exited: u8, signaled: u32 };

/// Run `body` in a forked child. The child exits 0 if `body` returns without
/// error and 1 if it returns one. It ends with _exit, so the test runner's
/// atexit handlers don't run a second time in the child.
pub fn run(comptime body: fn () anyerror!void) !Outcome {
    const pid = try posix.fork();
    if (pid == 0) {
        body() catch std.c._exit(1);
        std.c._exit(0);
    }
    const status = posix.waitpid(pid, 0).status;
    if (posix.W.IFSIGNALED(status)) return .{ .signaled = posix.W.TERMSIG(status) };
    return .{ .exited = posix.W.EXITSTATUS(status) };
}
