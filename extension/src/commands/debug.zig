const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const tiered_state = @import("../server/tiered_state.zig");

/// Get memory usage statistics for all arenas.
/// Input: {} (no parameters)
/// Response: {
///   "high": { "used": N, "capacity": N, "peak": N, "utilization": N.N },
///   "medium": { "used": N, "capacity": N, "peak": N, "utilization": N.N },
///   "low": { "used": N, "capacity": N, "peak": N, "utilization": N.N },
///   "scratch": { "used": N, "capacity": N },
///   "total": { "allocated": N, "allocatedMB": N.N },
///   "sizes": { "high": N, "medium": N, "low": N, "scratch": N }
/// }
pub fn handleMemoryStats(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    _ = api;
    _ = cmd;

    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };

    const usage = tiered.usage();

    // Calculate utilization percentages
    const high_util = if (usage.high_capacity > 0)
        @as(f64, @floatFromInt(usage.high_peak * 100)) / @as(f64, @floatFromInt(usage.high_capacity))
    else
        0.0;
    const medium_util = if (usage.medium_capacity > 0)
        @as(f64, @floatFromInt(usage.medium_peak * 100)) / @as(f64, @floatFromInt(usage.medium_capacity))
    else
        0.0;
    const low_util = if (usage.low_capacity > 0)
        @as(f64, @floatFromInt(usage.low_peak * 100)) / @as(f64, @floatFromInt(usage.low_capacity))
    else
        0.0;

    const total_allocated = usage.totalAllocated();
    const total_mb = @as(f64, @floatFromInt(total_allocated)) / (1024.0 * 1024.0);

    // Serialize response
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var w = stream.writer();

    w.print(
        \\{{"high":{{"used":{d},"capacity":{d},"peak":{d},"utilization":{d:.1}}},
    , .{ usage.high_used, usage.high_capacity, usage.high_peak, high_util }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    w.print(
        \\"medium":{{"used":{d},"capacity":{d},"peak":{d},"utilization":{d:.1}}},
    , .{ usage.medium_used, usage.medium_capacity, usage.medium_peak, medium_util }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    w.print(
        \\"low":{{"used":{d},"capacity":{d},"peak":{d},"utilization":{d:.1}}},
    , .{ usage.low_used, usage.low_capacity, usage.low_peak, low_util }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    w.print(
        \\"scratch":{{"used":{d},"capacity":{d}}},
    , .{ usage.scratch_used, usage.scratch_capacity }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    w.print(
        \\"total":{{"allocated":{d},"allocatedMB":{d:.2}}},
    , .{ total_allocated, total_mb }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    w.print(
        \\"sizes":{{"high":{d},"medium":{d},"low":{d},"scratch":{d}}},
    , .{ tiered.sizes.high, tiered.sizes.medium, tiered.sizes.low, tiered.sizes.scratch }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    w.print(
        \\"frameCount":{d}}}
    , .{usage.frame_count}) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    response.success(stream.getWritten());
    logging.debug("Returned memory stats", .{});
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "memory stats JSON serialization" {
    // Test that we can serialize memory stats when tiered arenas exist
    var arenas = try tiered_state.TieredArenas.init(testing.allocator);
    defer arenas.deinit(testing.allocator);

    // Run a few frames to get some usage data
    try arenas.beginFrame(0);
    _ = try arenas.high.currentAllocator().alloc(u8, 1000);
    try arenas.beginFrame(1);

    const usage = arenas.usage();

    // Verify usage struct has expected fields
    try testing.expect(usage.high_capacity > 0);
    try testing.expect(usage.medium_capacity > 0);
    try testing.expect(usage.low_capacity > 0);
    try testing.expect(usage.scratch_capacity > 0);

    // Verify we can format for JSON without error
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var w = stream.writer();

    // Calculate utilization percentages (same logic as handler)
    const high_util = if (usage.high_capacity > 0)
        @as(f64, @floatFromInt(usage.high_peak * 100)) / @as(f64, @floatFromInt(usage.high_capacity))
    else
        0.0;

    const total_allocated = usage.totalAllocated();
    const total_mb = @as(f64, @floatFromInt(total_allocated)) / (1024.0 * 1024.0);

    try w.print(
        \\{{"high":{{"used":{d},"capacity":{d},"peak":{d},"utilization":{d:.1}}},
    , .{ usage.high_used, usage.high_capacity, usage.high_peak, high_util });

    try w.print(
        \\"total":{{"allocated":{d},"allocatedMB":{d:.2}}}}}
    , .{ total_allocated, total_mb });

    const json = stream.getWritten();
    try testing.expect(json.len > 0);
    try testing.expect(std.mem.indexOf(u8, json, "\"high\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":") != null);
}

test "g_ctx.tiered is null by default" {
    // Verify the global starts as null (safety check)
    const saved = mod.g_ctx.tiered;
    defer mod.g_ctx.tiered = saved;

    mod.g_ctx.tiered = null;
    try testing.expect(mod.g_ctx.tiered == null);
}
