/// Peaks subscription command handlers.
///
/// Commands:
/// - peaks/subscribe: Subscribe to peaks for tracks (by range or GUID list)
/// - peaks/unsubscribe: Clear peaks subscription for this client
/// - peaks/updateViewport: Update viewport for adaptive peak resolution
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const peaks_subscriptions = @import("../subscriptions/peaks_subscriptions.zig");
const logging = @import("../core/logging.zig");

const ViewportParams = peaks_subscriptions.PeaksSubscriptions.ViewportParams;

/// Parse optional viewport from command: {"viewport": {"start": 0.0, "end": 30.0, "widthPx": 400}}
/// Null, with no error of its own, for a viewport that isn't complete and
/// valid. The phone can send a fractional widthPx (a measured CSS width), so
/// peaks/subscribe then falls back to sampleCount and peaks/updateViewport
/// answers INVALID_PARAMS.
fn parseViewport(raw: []const u8) ?ViewportParams {
    const start = protocol.jsonGetFloatFromObject(raw, "viewport", "start") orelse return null;
    const end = protocol.jsonGetFloatFromObject(raw, "viewport", "end") orelse return null;
    const width_px = protocol.jsonGetIntFromObject(raw, "viewport", "widthPx") orelse return null;
    if (width_px <= 0) return null;
    // jsonGetFloat parses e.g. 1e999 as inf.
    if (!std.math.isFinite(start) or !std.math.isFinite(end)) return null;
    return ViewportParams{
        .start = start,
        .end = end,
        .width_px = @intCast(width_px),
    };
}

/// Subscribe to peaks updates. Supports two mutually exclusive modes:
///
/// Range mode - subscribe to unified indices [start, end]:
/// { "command": "peaks/subscribe", "range": {"start": 0, "end": 7}, "sampleCount": 30, "id": "1" }
///
/// GUID mode - subscribe to specific tracks by GUID:
/// { "command": "peaks/subscribe", "guids": ["{AAA...}", "{BBB...}"], "sampleCount": 30, "id": "2" }
///
/// With viewport for adaptive resolution:
/// { "command": "peaks/subscribe", "range": {...}, "viewport": {"start": 0.0, "end": 30.0, "widthPx": 400} }
///
/// Parameters:
/// - range: Object with start/end unified indices (mutually exclusive with guids)
/// - guids: Array of track GUIDs (mutually exclusive with range)
/// - sampleCount: Number of peak samples per item (optional, default 30, used as fallback)
/// - viewport: Object with start/end (seconds) and widthPx for adaptive peak resolution
///
/// Response:
/// { "type": "response", "id": "1", "success": true, "payload": {"subscribedCount": 8} }
///
/// After subscribing, the client receives "peaks" events with data for all items
/// on the subscribed tracks.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.peaks_subs orelse {
        response.err("NOT_INITIALIZED", "Peaks subscriptions not initialized");
        return;
    };

    // Parse sampleCount (optional, default 30, used as fallback when viewport not provided)
    const sample_count_param = cmd.getIntStrict("sampleCount") catch
        return response.err("INVALID_PARAMS", "sampleCount must be an integer");
    const sample_count: u32 = if (sample_count_param) |sc|
        if (sc > 0 and sc <= 200) @intCast(sc) else 30
    else
        30;

    // Parse optional viewport for adaptive resolution
    const viewport = parseViewport(cmd.raw);
    if (viewport) |vp| {
        logging.debug("peaks_subs: parsed viewport start={d:.2}, end={d:.2}, width={d}", .{ vp.start, vp.end, vp.width_px });
    } else {
        logging.debug("peaks_subs: no viewport parsed from command", .{});
    }

    // Try range mode first
    const range = mod.getIndexRange(cmd) catch
        return response.err("INVALID_PARAMS", "range must be an object of integer start and end");

    if (range) |r| {
        // Range mode with optional viewport
        const count = subs.subscribeRangeWithViewport(response.client_id, r.start, r.end, sample_count, viewport) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            }
            return;
        };

        var payload_buf: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedCount\":{d}}}", .{count}) catch {
            response.err("JSON_ERROR", "Failed to format response");
            return;
        };
        response.success(payload);
        return;
    }

    // Try GUID mode
    var guid_bufs: [peaks_subscriptions.MAX_GUIDS_PER_CLIENT][peaks_subscriptions.GUID_LEN]u8 = undefined;
    var guid_lens: [peaks_subscriptions.MAX_GUIDS_PER_CLIENT]usize = undefined;

    const guid_count = protocol.jsonGetStringArray(
        cmd.raw,
        "guids",
        peaks_subscriptions.MAX_GUIDS_PER_CLIENT,
        peaks_subscriptions.GUID_LEN,
        &guid_bufs,
        &guid_lens,
    ) catch |err| return mod.answerGuidListError(response, "guids", peaks_subscriptions.MAX_GUIDS_PER_CLIENT, err);

    if (guid_count) |count| {
        // Build slice array for subscribeGuids
        var guid_slices: [peaks_subscriptions.MAX_GUIDS_PER_CLIENT][]const u8 = undefined;
        for (0..count) |i| {
            guid_slices[i] = guid_bufs[i][0..guid_lens[i]];
        }

        const subscribed = subs.subscribeGuidsWithViewport(response.client_id, guid_slices[0..count], sample_count, viewport) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            }
            return;
        };

        var payload_buf: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedCount\":{d}}}", .{subscribed}) catch {
            response.err("JSON_ERROR", "Failed to format response");
            return;
        };
        response.success(payload);
        return;
    }

    // Neither mode specified
    response.err("INVALID_PARAMS", "Either range or guids parameter is required");
}

/// Unsubscribe from peaks updates.
///
/// Command format:
/// { "command": "peaks/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.peaks_subs orelse {
        response.err("NOT_INITIALIZED", "Peaks subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

/// Update viewport for adaptive peak resolution without changing track subscription.
/// Use this when panning/zooming to request peaks at appropriate resolution.
///
/// Command format:
/// { "command": "peaks/updateViewport", "viewport": {"start": 0.0, "end": 30.0, "widthPx": 400}, "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// Note: Requires an active subscription. Returns error if not subscribed.
pub fn handleUpdateViewport(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.peaks_subs orelse {
        response.err("NOT_INITIALIZED", "Peaks subscriptions not initialized");
        return;
    };

    const viewport = parseViewport(cmd.raw) orelse {
        response.err("INVALID_PARAMS", "viewport parameter required with start, end, and widthPx");
        return;
    };

    logging.debug("peaks_subs: updateViewport received start={d:.2}, end={d:.2}, width={d}", .{ viewport.start, viewport.end, viewport.width_px });

    if (!subs.updateViewport(response.client_id, viewport)) {
        response.err("NOT_SUBSCRIBED", "No active peaks subscription");
        return;
    }

    response.success(null);
}

// Tests

const TestStore = struct {
    subs: peaks_subscriptions.PeaksSubscriptions,
    reply: mod.TestReply = .{},

    fn init() TestStore {
        return .{ .subs = peaks_subscriptions.PeaksSubscriptions.init(std.testing.allocator) };
    }

    fn deinit(self: *TestStore) void {
        self.reply.deinit();
        self.subs.deinit();
    }

    fn client(self: *TestStore) ?*peaks_subscriptions.ClientSubscription {
        const slot = self.subs.client_id_to_slot.get(1) orelse return null;
        return &self.subs.clients[slot];
    }

    fn run(self: *TestStore, json: []const u8) void {
        const saved = mod.g_ctx.peaks_subs;
        mod.g_ctx.peaks_subs = &self.subs;
        defer mod.g_ctx.peaks_subs = saved;
        const mock = @import("../reaper/mock/mod.zig");
        var m = mock.MockBackend{};
        mod.testRunHandlerReply(&m, handleSubscribe, json, &self.reply);
    }

    fn expectSubscribed(self: *TestStore, json: []const u8) !*peaks_subscriptions.ClientSubscription {
        self.run(json);
        if (!self.reply.succeeded()) {
            std.debug.print("expected success for {s}, got {s}\n", .{ json, self.reply.json() });
            return error.TestUnexpectedResult;
        }
        return self.client() orelse error.TestUnexpectedResult;
    }

    /// Run peaks/subscribe and require INVALID_PARAMS, leaving client 1's
    /// subscription as it was.
    fn expectInvalid(self: *TestStore, json: []const u8) !void {
        const before = if (self.client()) |c| c.* else null;
        self.run(json);
        std.testing.expectEqualStrings("INVALID_PARAMS", self.reply.errorCode() orelse "(no error)") catch |e| {
            std.debug.print("reply to {s}:\n  {s}\n", .{ json, self.reply.json() });
            return e;
        };
        const after = if (self.client()) |c| c.* else null;
        try std.testing.expectEqual(before == null, after == null);
        if (before) |b| {
            try std.testing.expectEqual(b.mode, after.?.mode);
            try std.testing.expectEqual(b.range_start, after.?.range_start);
            try std.testing.expectEqual(b.guid_count, after.?.guid_count);
            try std.testing.expectEqual(b.sample_count, after.?.sample_count);
        }
    }
};

fn peaksCommand(comptime fields: []const u8) []const u8 {
    return "{\"type\":\"command\",\"command\":\"peaks/subscribe\"," ++ fields ++ "}";
}

/// A peaks/subscribe command listing `count` distinct GUIDs.
fn guidsCommand(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"command\",\"command\":\"peaks/subscribe\",\"guids\":[");
    for (0..count) |i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(allocator, "\"{{00000000-0000-0000-0000-{d:0>12}}}\"", .{i});
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

test "peaks/subscribe accepts exactly 64 guids" {
    var store = TestStore.init();
    defer store.deinit();
    const json = try guidsCommand(std.testing.allocator, peaks_subscriptions.MAX_GUIDS_PER_CLIENT);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqual(peaks_subscriptions.MAX_GUIDS_PER_CLIENT, (try store.expectSubscribed(json)).guid_count);
}

test "peaks/subscribe rejects more than 64 guids rather than keeping the first 64" {
    var store = TestStore.init();
    defer store.deinit();
    _ = try store.expectSubscribed(peaksCommand("\"range\":{\"start\":0,\"end\":3}"));
    const json = try guidsCommand(std.testing.allocator, peaks_subscriptions.MAX_GUIDS_PER_CLIENT + 1);
    defer std.testing.allocator.free(json);
    try store.expectInvalid(json);
}

test "peaks/subscribe rejects malformed parameters rather than falling back to defaults" {
    var store = TestStore.init();
    defer store.deinit();
    _ = try store.expectSubscribed(peaksCommand("\"range\":{\"start\":0,\"end\":3},\"sampleCount\":50"));
    const malformed = [_][]const u8{
        peaksCommand("\"range\":{\"start\":0,\"end\":3},\"sampleCount\":30.5"),
        peaksCommand("\"range\":{\"start\":0,\"end\":3},\"sampleCount\":\"30\""),
        peaksCommand("\"range\":{\"start\":1.5,\"end\":3}"),
        peaksCommand("\"range\":{\"end\":3}"),
        peaksCommand("\"range\":7"),
        peaksCommand("\"guids\":[\"{A}\",]"),
        peaksCommand("\"guids\":[{\"g\":\"{A}\"}]"),
        peaksCommand("\"guids\":[\"{00000000-0000-0000-0000-000000000000}xyz\"]"),
    };
    for (malformed) |json| try store.expectInvalid(json);
}

test "peaks/subscribe reads sampleCount, and takes 30 when it is absent" {
    var store = TestStore.init();
    defer store.deinit();
    try std.testing.expectEqual(@as(u32, 50), (try store.expectSubscribed(peaksCommand("\"range\":{\"start\":0,\"end\":3},\"sampleCount\":50"))).sample_count);
    try std.testing.expectEqual(@as(u32, 30), (try store.expectSubscribed(peaksCommand("\"guids\":[\"{A}\"]"))).sample_count);
}

test "parseViewport rejects non-finite viewport bounds" {
    try std.testing.expect(parseViewport(
        \\{"viewport":{"start":0,"end":1e999,"widthPx":400}}
    ) == null);
    try std.testing.expect(parseViewport(
        \\{"viewport":{"start":-1e999,"end":10,"widthPx":400}}
    ) == null);
    try std.testing.expect(parseViewport(
        \\{"viewport":{"start":0,"end":30,"widthPx":400}}
    ) != null);
}
