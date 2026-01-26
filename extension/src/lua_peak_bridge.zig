//! Lua Peak Bridge - receives peak waveform data from Lua scripts.
//!
//! This module provides the bridge between REAPER's Lua scripting environment
//! and the native extension for fetching audio peak data. The bridge uses
//! REAPER's API registration system to expose C-callable functions that Lua
//! scripts can invoke via reaper.Reamo_* functions.
//!
//! ## Architecture
//!
//! 1. Zig registers API functions with REAPER (API_, APIdef_, APIvararg_ triplets)
//! 2. Zig populates a request struct and calls the Lua script via Main_OnCommand
//! 3. Lua script reads request fields, fetches peaks, calls Reamo_ReceivePeakData
//! 4. Zig receives the data in a static buffer and returns it to the caller
//!
//! ## Thread Safety
//!
//! All operations occur on REAPER's main thread. The Lua script executes
//! synchronously via Main_OnCommand, so no locking is needed.

const std = @import("std");
const logging = @import("logging.zig");
const reaper = @import("reaper.zig");

/// Global API reference - must be set by main.zig before use.
/// Required for bridgeFetchAdapter() to call runCommand().
pub var g_api: ?*const reaper.Api = null;

/// Plugin register function type (matches REAPER's signature)
pub const PluginRegisterFn = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int;

pub const LuaPeakBridge = struct {
    const MAX_PEAKS = 65536; // 64K doubles = 512KB max

    // Static buffer for received peak data
    var peak_buffer: [MAX_PEAKS]f64 = undefined;
    var peak_count: usize = 0;
    var last_receive_time: i64 = 0;

    // =========================================================================
    // Request/Response System (Zig -> Lua -> Zig)
    // =========================================================================

    /// Request struct for Zig -> Lua communication
    /// Lua reads individual fields via Reamo_GetPeakRequest*() functions
    const PeakRequest = extern struct {
        track_idx: i32 = 0,
        item_idx: i32 = 0,
        start_time: f64 = 0, // Project time (not item-relative)
        end_time: f64 = 0, // Project time
        peakrate: f64 = 0,
        channels: i32 = 0,
        valid: i32 = 0, // 0 = no request, 1 = pending
    };

    var pending_request: PeakRequest = .{};
    var lua_script_cmd_id: c_int = 0;
    var request_result: c_int = 0; // Result from Lua (peak count or error code)

    // =========================================================================
    // API Functions (C ABI)
    // =========================================================================

    /// Receive packed binary peak data from Lua via string.pack
    /// data: pointer to packed doubles (8 bytes each, little-endian)
    /// count: number of doubles in the buffer
    /// Returns number of doubles received, or -1 on error.
    pub fn receivePacked(data: ?[*]const u8, count: c_int) callconv(.c) c_int {
        if (data == null or count <= 0) {
            logging.warn("LuaPeakBridge: receivePacked got null data or count={d}", .{count});
            return -1;
        }

        const num_doubles: usize = @intCast(count);
        const to_copy = @min(num_doubles, MAX_PEAKS);

        // Copy doubles from packed bytes (explicit little-endian for cross-platform)
        // Lua sends with string.pack("<d", ...) which is little-endian
        const src = data.?;
        for (0..to_copy) |i| {
            var bytes: [8]u8 = undefined;
            for (0..8) |b| {
                bytes[b] = src[i * 8 + b];
            }
            // Read as little-endian u64, then bitcast to f64
            const bits = std.mem.readInt(u64, &bytes, .little);
            peak_buffer[i] = @bitCast(bits);
        }
        peak_count = to_copy;
        last_receive_time = std.time.milliTimestamp();

        logging.info("LuaPeakBridge: received {d} doubles via string.pack", .{to_copy});

        // Log first few values as sanity check
        if (to_copy >= 4) {
            logging.debug("  First values: [{d:.4}, {d:.4}, {d:.4}, {d:.4}]", .{
                peak_buffer[0],
                peak_buffer[1],
                peak_buffer[2],
                peak_buffer[3],
            });
        }

        return @intCast(to_copy);
    }

    /// Get the number of peaks currently in the buffer
    pub fn getCount() callconv(.c) c_int {
        return @intCast(peak_count);
    }

    /// Clear the buffer (for testing)
    pub fn clear() callconv(.c) void {
        peak_count = 0;
        logging.debug("LuaPeakBridge: buffer cleared", .{});
    }

    // Individual getters for pending request fields
    // (Can't use packed struct because const char* is null-terminated in Lua)
    pub fn getRequestValid() callconv(.c) c_int {
        return pending_request.valid;
    }

    pub fn getRequestTrackIdx() callconv(.c) c_int {
        return pending_request.track_idx;
    }

    pub fn getRequestItemIdx() callconv(.c) c_int {
        return pending_request.item_idx;
    }

    pub fn getRequestStartTime() callconv(.c) f64 {
        return pending_request.start_time;
    }

    pub fn getRequestEndTime() callconv(.c) f64 {
        return pending_request.end_time;
    }

    pub fn getRequestPeakrate() callconv(.c) f64 {
        return pending_request.peakrate;
    }

    /// Called by Lua when peak fetch is complete
    /// count: number of peaks fetched (or negative error code)
    pub fn setRequestComplete(count: c_int) callconv(.c) void {
        request_result = count;
        pending_request.valid = 0; // Clear the request
        logging.info("LuaPeakBridge: setRequestComplete called with count={d}", .{count});
    }

    // =========================================================================
    // Vararg Wrappers (REQUIRED for Lua/EEL compatibility!)
    // Signature: void* (*)(void** arglist, int numparms)
    // Without these, the function is not callable from Lua scripts.
    // =========================================================================

    /// Vararg wrapper for receivePacked
    /// arglist[0] = const char* (packed data pointer)
    /// arglist[1] = int (count) as intptr
    /// Returns int as intptr
    pub fn vararg_receivePacked(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = numparms;
        const data: ?[*]const u8 = @ptrCast(arglist[0]);
        // Use truncate to safely extract 32-bit int from potentially 64-bit value
        const raw: usize = @intFromPtr(arglist[1]);
        const count: c_int = @truncate(@as(isize, @bitCast(raw)));
        const result = receivePacked(data, count);
        return @ptrFromInt(@as(usize, @intCast(result)));
    }

    /// Vararg wrapper for getCount (no args, returns int)
    pub fn vararg_getCount(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        const result = getCount();
        return @ptrFromInt(@as(usize, @intCast(result)));
    }

    /// Vararg wrapper for clear (no args, no return)
    pub fn vararg_clear(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        clear();
        return null;
    }

    /// Vararg wrappers for request field getters
    pub fn vararg_getRequestValid(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        return @ptrFromInt(@as(usize, @intCast(getRequestValid())));
    }

    pub fn vararg_getRequestTrackIdx(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        return @ptrFromInt(@as(usize, @intCast(getRequestTrackIdx())));
    }

    pub fn vararg_getRequestItemIdx(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        return @ptrFromInt(@as(usize, @intCast(getRequestItemIdx())));
    }

    // Static storage for double return values - vararg wrappers must return
    // valid pointers to memory, not raw bits, due to ARM64 pointer authentication
    var return_start_time: f64 = 0;
    var return_end_time: f64 = 0;
    var return_peakrate: f64 = 0;

    pub fn vararg_getRequestStartTime(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        return_start_time = getRequestStartTime();
        return @ptrCast(&return_start_time);
    }

    pub fn vararg_getRequestEndTime(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        return_end_time = getRequestEndTime();
        return @ptrCast(&return_end_time);
    }

    pub fn vararg_getRequestPeakrate(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = arglist;
        _ = numparms;
        return_peakrate = getRequestPeakrate();
        return @ptrCast(&return_peakrate);
    }

    /// Vararg wrapper for setRequestComplete (int arg, no return)
    /// Integer args are passed as pointer values - use truncate not intCast to handle
    /// sign-extended negative values (e.g., -6 becomes 0xFFFFFFFFFFFFFFFA on 64-bit)
    pub fn vararg_setRequestComplete(arglist: [*]?*anyopaque, numparms: c_int) callconv(.c) ?*anyopaque {
        _ = numparms;
        // Extract the low 32 bits - this handles both positive values and
        // sign-extended negative values correctly
        const raw: usize = @intFromPtr(arglist[0]);
        const count: c_int = @truncate(@as(isize, @bitCast(raw)));
        setRequestComplete(count);
        return null;
    }

    // =========================================================================
    // Registration - All THREE registrations required for Lua!
    // =========================================================================

    /// Register the API functions with REAPER
    /// All three registrations required for Lua compatibility:
    /// - API_name: C function pointer (for C/C++ extension interop)
    /// - APIdef_name: type metadata ("rettype\0paramtypes\0paramnames\0help")
    /// - APIvararg_name: vararg wrapper (REQUIRED for Lua/EEL scripts!)
    pub fn register(plugin_register: PluginRegisterFn) void {
        // Reamo_ReceivePeakData - receives packed doubles via Lua's string.pack
        _ = plugin_register("API_Reamo_ReceivePeakData", @constCast(@ptrCast(&receivePacked)));
        _ = plugin_register("APIdef_Reamo_ReceivePeakData", @constCast(@ptrCast("int\x00const char*,int\x00data,count\x00Receive packed peak data (use string.pack with 'd' format)")));
        _ = plugin_register("APIvararg_Reamo_ReceivePeakData", @constCast(@ptrCast(&vararg_receivePacked)));

        // Reamo_GetPeakCount - returns number of peaks in buffer
        _ = plugin_register("API_Reamo_GetPeakCount", @constCast(@ptrCast(&getCount)));
        _ = plugin_register("APIdef_Reamo_GetPeakCount", @constCast(@ptrCast("int\x00\x00\x00Get number of peaks in Reamo buffer")));
        _ = plugin_register("APIvararg_Reamo_GetPeakCount", @constCast(@ptrCast(&vararg_getCount)));

        // Reamo_ClearPeakBuffer - clears the buffer
        _ = plugin_register("API_Reamo_ClearPeakBuffer", @constCast(@ptrCast(&clear)));
        _ = plugin_register("APIdef_Reamo_ClearPeakBuffer", @constCast(@ptrCast("void\x00\x00\x00Clear Reamo peak buffer")));
        _ = plugin_register("APIvararg_Reamo_ClearPeakBuffer", @constCast(@ptrCast(&vararg_clear)));

        // Request field getters (individual functions to avoid null-byte issues with packed struct)
        _ = plugin_register("API_Reamo_GetPeakRequestValid", @constCast(@ptrCast(&getRequestValid)));
        _ = plugin_register("APIdef_Reamo_GetPeakRequestValid", @constCast(@ptrCast("int\x00\x00\x00Get peak request valid flag (1=pending, 0=none)")));
        _ = plugin_register("APIvararg_Reamo_GetPeakRequestValid", @constCast(@ptrCast(&vararg_getRequestValid)));

        _ = plugin_register("API_Reamo_GetPeakRequestTrackIdx", @constCast(@ptrCast(&getRequestTrackIdx)));
        _ = plugin_register("APIdef_Reamo_GetPeakRequestTrackIdx", @constCast(@ptrCast("int\x00\x00\x00Get peak request track index")));
        _ = plugin_register("APIvararg_Reamo_GetPeakRequestTrackIdx", @constCast(@ptrCast(&vararg_getRequestTrackIdx)));

        _ = plugin_register("API_Reamo_GetPeakRequestItemIdx", @constCast(@ptrCast(&getRequestItemIdx)));
        _ = plugin_register("APIdef_Reamo_GetPeakRequestItemIdx", @constCast(@ptrCast("int\x00\x00\x00Get peak request item index")));
        _ = plugin_register("APIvararg_Reamo_GetPeakRequestItemIdx", @constCast(@ptrCast(&vararg_getRequestItemIdx)));

        _ = plugin_register("API_Reamo_GetPeakRequestStartTime", @constCast(@ptrCast(&getRequestStartTime)));
        _ = plugin_register("APIdef_Reamo_GetPeakRequestStartTime", @constCast(@ptrCast("double\x00\x00\x00Get peak request start time")));
        _ = plugin_register("APIvararg_Reamo_GetPeakRequestStartTime", @constCast(@ptrCast(&vararg_getRequestStartTime)));

        _ = plugin_register("API_Reamo_GetPeakRequestEndTime", @constCast(@ptrCast(&getRequestEndTime)));
        _ = plugin_register("APIdef_Reamo_GetPeakRequestEndTime", @constCast(@ptrCast("double\x00\x00\x00Get peak request end time")));
        _ = plugin_register("APIvararg_Reamo_GetPeakRequestEndTime", @constCast(@ptrCast(&vararg_getRequestEndTime)));

        _ = plugin_register("API_Reamo_GetPeakRequestPeakrate", @constCast(@ptrCast(&getRequestPeakrate)));
        _ = plugin_register("APIdef_Reamo_GetPeakRequestPeakrate", @constCast(@ptrCast("double\x00\x00\x00Get peak request peakrate")));
        _ = plugin_register("APIvararg_Reamo_GetPeakRequestPeakrate", @constCast(@ptrCast(&vararg_getRequestPeakrate)));

        // Reamo_SetPeakRequestComplete - called by Lua when done
        _ = plugin_register("API_Reamo_SetPeakRequestComplete", @constCast(@ptrCast(&setRequestComplete)));
        _ = plugin_register("APIdef_Reamo_SetPeakRequestComplete", @constCast(@ptrCast("void\x00int\x00count\x00Signal peak request complete (count or error code)")));
        _ = plugin_register("APIvararg_Reamo_SetPeakRequestComplete", @constCast(@ptrCast(&vararg_setRequestComplete)));

        logging.info("LuaPeakBridge: registered 5 API functions with vararg wrappers", .{});
    }

    // =========================================================================
    // Public Interface for peaks_generator
    // =========================================================================

    /// Initialize the Lua script for peak fetching
    /// Called once during extension init. Returns true if script was registered.
    pub fn initScript(api: *const reaper.Api) bool {
        // Build path to the Lua script
        const resource_path = api.resourcePath() orelse {
            logging.err("LuaPeakBridge: failed to get resource path", .{});
            return false;
        };

        var path_buf: [512]u8 = undefined;
        const script_path = std.fmt.bufPrintZ(&path_buf, "{s}/Scripts/Reamo/reamo_internal_fetch_peaks.lua", .{resource_path}) catch {
            logging.err("LuaPeakBridge: script path too long", .{});
            return false;
        };

        // Register script (commit=false for session-only, hidden from Actions menu)
        lua_script_cmd_id = api.registerScript(true, 0, script_path, false);
        if (lua_script_cmd_id == 0) {
            logging.warn("LuaPeakBridge: failed to register Lua script at {s}", .{script_path});
            logging.warn("LuaPeakBridge: waveforms will be disabled (script missing)", .{});
            return false;
        }

        logging.info("LuaPeakBridge: registered Lua script, cmd_id={d}", .{lua_script_cmd_id});
        return true;
    }

    /// Fetch peaks via Lua bridge
    /// Returns slice of peak data, or null on failure
    /// Buffer format: [max0, max1, ..., min0, min1, ...] for each channel interleaved
    pub fn fetchPeaksViaLua(
        api: *const reaper.Api,
        track_idx: i32,
        item_idx: i32,
        start_time: f64,
        end_time: f64,
        peakrate: f64,
        channels: i32,
    ) ?[]const f64 {
        if (lua_script_cmd_id == 0) {
            logging.debug("LuaPeakBridge: no script registered, cannot fetch peaks", .{});
            return null;
        }

        // Clear previous data
        peak_count = 0;
        request_result = 0;

        // Populate the request struct
        pending_request = .{
            .track_idx = track_idx,
            .item_idx = item_idx,
            .start_time = start_time,
            .end_time = end_time,
            .peakrate = peakrate,
            .channels = channels,
            .valid = 1,
        };

        // Execute the Lua script synchronously
        // Main_OnCommand blocks until the script completes
        api.runCommand(lua_script_cmd_id);

        // Check result
        if (request_result <= 0) {
            if (request_result < 0) {
                logging.debug("LuaPeakBridge: Lua returned error {d}", .{request_result});
            }
            return null;
        }

        // Return slice of received peaks
        if (peak_count > 0) {
            return peak_buffer[0..peak_count];
        }
        return null;
    }

    /// Check if Lua bridge is available
    pub fn isAvailable() bool {
        return lua_script_cmd_id != 0;
    }

    /// Adapter function for peaks_generator integration.
    /// Matches peaks_generator.LuaBridgeFetchFn signature.
    pub fn bridgeFetchAdapter(
        track_idx: i32,
        item_idx: i32,
        start_time: f64,
        end_time: f64,
        peakrate: f64,
    ) ?[]const f64 {
        const api = g_api orelse return null;

        // Clear previous data
        peak_count = 0;
        request_result = 0;

        // Populate the request struct
        // Note: channels field is ignored by Lua - it queries the source directly
        pending_request = .{
            .track_idx = track_idx,
            .item_idx = item_idx,
            .start_time = start_time,
            .end_time = end_time,
            .peakrate = peakrate,
            .channels = 0, // Lua will determine this
            .valid = 1,
        };

        // Execute the Lua script synchronously
        logging.info("LuaPeakBridge: calling Lua script cmd_id={d} track={d} item={d} start={d:.2} end={d:.2} peakrate={d:.2}", .{
            lua_script_cmd_id,
            track_idx,
            item_idx,
            start_time,
            end_time,
            peakrate,
        });
        api.runCommand(lua_script_cmd_id);

        // Check result
        if (request_result <= 0) {
            logging.warn("LuaPeakBridge: Lua returned result={d} peak_count={d}", .{ request_result, peak_count });
            return null;
        }

        // Return slice of received peaks
        if (peak_count > 0) {
            return peak_buffer[0..peak_count];
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "LuaPeakBridge.receivePacked handles valid data" {
    // Create test data: 4 doubles packed as little-endian bytes
    const test_values = [_]f64{ 0.5, -0.5, 0.25, -0.25 };
    var packed_data: [32]u8 = undefined; // 4 * 8 bytes

    for (test_values, 0..) |val, i| {
        const bits: u64 = @bitCast(val);
        std.mem.writeInt(u64, packed_data[i * 8 ..][0..8], bits, .little);
    }

    const result = LuaPeakBridge.receivePacked(&packed_data, 4);
    try std.testing.expectEqual(@as(c_int, 4), result);
    try std.testing.expectEqual(@as(usize, 4), LuaPeakBridge.peak_count);

    // Verify values
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), LuaPeakBridge.peak_buffer[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), LuaPeakBridge.peak_buffer[1], 0.0001);
}

test "LuaPeakBridge.receivePacked rejects null data" {
    const result = LuaPeakBridge.receivePacked(null, 10);
    try std.testing.expectEqual(@as(c_int, -1), result);
}

test "LuaPeakBridge.receivePacked rejects zero count" {
    var dummy: [8]u8 = undefined;
    const result = LuaPeakBridge.receivePacked(&dummy, 0);
    try std.testing.expectEqual(@as(c_int, -1), result);
}

test "LuaPeakBridge.clear resets count" {
    LuaPeakBridge.peak_count = 100;
    LuaPeakBridge.clear();
    try std.testing.expectEqual(@as(usize, 0), LuaPeakBridge.peak_count);
}

test "LuaPeakBridge.getCount returns current count" {
    LuaPeakBridge.peak_count = 42;
    try std.testing.expectEqual(@as(c_int, 42), LuaPeakBridge.getCount());
}

test "LuaPeakBridge.isAvailable returns false when no script" {
    LuaPeakBridge.lua_script_cmd_id = 0;
    try std.testing.expect(!LuaPeakBridge.isAvailable());
}

test "LuaPeakBridge.isAvailable returns true when script registered" {
    LuaPeakBridge.lua_script_cmd_id = 12345;
    try std.testing.expect(LuaPeakBridge.isAvailable());
    // Reset for other tests
    LuaPeakBridge.lua_script_cmd_id = 0;
}

test "LuaPeakBridge request field getters" {
    LuaPeakBridge.pending_request = .{
        .track_idx = 5,
        .item_idx = 3,
        .start_time = 10.5,
        .end_time = 20.5,
        .peakrate = 44100.0,
        .channels = 2,
        .valid = 1,
    };

    try std.testing.expectEqual(@as(c_int, 1), LuaPeakBridge.getRequestValid());
    try std.testing.expectEqual(@as(c_int, 5), LuaPeakBridge.getRequestTrackIdx());
    try std.testing.expectEqual(@as(c_int, 3), LuaPeakBridge.getRequestItemIdx());
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), LuaPeakBridge.getRequestStartTime(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 20.5), LuaPeakBridge.getRequestEndTime(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 44100.0), LuaPeakBridge.getRequestPeakrate(), 0.0001);
}

test "LuaPeakBridge.setRequestComplete clears valid flag" {
    LuaPeakBridge.pending_request.valid = 1;
    LuaPeakBridge.setRequestComplete(100);

    try std.testing.expectEqual(@as(c_int, 0), LuaPeakBridge.pending_request.valid);
    try std.testing.expectEqual(@as(c_int, 100), LuaPeakBridge.request_result);
}

test "LuaPeakBridge.bridgeFetchAdapter returns null without g_api" {
    g_api = null;
    const result = LuaPeakBridge.bridgeFetchAdapter(0, 0, 0.0, 1.0, 44100.0);
    try std.testing.expect(result == null);
}
