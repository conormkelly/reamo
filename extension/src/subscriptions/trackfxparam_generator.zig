/// Track FX Parameter Generator - Generates JSON for FX parameter subscription broadcasts.
///
/// Produces "trackFxParams" events containing parameter values for subscribed params
/// of a single FX (identified by track + FX GUID), including param count and name hash
/// for skeleton invalidation.
const std = @import("std");
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
const ffi = @import("../core/ffi.zig");
const guid_cache = @import("../state/guid_cache.zig");
const constants = @import("../core/constants.zig");
const trackfxparam_subscriptions = @import("trackfxparam_subscriptions.zig");
const fx = @import("../commands/fx.zig");

const Allocator = std.mem.Allocator;
const Mode = trackfxparam_subscriptions.Mode;
const ClientSubscription = trackfxparam_subscriptions.ClientSubscription;

/// Result of JSON generation.
pub const GenerateResult = struct {
    json: []const u8,
    param_count: c_int,
    name_hash: u64,
};

/// Why no values could be generated: the track or FX is gone (the
/// subscription is dropped after a few of these), or the message couldn't
/// be built this tick (it is retried on the next).
pub const GenerateError = error{ NotFound, OutOfMemory };

/// Generate FX parameter values JSON for a subscription, allocated from
/// `allocator`, with the metadata for skeleton invalidation.
pub fn generateParamValues(
    allocator: Allocator,
    api: anytype,
    guid_cache_ptr: *guid_cache.GuidCache,
    track_guid: []const u8,
    fx_guid: []const u8,
    client: *const ClientSubscription,
) GenerateError!GenerateResult {
    // Resolve GUID to track pointer
    const track = guid_cache_ptr.resolve(api, track_guid) orelse {
        logging.debug("trackfxparam_generator: Track GUID not found in cache: {s}", .{track_guid});
        return error.NotFound;
    };

    // Validate track pointer is still valid (track could be deleted while subscription is active)
    if (!api.validateTrackPtr(track)) {
        logging.debug("trackfxparam_generator: stale track pointer for GUID: {s}", .{track_guid});
        return error.NotFound;
    }

    // Resolve FX by GUID
    const fx_idx = fx.findFxByGuid(api, track, fx_guid) orelse {
        logging.debug("trackfxparam_generator: FX GUID not found on track: {s}", .{fx_guid});
        return error.NotFound;
    };

    // Read the parameter count every poll: it can change at runtime (VST2
    // Cockos extension, VST3 restartComponent) and no CSurf callback reports
    // it. GetNumParams is cheap enough to call every frame, and an
    // out-of-range parameter index returns 0.0/false rather than crashing.
    // paramCount and nameHash in every event let the client refetch its
    // skeleton when either changes. FX inside containers aren't reachable:
    // native containers need 0x2000000 addressing, third-party ones are opaque.
    const param_count = api.trackFxGetNumParams(track, fx_idx);
    if (param_count <= 0) {
        return .{
            .json = "",
            .param_count = param_count,
            .name_hash = 0,
        };
    }

    // The same hash trackFx/getParams returns, so a client's cached skeleton
    // matches the events while the names are unchanged.
    var hasher = fx.ParamNameHasher{};
    {
        var name_buf: [fx.ParamNameHasher.name_buf_len]u8 = undefined;
        var i: c_int = 0;
        while (i < param_count) : (i += 1) {
            hasher.update(api.trackFxGetParamName(track, fx_idx, i, &name_buf));
        }
    }
    const name_hash = hasher.final();

    // A big synth's parameters with long labels run well past any fixed
    // buffer; the message grows to fit (~100 bytes per parameter).
    const ctx = WriteContext(@TypeOf(api)){
        .api = api,
        .track = track,
        .fx_idx = fx_idx,
        .track_guid = track_guid,
        .fx_guid = fx_guid,
        .client = client,
        .param_count = param_count,
        .name_hash = name_hash,
    };
    const estimate = 512 + @as(usize, @intCast(param_count)) * 128;
    const json = protocol.writeAlloc(allocator, estimate, ctx, writeParamValues) catch |err| {
        logging.warn("trackfxparam_generator: could not build {d} parameter values: {s}", .{ param_count, @errorName(err) });
        return error.OutOfMemory;
    };

    return GenerateResult{
        .json = json,
        .param_count = param_count,
        .name_hash = name_hash,
    };
}

fn WriteContext(comptime Api: type) type {
    return struct {
        api: Api,
        track: *anyopaque,
        fx_idx: c_int,
        track_guid: []const u8,
        fx_guid: []const u8,
        client: *const ClientSubscription,
        param_count: c_int,
        name_hash: u64,
    };
}

fn writeParamValues(ctx: anytype, w: anytype) !void {
    const api = ctx.api;
    const track = ctx.track;
    const fx_idx = ctx.fx_idx;
    const param_count = ctx.param_count;

    // Start event envelope
    try w.writeAll("{\"type\":\"event\",\"event\":\"trackFxParams\",\"payload\":{");
    try w.print("\"trackGuid\":\"{s}\",\"fxGuid\":\"{s}\",\"paramCount\":{d},\"nameHash\":{d},\"values\":{{", .{
        ctx.track_guid,
        ctx.fx_guid,
        param_count,
        ctx.name_hash,
    });

    // Generate values based on subscription mode
    var first = true;
    var formatted_buf: [256]u8 = undefined;

    switch (ctx.client.mode) {
        .range => {
            // Clamp range to actual param count (param_count > 0 guaranteed by the caller)
            const range_start = ctx.client.range_start;
            const range_end = @min(ctx.client.range_end, param_count - 1);

            if (range_start <= range_end) {
                var i: c_int = range_start;
                while (i <= range_end) : (i += 1) {
                    const value = api.trackFxGetParamNormalized(track, fx_idx, i);
                    if (!ffi.isFinite(value)) continue;
                    const formatted = api.trackFxGetFormattedParamValue(track, fx_idx, i, &formatted_buf);

                    if (!first) try w.writeByte(',');
                    first = false;

                    // Write: "index": [value, "formatted"]
                    try w.print("\"{d}\":[{d:.6},\"", .{ i, value });
                    try protocol.writeJsonString(w, formatted);
                    try w.writeAll("\"]");
                }
            }
        },
        .indices => {
            for (ctx.client.indices[0..ctx.client.indices_count]) |param_idx| {
                // Skip out-of-bounds indices
                if (param_idx >= param_count) continue;

                const value = api.trackFxGetParamNormalized(track, fx_idx, param_idx);
                if (!ffi.isFinite(value)) continue;
                const formatted = api.trackFxGetFormattedParamValue(track, fx_idx, param_idx, &formatted_buf);

                if (!first) try w.writeByte(',');
                first = false;

                // Write: "index": [value, "formatted"]
                try w.print("\"{d}\":[{d:.6},\"", .{ param_idx, value });
                try protocol.writeJsonString(w, formatted);
                try w.writeAll("\"]");
            }
        },
    }

    try w.writeAll("}}}");
}

/// Compute hash of param values for change detection.
pub fn hashParamValues(json: []const u8) u64 {
    return std.hash.Wyhash.hash(0, json);
}

// =============================================================================
// Tests
// =============================================================================

test "hashParamValues produces consistent results" {
    const json = "{\"type\":\"event\",\"event\":\"trackFxParams\",\"payload\":{}}";
    const h1 = hashParamValues(json);
    const h2 = hashParamValues(json);
    try std.testing.expectEqual(h1, h2);
}

test "hashParamValues produces different results for different content" {
    const json1 = "{\"values\":{}}";
    const json2 = "{\"values\":{\"0\":[0.5,\"50%\"]}}";
    const h1 = hashParamValues(json1);
    const h2 = hashParamValues(json2);
    try std.testing.expect(h1 != h2);
}
