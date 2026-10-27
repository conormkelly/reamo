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
    const track = guid_cache_ptr.resolve(api, track_guid) orelse {
        logging.debug("trackfx_generator: GUID not found in cache: {s}", .{track_guid});
        return null;
    };

    // Validate track pointer is still valid (track could be deleted while subscription is active)
    if (!api.validateTrackPtr(track)) {
        logging.debug("trackfx_generator: stale track pointer for GUID: {s}", .{track_guid});
        return null;
    }

    const Ctx = struct { api: @TypeOf(api), track: *anyopaque, track_guid: []const u8 };
    // ~300 bytes per FX with names and preset; grows for long chains.
    const estimate = 1024 + @as(usize, @intCast(@max(api.trackFxCount(track), 0))) * 384;
    const ctx = Ctx{ .api = api, .track = track, .track_guid = track_guid };
    return protocol.writeAlloc(allocator, estimate, ctx, writeTrackFxChain) catch |err| {
        logging.warn("trackfx_generator: could not serialize for {s}: {s}", .{ track_guid, @errorName(err) });
        return null;
    };
}

fn writeTrackFxChain(ctx: anytype, w: anytype) !void {
    const api = ctx.api;
    const track = ctx.track;
    const track_guid = ctx.track_guid;

    // Start event envelope
    try w.writeAll("{\"type\":\"event\",\"event\":\"trackFxChain\",\"payload\":{");
    try w.print("\"trackGuid\":\"{s}\",\"fx\":[", .{track_guid});

    // Iterate all FX on the track
    const fx_count = api.trackFxCount(track);
    var i: c_int = 0;
    while (i < fx_count) : (i += 1) {
        if (i > 0) try w.writeByte(',');

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
        try w.writeAll("{\"fxGuid\":\"");
        try protocol.writeJsonString(w, fx_guid);
        try w.print("\",\"fxIndex\":{d},\"name\":\"", .{i});
        try protocol.writeJsonString(w, name);
        try w.writeAll("\",\"presetName\":\"");
        try protocol.writeJsonString(w, preset_info.name);
        try w.print("\",\"presetIndex\":{d},\"presetCount\":{d},\"modified\":{s},\"enabled\":{s}}}", .{
            preset_index,
            preset_count,
            if (!preset_info.matches_preset) "true" else "false",
            if (enabled) "true" else "false",
        });
    }

    try w.writeAll("]}}");

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
