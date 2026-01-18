/// Track FX Parameter Generator - Generates JSON for FX parameter subscription broadcasts.
///
/// Produces "trackFxParams" events containing parameter values for subscribed params
/// of a single FX (identified by track + FX GUID), including param count and name hash
/// for skeleton invalidation.
const std = @import("std");
const logging = @import("logging.zig");
const protocol = @import("protocol.zig");
const guid_cache = @import("guid_cache.zig");
const constants = @import("constants.zig");
const trackfxparam_subscriptions = @import("trackfxparam_subscriptions.zig");
const fx = @import("commands/fx.zig");

const Allocator = std.mem.Allocator;
const Mode = trackfxparam_subscriptions.Mode;
const ClientSubscription = trackfxparam_subscriptions.ClientSubscription;

/// Result of JSON generation.
pub const GenerateResult = struct {
    json: []const u8,
    param_count: c_int,
    name_hash: u64,
};

/// Generate FX parameter values JSON for a subscription.
/// Returns allocated JSON string + metadata from the provided allocator, or null on error.
pub fn generateParamValues(
    allocator: Allocator,
    api: anytype,
    guid_cache_ptr: *guid_cache.GuidCache,
    track_guid: []const u8,
    fx_guid: []const u8,
    client: *const ClientSubscription,
) ?GenerateResult {
    // Resolve GUID to track pointer
    const track = guid_cache_ptr.resolve(track_guid) orelse {
        logging.debug("trackfxparam_generator: Track GUID not found in cache: {s}", .{track_guid});
        return null;
    };

    // Resolve FX by GUID
    const fx_idx = fx.findFxByGuid(api, track, fx_guid) orelse {
        logging.debug("trackfxparam_generator: FX GUID not found on track: {s}", .{fx_guid});
        return null;
    };

    // Get param count
    const param_count = api.trackFxGetNumParams(track, fx_idx);

    // Compute name hash for skeleton invalidation (hash of all param names concatenated)
    var name_hash: u64 = 0;
    {
        var hasher = std.hash.Wyhash.init(0);
        var name_buf: [256]u8 = undefined;
        var i: c_int = 0;
        while (i < param_count) : (i += 1) {
            const name = api.trackFxGetParamName(track, fx_idx, i, &name_buf);
            hasher.update(name);
        }
        name_hash = hasher.final();
    }

    // Allocate buffer for JSON serialization.
    // 32KB supports ~200 params with formatted strings (each entry ~100 bytes)
    const buf = allocator.alloc(u8, 32768) catch return null;
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Start event envelope
    w.writeAll("{\"type\":\"event\",\"event\":\"trackFxParams\",\"payload\":{") catch return null;
    w.print("\"trackGuid\":\"{s}\",\"fxGuid\":\"{s}\",\"paramCount\":{d},\"nameHash\":{d},\"values\":{{", .{
        track_guid,
        fx_guid,
        param_count,
        name_hash,
    }) catch return null;

    // Generate values based on subscription mode
    var first = true;
    var formatted_buf: [256]u8 = undefined;

    switch (client.mode) {
        .range => {
            // Clamp range to actual param count
            const range_start = client.range_start;
            const range_end = @min(client.range_end, param_count - 1);

            if (range_start <= range_end) {
                var i: c_int = range_start;
                while (i <= range_end) : (i += 1) {
                    if (!first) w.writeByte(',') catch return null;
                    first = false;

                    const value = api.trackFxGetParamNormalized(track, fx_idx, i);
                    const formatted = api.trackFxGetFormattedParamValue(track, fx_idx, i, &formatted_buf);

                    // Write: "index": [value, "formatted"]
                    w.print("\"{d}\":[{d:.6},\"", .{ i, value }) catch return null;
                    protocol.writeJsonString(w, formatted) catch return null;
                    w.writeAll("\"]") catch return null;
                }
            }
        },
        .indices => {
            for (client.indices[0..client.indices_count]) |param_idx| {
                // Skip out-of-bounds indices
                if (param_idx >= param_count) continue;

                if (!first) w.writeByte(',') catch return null;
                first = false;

                const value = api.trackFxGetParamNormalized(track, fx_idx, param_idx);
                const formatted = api.trackFxGetFormattedParamValue(track, fx_idx, param_idx, &formatted_buf);

                // Write: "index": [value, "formatted"]
                w.print("\"{d}\":[{d:.6},\"", .{ param_idx, value }) catch return null;
                protocol.writeJsonString(w, formatted) catch return null;
                w.writeAll("\"]") catch return null;
            }
        },
    }

    w.writeAll("}}}") catch return null;

    return GenerateResult{
        .json = stream.getWritten(),
        .param_count = param_count,
        .name_hash = name_hash,
    };
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
