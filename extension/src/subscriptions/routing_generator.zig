/// Routing Generator - Generates JSON for routing subscription broadcasts.
///
/// Produces "routing_state" events containing sends, receives, and hw outputs
/// for a single track (identified by GUID).
const std = @import("std");
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
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
    const track = guid_cache_ptr.resolve(track_guid) orelse {
        logging.debug("routing_generator: GUID not found in cache: {s}", .{track_guid});
        return null;
    };

    // Allocate buffer for JSON serialization.
    // 8KB supports ~40 sends + ~40 hw outputs per track (each entry ~100 bytes).
    // This is sufficient for real-world use - most tracks have <10 sends.
    // If a track exceeds this, the write will fail gracefully (return null).
    const buf = allocator.alloc(u8, 8192) catch return null;
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Start event envelope
    w.writeAll("{\"type\":\"event\",\"event\":\"routing_state\",\"payload\":{") catch return null;
    w.print("\"trackGuid\":\"{s}\",", .{track_guid}) catch return null;

    // Write sends array (category 0)
    w.writeAll("\"sends\":[") catch return null;
    const send_count = api.trackSendCount(track);
    var i: c_int = 0;
    while (i < send_count) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return null;

        var dest_name_buf: [MAX_NAME_LEN]u8 = undefined;
        const dest_name = api.trackSendGetDestName(track, i, &dest_name_buf);
        const volume = api.trackSendGetVolume(track, i);
        const pan = api.trackSendGetPan(track, i);
        const muted = api.trackSendGetMute(track, i);
        const mode = api.trackSendGetMode(track, i) catch 0;

        w.print("{{\"sendIndex\":{d},\"destName\":\"", .{i}) catch return null;
        protocol.writeJsonString(w, dest_name) catch return null;
        w.print("\",\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            volume,
            pan,
            if (muted) "true" else "false",
            mode,
        }) catch return null;
    }
    w.writeAll("],") catch return null;

    // Write receives array (category -1)
    w.writeAll("\"receives\":[") catch return null;
    const receive_count = api.trackReceiveCount(track);
    i = 0;
    while (i < receive_count) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return null;

        var src_name_buf: [MAX_NAME_LEN]u8 = undefined;
        const src_name = api.trackReceiveGetSrcName(track, i, &src_name_buf);
        const recv_volume = api.trackReceiveGetVolume(track, i);
        const recv_pan = api.trackReceiveGetPan(track, i);
        const recv_muted = api.trackReceiveGetMute(track, i);
        const recv_mode = api.trackReceiveGetMode(track, i) catch 0;

        w.print("{{\"receiveIndex\":{d},\"srcName\":\"", .{i}) catch return null;
        protocol.writeJsonString(w, src_name) catch return null;
        w.print("\",\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            recv_volume,
            recv_pan,
            if (recv_muted) "true" else "false",
            recv_mode,
        }) catch return null;
    }
    w.writeAll("],") catch return null;

    // Write hwOutputs array (category 1)
    w.writeAll("\"hwOutputs\":[") catch return null;
    const hw_count = api.trackHwOutputCount(track);
    i = 0;
    while (i < hw_count) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return null;

        const volume = api.trackHwOutputGetVolume(track, i);
        const pan = api.trackHwOutputGetPan(track, i);
        const muted = api.trackHwOutputGetMute(track, i);
        const mode = api.trackHwOutputGetMode(track, i) catch 0;
        const dest_chan = api.trackHwOutputGetDestChannel(track, i) catch 0;

        w.print("{{\"hwIdx\":{d},\"destChannel\":{d},\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            i,
            dest_chan,
            volume,
            pan,
            if (muted) "true" else "false",
            mode,
        }) catch return null;
    }
    w.writeAll("]}}") catch return null;

    return stream.getWritten();
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
