/// Audio hook module — registers with REAPER's Audio_RegHardwareHook to capture
/// post-master-FX output on the real-time audio thread.
///
/// The OnAudioBuffer callback converts deinterleaved f64 channels to interleaved
/// i16 and writes to a lock-free SPSC ring buffer. The network thread (in stream.zig)
/// reads from this buffer and sends binary WebSocket frames.
const std = @import("std");
const raw = @import("../reaper/raw.zig");
const ring_buffer = @import("ring_buffer.zig");
const logging = @import("../core/logging.zig");

// ============================================================================
// Module-level state (accessed by C callback)
// ============================================================================

/// The ring buffer shared between the audio thread (writer) and network thread (reader).
/// Module-level var so it lives for the lifetime of the plugin.
var g_ring_buffer: ring_buffer.AudioRingBuffer = .{};

/// REAPER audio hook registration struct. Module-level so the pointer stays valid
/// for the entire duration of hook registration.
var g_hook_reg: raw.AudioHookRegister = .{
    .OnAudioBuffer = onAudioBuffer,
};

/// Whether the hook is currently registered with REAPER.
var g_registered: bool = false;

// Diagnostic counters (atomic, safe to read from any thread)
pub var diag_callback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_post_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_no_getbuffer: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_low_nch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_no_left: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_write_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_last_nch: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

// ============================================================================
// Public API
// ============================================================================

/// Register the audio hook with REAPER. Call from main thread.
/// Returns true on success.
pub fn register(api: *const raw.Api) bool {
    if (g_registered) return true;

    // Reset ring buffer state before starting capture
    g_ring_buffer.reset();

    if (api.registerAudioHook(&g_hook_reg)) {
        g_registered = true;
        logging.info("Audio hook registered", .{});
        return true;
    }
    logging.err("Failed to register audio hook", .{});
    return false;
}

/// Unregister the audio hook from REAPER. Call from main thread.
pub fn unregister(api: *const raw.Api) void {
    if (!g_registered) return;
    api.unregisterAudioHook(&g_hook_reg);
    g_registered = false;
    logging.info("Audio hook unregistered", .{});
}

/// Get a pointer to the ring buffer for the network thread to read from.
pub fn getRingBuffer() *ring_buffer.AudioRingBuffer {
    return &g_ring_buffer;
}

/// Check whether the hook is currently registered.
pub fn isRegistered() bool {
    return g_registered;
}

// ============================================================================
// Audio thread callback
// ============================================================================

/// Called by REAPER on the audio thread, twice per buffer (pre and post processing).
/// REAL-TIME SAFE: No allocations, no locks, no I/O, no logging.
fn onAudioBuffer(isPost: bool, len: c_int, srate: f64, reg: *raw.AudioHookRegister) callconv(.c) void {
    _ = diag_callback_count.fetchAdd(1, .monotonic);

    const sample_count: usize = if (len > 0) @intCast(len) else return;

    // GetBuffer is set by REAPER host — must check
    const get_buffer = reg.GetBuffer orelse {
        _ = diag_no_getbuffer.fetchAdd(1, .monotonic);
        return;
    };

    if (!isPost) {
        // PRE-CALLBACK: Zero output buffers before REAPER's mixer runs.
        // When transport is playing, the mixer overwrites these with fresh audio.
        // When transport is stopped, the buffers stay zeroed — eliminating stale
        // data that would otherwise repeat as a loud buzz at sampleRate/bufferSize Hz.
        // Monitoring input (guitar/vocals) still works because the mixer processes
        // live signal even when stopped, overwriting our zeros with real audio.
        // Don't iterate output_nch — REAPER may not set it in the struct.
        if (get_buffer(true, 0)) |buf| @memset(buf[0..sample_count], 0.0);
        if (get_buffer(true, 1)) |buf| @memset(buf[0..sample_count], 0.0);
        return;
    }

    _ = diag_post_count.fetchAdd(1, .monotonic);

    // Store last observed output_nch for diagnostics
    diag_last_nch.store(reg.output_nch, .monotonic);

    // Get left and right output channels directly from GetBuffer.
    // Don't check output_nch — REAPER may not set it in the struct.
    const left = get_buffer(true, 0) orelse {
        _ = diag_no_left.fetchAdd(1, .monotonic);
        return;
    };
    const right = get_buffer(true, 1) orelse return;

    // Update sample rate and write to ring buffer
    g_ring_buffer.sample_rate.store(@intFromFloat(srate), .release);
    g_ring_buffer.writeFromF64(left, right, sample_count);
    _ = diag_write_count.fetchAdd(1, .monotonic);
}

// ============================================================================
// Tests
// ============================================================================

test "getRingBuffer returns stable pointer" {
    const rb1 = getRingBuffer();
    const rb2 = getRingBuffer();
    try std.testing.expectEqual(rb1, rb2);
}

test "register and unregister with null API" {
    // With a default Api where audioRegHardwareHook is null,
    // register should return false (graceful degradation)
    const api = raw.Api{
        .showConsoleMsg = undefined,
        .register = undefined,
    };
    const result = register(&api);
    try std.testing.expect(!result);
    try std.testing.expect(!isRegistered());
}
