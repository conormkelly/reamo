/// Routing Generator - Generates JSON for routing subscription broadcasts.
///
/// Produces "routing_state" events containing sends, receives, and hw outputs
/// for a single track (identified by GUID).
const std = @import("std");
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
const ffi = @import("../core/ffi.zig");
const guid_cache = @import("../state/guid_cache.zig");

const Allocator = std.mem.Allocator;
const MAX_NAME_LEN = 256;

/// Generate routing state JSON for a subscribed track.
/// Returns allocated JSON string from the provided allocator, or null on error.
pub fn generateRoutingState(
    allocator: Allocator,
    api: anytype,
    guid_cache_ptr: *guid_cache.GuidCache,
    track_guid: []const u8,
) ?[]const u8 {
    // Resolve GUID to track pointer
    const track = guid_cache_ptr.resolve(api, track_guid) orelse {
        logging.debug("routing_generator: GUID not found in cache: {s}", .{track_guid});
        return null;
    };

    // Validate track pointer is still valid (track could be deleted while subscription is active)
    if (!api.validateTrackPtr(track)) {
        logging.debug("routing_generator: stale track pointer for GUID: {s}", .{track_guid});
        return null;
    }

    const Ctx = struct { api: @TypeOf(api), track: *anyopaque, guid: []const u8 };
    // ~100 bytes per send, receive or hardware output; grows for buses with
    // dozens of receives (an orchestral template's reverb).
    return protocol.writeAlloc(allocator, 8192, Ctx{ .api = api, .track = track, .guid = track_guid }, writeRoutingState) catch |err| {
        logging.warn("routing_generator: could not serialize routing for {s}: {s}", .{ track_guid, @errorName(err) });
        return null;
    };
}

fn writeRoutingState(ctx: anytype, w: anytype) !void {
    const api = ctx.api;
    const track = ctx.track;
    const track_guid = ctx.guid;

    // Start event envelope
    try w.writeAll("{\"type\":\"event\",\"event\":\"routing_state\",\"payload\":{");
    try w.print("\"trackGuid\":\"{s}\",", .{track_guid});

    // Write sends array (category 0)
    try w.writeAll("\"sends\":[");
    const send_count = api.trackSendCount(track);
    var i: c_int = 0;
    while (i < send_count) : (i += 1) {
        if (i > 0) try w.writeByte(',');

        var dest_name_buf: [MAX_NAME_LEN]u8 = undefined;
        const dest_name = api.trackSendGetDestName(track, i, &dest_name_buf);
        const volume = api.trackSendGetVolume(track, i);
        const pan = api.trackSendGetPan(track, i);
        const muted = api.trackSendGetMute(track, i);
        const mode = api.trackSendGetMode(track, i) catch 0;

        // Guard against NaN/Inf from stale pointers or corrupt project state
        const safe_volume = if (ffi.isFinite(volume)) volume else 0.0;
        const safe_pan = if (ffi.isFinite(pan)) pan else 0.0;

        try w.print("{{\"sendIndex\":{d},\"destName\":\"", .{i});
        try protocol.writeJsonString(w, dest_name);
        try w.print("\",\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            safe_volume,
            safe_pan,
            if (muted) "true" else "false",
            mode,
        });
    }
    try w.writeAll("],");

    // Write receives array (category -1)
    try w.writeAll("\"receives\":[");
    const receive_count = api.trackReceiveCount(track);
    i = 0;
    while (i < receive_count) : (i += 1) {
        if (i > 0) try w.writeByte(',');

        var src_name_buf: [MAX_NAME_LEN]u8 = undefined;
        const src_name = api.trackReceiveGetSrcName(track, i, &src_name_buf);
        const recv_volume = api.trackReceiveGetVolume(track, i);
        const recv_pan = api.trackReceiveGetPan(track, i);
        const recv_muted = api.trackReceiveGetMute(track, i);
        const recv_mode = api.trackReceiveGetMode(track, i) catch 0;

        const safe_recv_volume = if (ffi.isFinite(recv_volume)) recv_volume else 0.0;
        const safe_recv_pan = if (ffi.isFinite(recv_pan)) recv_pan else 0.0;

        try w.print("{{\"receiveIndex\":{d},\"srcName\":\"", .{i});
        try protocol.writeJsonString(w, src_name);
        try w.print("\",\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            safe_recv_volume,
            safe_recv_pan,
            if (recv_muted) "true" else "false",
            recv_mode,
        });
    }
    try w.writeAll("],");

    // Write hwOutputs array (category 1)
    try w.writeAll("\"hwOutputs\":[");
    const hw_count = api.trackHwOutputCount(track);
    i = 0;
    while (i < hw_count) : (i += 1) {
        if (i > 0) try w.writeByte(',');

        const volume = api.trackHwOutputGetVolume(track, i);
        const pan = api.trackHwOutputGetPan(track, i);
        const muted = api.trackHwOutputGetMute(track, i);
        const mode = api.trackHwOutputGetMode(track, i) catch 0;
        const dest_chan = api.trackHwOutputGetDestChannel(track, i) catch 0;

        const safe_hw_volume = if (ffi.isFinite(volume)) volume else 0.0;
        const safe_hw_pan = if (ffi.isFinite(pan)) pan else 0.0;

        try w.print("{{\"hwIdx\":{d},\"destChannel\":{d},\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            i,
            dest_chan,
            safe_hw_volume,
            safe_hw_pan,
            if (muted) "true" else "false",
            mode,
        });
    }
    try w.writeAll("]}}");

}

/// Compute hash of routing state for change detection.
pub fn hashRoutingState(json: []const u8) u64 {
    return std.hash.Wyhash.hash(0, json);
}

// Tests
test "hashRoutingState produces consistent results" {
    const json = "{\"type\":\"event\",\"event\":\"routing_state\",\"payload\":{}}";
    const h1 = hashRoutingState(json);
    const h2 = hashRoutingState(json);
    try std.testing.expectEqual(h1, h2);
}
