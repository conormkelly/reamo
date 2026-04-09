/// Track FX Generator - Generates JSON for FX chain subscription broadcasts.
///
/// Produces "trackFxChain" events containing all FX for a single track
/// (identified by GUID), including preset info and enabled state.
const std = @import("std");
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
const guid_cache = @import("../state/guid_cache.zig");
const constants = @import("../core/constants.zig");

const Allocator = std.mem.Allocator;
const MAX_FX_NAME_LEN = constants.MAX_FX_NAME_LEN;

/// Generate FX chain JSON for a subscribed track.
/// Returns allocated JSON string from the provided allocator, or null on error.
pub fn generateTrackFxChain(
    allocator: Allocator,
    api: anytype,
    guid_cache_ptr: *guid_cache.GuidCache,
    track_guid: []const u8,
) ?[]const u8 {
    // Resolve GUID to track pointer
    const track = guid_cache_ptr.resolve(track_guid) orelse {
        logging.debug("trackfx_generator: GUID not found in cache: {s}", .{track_guid});
        return null;
    };

    // Validate track pointer is still valid (track could be deleted while subscription is active)
    if (!api.validateTrackPtr(track)) {
        logging.debug("trackfx_generator: stale track pointer for GUID: {s}", .{track_guid});
        return null;
    }

    // Allocate buffer for JSON serialization.
    // 16KB supports ~50 FX per track (each entry ~300 bytes with names).
    const buf = allocator.alloc(u8, 16384) catch return null;
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Start event envelope
    w.writeAll("{\"type\":\"event\",\"event\":\"trackFxChain\",\"payload\":{") catch return null;
    w.print("\"trackGuid\":\"{s}\",\"fx\":[", .{track_guid}) catch return null;

    // Iterate all FX on the track
    const fx_count = api.trackFxCount(track);
    var i: c_int = 0;
    while (i < fx_count) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return null;

        // Get FX name
        var name_buf: [MAX_FX_NAME_LEN]u8 = undefined;
        const name = api.trackFxGetName(track, i, &name_buf);

        // Get FX GUID
        var guid_buf: [64]u8 = undefined;
        const fx_guid = api.trackFxGetGuid(track, i, &guid_buf);

        // Get preset info
        var preset_count: c_int = 0;
        const preset_index = api.trackFxGetPresetIndex(track, i, &preset_count);

        var preset_name_buf: [MAX_FX_NAME_LEN]u8 = undefined;
        const preset_info = api.trackFxGetPreset(track, i, &preset_name_buf);

        // Get enabled state
        const enabled = api.trackFxGetEnabled(track, i);

        // Write FX object
        w.writeAll("{\"fxGuid\":\"") catch return null;
        protocol.writeJsonString(w, fx_guid) catch return null;
        w.print("\",\"fxIndex\":{d},\"name\":\"", .{i}) catch return null;
        protocol.writeJsonString(w, name) catch return null;
        w.writeAll("\",\"presetName\":\"") catch return null;
        protocol.writeJsonString(w, preset_info.name) catch return null;
        w.print("\",\"presetIndex\":{d},\"presetCount\":{d},\"modified\":{s},\"enabled\":{s}}}", .{
            preset_index,
            preset_count,
            if (!preset_info.matches_preset) "true" else "false",
            if (enabled) "true" else "false",
        }) catch return null;
    }

    w.writeAll("]}}") catch return null;

    return stream.getWritten();
}

/// Compute hash of FX chain state for change detection.
pub fn hashTrackFxChain(json: []const u8) u64 {
    return std.hash.Wyhash.hash(0, json);
}

// =============================================================================
// Tests
// =============================================================================

test "hashTrackFxChain produces consistent results" {
    const json = "{\"type\":\"event\",\"event\":\"trackFxChain\",\"payload\":{}}";
    const h1 = hashTrackFxChain(json);
    const h2 = hashTrackFxChain(json);
    try std.testing.expectEqual(h1, h2);
}

test "hashTrackFxChain produces different results for different content" {
    const json1 = "{\"fx\":[]}";
    const json2 = "{\"fx\":[{\"name\":\"EQ\"}]}";
    const h1 = hashTrackFxChain(json1);
    const h2 = hashTrackFxChain(json2);
    try std.testing.expect(h1 != h2);
}
