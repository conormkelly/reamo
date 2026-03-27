/// Cross-platform compatibility shims.
///
/// Provides platform-abstracted versions of APIs that differ between
/// POSIX (macOS/Linux) and Windows. Keeps platform #ifdefs in one place
/// so call sites stay clean.

const std = @import("std");
const builtin = @import("builtin");

/// Maximum hostname length. POSIX uses HOST_NAME_MAX (typically 255),
/// Windows MAX_COMPUTERNAME_LENGTH is 15 but DNS hostnames can be up to 256.
pub const HOSTNAME_MAX: usize = if (builtin.os.tag == .windows) 256 else std.posix.HOST_NAME_MAX;

/// Get the local machine's hostname.
/// On POSIX: wraps std.posix.gethostname.
/// On Windows: uses kernel32.GetComputerNameExA (DNS hostname format).
pub fn getHostname(buf: *[HOSTNAME_MAX]u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        const ComputerNameDnsHostname = 1;
        var len: u32 = HOSTNAME_MAX;
        if (win32.GetComputerNameExA(ComputerNameDnsHostname, buf, &len) != 0) {
            return buf[0..len];
        }
        return null;
    } else {
        return std.posix.gethostname(buf) catch null;
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetComputerNameExA(u32, [*]u8, *u32) callconv(.winapi) c_int;
} else struct {};
