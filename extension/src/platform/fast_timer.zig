//! Fast Timer for Command Queue Processing
//!
//! A 10ms timer (100Hz on macOS, ~63Hz on Windows) drains the WebSocket
//! command queue, separate from the 30Hz polling timer, so every command
//! (MIDI, transport, parameters) spends less time queued: at most one
//! interval, so up to 33ms (~16ms average) at 30Hz vs up to 10ms (~5ms
//! average) at 100Hz, or ~16ms (~8ms average) on Windows.
//!
//! Platform implementations:
//! - macOS: dispatch_source (GCD) on the main queue.
//! - Windows: Win32 SetTimer with TIMERPROC. USER timers fire on the
//!   ~15.6ms system tick, so the 10ms timer runs at ~63Hz (measured 15.8ms
//!   on Windows 10 22H2, idle or playing); timeBeginPeriod(1) doesn't change
//!   that (measured).
//! - Linux: not implemented. zig_fast_timer_start returns false and commands
//!   drain at 30Hz from the polling timer's fallback. SWELL's SetTimer with a
//!   TIMERPROC (wrapping glib timers) is the likely route.
//!
//! The callback fires on the main thread, safe for REAPER API calls. If the
//! timer fails to start, the 30Hz timer keeps draining the queue.
//!
//! Deliberately not done:
//! - Draining from the audio hook (once per audio block, e.g. 375Hz at 128
//!   samples/48kHz): it runs on the audio thread, where StuffMIDIMessage isn't
//!   safe.
//! - A lock-free queue: a mutex push/pop costs well under a microsecond
//!   against a 10ms interval.
//! - Virtual MIDI ports (CoreMIDI; on Windows the licensed virtualMIDI SDK or
//!   a user-installed loopMIDI): they would skip the queue but make the user
//!   pick the port in REAPER's preferences; armed tracks work as they are.
//! - 100Hz on Windows: a high-resolution waitable timer on a worker thread,
//!   posting to a main-thread window, measured 11ms, but its thread and
//!   unload teardown aren't worth ~3ms of command wait.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../core/logging.zig");

/// Timer interval in milliseconds (100Hz = 10ms)
pub const COMMAND_TIMER_INTERVAL: c_uint = 10;

/// The interval the timer fires at in practice: on Windows the 10ms request
/// lands on the ~15.6ms system tick (measured 15.8ms average).
pub const EXPECTED_INTERVAL_MS: i64 = if (builtin.os.tag == .windows) 16 else COMMAND_TIMER_INTERVAL;

/// A tick counts as a slip when it is more than half an interval late,
/// i.e. the main thread was busy through a tick.
pub fn isSlip(delta_ms: i64) bool {
    return isSlipAt(EXPECTED_INTERVAL_MS, delta_ms);
}

fn isSlipAt(interval_ms: i64, delta_ms: i64) bool {
    return delta_ms > interval_ms + @divTrunc(interval_ms, 2);
}

/// Simple callback type (no parameters needed - state accessed via globals)
pub const FastTimerCallback = *const fn () callconv(.c) void;

// =============================================================================
// Platform-specific implementations
// =============================================================================

// Native timer API (macOS via dispatch_source, Linux stub)
extern fn zig_fast_timer_start(interval_ms: c_uint, callback: ?FastTimerCallback) bool;
extern fn zig_fast_timer_stop() void;
extern fn zig_fast_timer_is_running() bool;

// Win32 imports (Windows only)
const win32 = if (builtin.os.tag == .windows) struct {
    const TIMERPROC = *const fn (?*anyopaque, c_uint, usize, c_uint) callconv(.c) void;

    extern "user32" fn SetTimer(
        hwnd: ?*anyopaque,
        nIDEvent: usize,
        uElapse: c_uint,
        lpTimerFunc: ?TIMERPROC,
    ) callconv(.c) usize;

    extern "user32" fn KillTimer(
        hwnd: ?*anyopaque,
        uIDEvent: usize,
    ) callconv(.c) c_int;
} else struct {};

// =============================================================================
// FastTimer
// =============================================================================

/// Fast timer for command queue processing.
/// Uses platform-native timers with main-thread callbacks.
pub const FastTimer = struct {
    timer_id: usize = 0,
    running: bool = false,
    callback: ?FastTimerCallback = null,

    /// Start the timer with the given callback.
    /// The callback fires on the main thread every EXPECTED_INTERVAL_MS or so.
    /// Returns error if timer creation fails.
    pub fn start(self: *FastTimer, callback: FastTimerCallback) !void {
        if (self.running) return;

        self.callback = callback;

        if (builtin.os.tag == .windows) {
            // Windows: Use SetTimer with TIMERPROC wrapper
            const id = win32.SetTimer(null, 0, COMMAND_TIMER_INTERVAL, &win32TimerProc);
            if (id == 0) {
                logging.warn("FastTimer: SetTimer failed (Win32 error {d})", .{@intFromEnum(std.os.windows.GetLastError())});
                return error.TimerCreationFailed;
            }
            self.timer_id = id;
            self.running = true;
            // Store self pointer for callback (Windows TIMERPROC doesn't have user data)
            g_timer_instance = self;
        } else {
            // macOS/Linux: Use native implementation
            if (zig_fast_timer_start(COMMAND_TIMER_INTERVAL, callback)) {
                self.running = true;
                logging.debug("FastTimer: started at {}ms interval (native)", .{COMMAND_TIMER_INTERVAL});
            } else {
                // Linux has no native timer; macOS failing is the caller's to log.
                return error.TimerCreationFailed;
            }
        }
    }

    /// Stop the timer.
    pub fn stop(self: *FastTimer) void {
        if (!self.running) return;

        if (builtin.os.tag == .windows) {
            _ = win32.KillTimer(null, self.timer_id);
            g_timer_instance = null;
        } else {
            zig_fast_timer_stop();
        }

        logging.debug("FastTimer: stopped", .{});
        self.running = false;
        self.timer_id = 0;
        self.callback = null;
    }

    /// Check if the timer is currently running.
    pub fn isRunning(self: *const FastTimer) bool {
        if (builtin.os.tag == .windows) {
            return self.running;
        } else {
            return zig_fast_timer_is_running();
        }
    }
};

// Global instance for Windows TIMERPROC callback (no user data parameter)
var g_timer_instance: ?*FastTimer = null;

/// Windows TIMERPROC wrapper - calls the stored callback
fn win32TimerProc(_: ?*anyopaque, _: c_uint, _: usize, _: c_uint) callconv(.c) void {
    if (g_timer_instance) |timer| {
        if (timer.callback) |cb| {
            cb();
        }
    }
}

test "a tick on the timer's grid is not a slip; a missed tick is" {
    // Windows: measured 14-17ms between ticks, 29-32ms when a tick is missed.
    try std.testing.expect(!isSlipAt(16, 17));
    try std.testing.expect(!isSlipAt(16, 24));
    try std.testing.expect(isSlipAt(16, 25));
    try std.testing.expect(isSlipAt(16, 29));
    // macOS: 10ms ticks.
    try std.testing.expect(!isSlipAt(10, 15));
    try std.testing.expect(isSlipAt(10, 16));
}

test "an on-time tick on this platform is not a slip" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(i64, 16), EXPECTED_INTERVAL_MS);
        try std.testing.expect(!isSlip(18));
    } else {
        try std.testing.expectEqual(@as(i64, 10), EXPECTED_INTERVAL_MS);
        try std.testing.expect(!isSlip(15));
    }
}
