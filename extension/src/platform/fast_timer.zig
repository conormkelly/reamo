//! Fast Timer for Command Queue Processing
//!
//! Provides a 100Hz (10ms) timer for draining the WebSocket command queue,
//! reducing latency from ~19ms (30Hz) to ~8ms average.
//!
//! Platform implementations:
//! - macOS: dispatch_source (GCD) - precise timing, main thread callback
//! - Windows: Win32 SetTimer with TIMERPROC
//! - Linux: Falls back to 30Hz (TODO: implement via SWELL + hidden window)
//!
//! The callback fires on the main thread, safe for REAPER API calls.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../core/logging.zig");

/// Timer interval in milliseconds (100Hz = 10ms)
pub const COMMAND_TIMER_INTERVAL: c_uint = 10;

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
/// Uses platform-native timers for precise timing with main-thread callbacks.
pub const FastTimer = struct {
    timer_id: usize = 0,
    running: bool = false,
    callback: ?FastTimerCallback = null,

    /// Start the timer with the given callback.
    /// The callback will fire every COMMAND_TIMER_INTERVAL ms on the main thread.
    /// Returns error if timer creation fails.
    pub fn start(self: *FastTimer, callback: FastTimerCallback) !void {
        if (self.running) return;

        self.callback = callback;

        if (builtin.os.tag == .windows) {
            // Windows: Use SetTimer with TIMERPROC wrapper
            const id = win32.SetTimer(null, 0, COMMAND_TIMER_INTERVAL, &win32TimerProc);
            if (id == 0) {
                logging.err("FastTimer: Win32 SetTimer failed", .{});
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
                logging.info("FastTimer: started at {}ms interval (native)", .{COMMAND_TIMER_INTERVAL});
            } else {
                logging.err("FastTimer: native timer failed to start", .{});
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

        logging.info("FastTimer: stopped", .{});
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
