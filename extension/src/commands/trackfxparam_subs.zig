/// Track FX Parameter subscription command handlers.
///
/// Commands:
/// - trackFxParams/subscribe: Subscribe to an FX's parameter values (range or indices mode)
/// - trackFxParams/unsubscribe: Clear parameter subscription for this client
///
/// Single FX per client - subscribing auto-unsubscribes from previous FX.
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const trackfxparam_subscriptions = @import("../subscriptions/trackfxparam_subscriptions.zig");

const MAX_SUBSCRIBED_PARAMS = trackfxparam_subscriptions.MAX_SUBSCRIBED_PARAMS;
const too_many_indices_msg = std.fmt.comptimePrint("At most {d} param indices allowed", .{MAX_SUBSCRIBED_PARAMS});
const too_wide_range_msg = std.fmt.comptimePrint("A range may cover at most {d} params", .{MAX_SUBSCRIBED_PARAMS});

/// Subscribe to FX parameter value updates.
///
/// Command formats:
///
/// Range mode (for scrollable views):
/// { "command": "trackFxParams/subscribe", "trackGuid": "{AAA}", "fxGuid": "{BBB}",
///   "rangeStart": 0, "rangeEnd": 20, "id": "1" }
///
/// Indices mode (for filtered/pinned params):
/// { "command": "trackFxParams/subscribe", "trackGuid": "{AAA}", "fxGuid": "{BBB}",
///   "indices": [0, 5, 10, 15], "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// Either mode covers at most MAX_SUBSCRIBED_PARAMS parameters, from index 0
/// up; a request outside that is rejected (TOO_MANY_PARAMS, INVALID_RANGE,
/// INVALID_INDEX, or INVALID_PARAMS for indices that are not an integer
/// array) and the current subscription is kept.
///
/// After subscribing, the client receives "trackFxParams" events at 30Hz
/// containing parameter values for the subscribed range/indices.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.trackfxparam_subs orelse {
        response.err("NOT_INITIALIZED", "Track FX parameter subscriptions not initialized");
        return;
    };

    // Get required parameters
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    const fx_guid = cmd.getString("fxGuid") orelse {
        response.err("MISSING_PARAM", "fxGuid is required");
        return;
    };

    // Determine mode: an indices array, even an empty one, takes precedence,
    // else use range
    var indices_buf: [MAX_SUBSCRIBED_PARAMS]c_int = undefined;
    const maybe_indices = cmd.getIntArray("indices", MAX_SUBSCRIBED_PARAMS, &indices_buf) catch |err| {
        switch (err) {
            error.TooManyItems => response.err("TOO_MANY_PARAMS", too_many_indices_msg),
            error.Malformed => response.err("INVALID_PARAMS", "indices must be an array of integers"),
        }
        return;
    };
    if (maybe_indices) |indices| {
        // Indices mode
        subs.subscribeIndices(response.client_id, track_guid, fx_guid, indices) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
                error.TooManyParams => response.err("TOO_MANY_PARAMS", too_many_indices_msg),
                error.InvalidIndex => response.err("INVALID_INDEX", "Param indices must be >= 0"),
            }
            return;
        };
    } else {
        // Range mode, inclusive (default 0-20). The frontend builder sends
        // "range": {"start", "end"}; API.md's flat rangeStart/rangeEnd also work.
        // A bound that is present but not an integer is an error, not the default.
        const range_obj = protocol.jsonGetObject(cmd.raw, "range") catch {
            response.err("INVALID_PARAMS", "range must be an object of integer start and end");
            return;
        };
        const range_start = rangeBound(cmd.raw, range_obj, "start", "rangeStart", 0) catch {
            response.err("INVALID_PARAMS", "The range start must be an integer");
            return;
        };
        const range_end = rangeBound(cmd.raw, range_obj, "end", "rangeEnd", 20) catch {
            response.err("INVALID_PARAMS", "The range end must be an integer");
            return;
        };

        subs.subscribeRange(response.client_id, track_guid, fx_guid, range_start, range_end) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
                error.InvalidRange => response.err("INVALID_RANGE", "rangeStart must be >= 0 and <= rangeEnd"),
                error.TooManyParams => response.err("TOO_MANY_PARAMS", too_wide_range_msg),
            }
            return;
        };
    }

    response.success(null);
}

/// One bound of a range subscription: `field` of the "range" object, else the
/// flat `flat_key`, else `default` when neither is present.
fn rangeBound(raw: []const u8, range_obj: ?[]const u8, comptime field: []const u8, comptime flat_key: []const u8, default: c_int) error{Malformed}!c_int {
    if (range_obj) |obj| {
        if (try protocol.jsonGetIntStrict(obj, field)) |v| return v;
    }
    return try protocol.jsonGetIntStrict(raw, flat_key) orelse default;
}

/// Unsubscribe from FX parameter updates.
///
/// Command format:
/// { "command": "trackFxParams/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.trackfxparam_subs orelse {
        response.err("NOT_INITIALIZED", "Track FX parameter subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests

/// A subscription store installed in g_ctx for one test, subscribed to by
/// client 1 (the client the test handler runners answer for).
const TestStore = struct {
    subs: trackfxparam_subscriptions.TrackFxParamSubscriptions,
    reply: mod.TestReply = .{},

    fn init() TestStore {
        return .{ .subs = trackfxparam_subscriptions.TrackFxParamSubscriptions.init(std.testing.allocator) };
    }

    fn deinit(self: *TestStore) void {
        self.reply.deinit();
        self.subs.deinit();
    }

    fn run(self: *TestStore, json: []const u8) void {
        const saved = mod.g_ctx.trackfxparam_subs;
        mod.g_ctx.trackfxparam_subs = &self.subs;
        defer mod.g_ctx.trackfxparam_subs = saved;
        const mock = @import("../reaper/mock/mod.zig");
        var m = mock.MockBackend{};
        mod.testRunHandlerReply(&m, handleSubscribe, json, &self.reply);
    }

    /// Run trackFxParams/subscribe, require success, and return client 1's
    /// subscription.
    fn expectSubscribed(self: *TestStore, json: []const u8) !*trackfxparam_subscriptions.ClientSubscription {
        self.run(json);
        if (!self.reply.succeeded()) {
            std.debug.print("expected success, got {s}\n", .{self.reply.json()});
            return error.TestUnexpectedResult;
        }
        return self.subs.getClient(1) orelse error.TestUnexpectedResult;
    }

    /// Run trackFxParams/subscribe and require it to fail with `code`,
    /// leaving client 1's subscription as it was.
    fn expectRejected(self: *TestStore, json: []const u8, code: []const u8) !void {
        const before = if (self.subs.getClient(1)) |c| c.* else null;
        self.run(json);
        std.testing.expectEqualStrings(code, self.reply.errorCode() orelse "(no error)") catch |e| {
            std.debug.print("reply to {s}:\n  {s}\n", .{ json, self.reply.json() });
            return e;
        };
        const after = if (self.subs.getClient(1)) |c| c.* else null;
        try std.testing.expectEqual(before == null, after == null);
        if (before) |b| {
            try std.testing.expectEqual(b.mode, after.?.mode);
            try std.testing.expectEqual(b.range_start, after.?.range_start);
            try std.testing.expectEqual(b.range_end, after.?.range_end);
            try std.testing.expectEqual(b.indices_count, after.?.indices_count);
        }
    }
};

/// A subscribe command in indices mode for indices 0..count-1.
fn indicesCommand(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"command\",\"command\":\"trackFxParams/subscribe\",\"trackGuid\":\"{T}\",\"fxGuid\":\"{F}\",\"indices\":[");
    for (0..count) |i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(allocator, "{d}", .{i});
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

/// A subscribe command with `fields` after the GUIDs.
fn subscribeCommand(comptime fields: []const u8) []const u8 {
    return "{\"type\":\"command\",\"command\":\"trackFxParams/subscribe\",\"trackGuid\":\"{T}\",\"fxGuid\":\"{F}\"," ++ fields ++ "}";
}

test "trackFxParams/subscribe accepts exactly MAX_SUBSCRIBED_PARAMS indices" {
    var store = TestStore.init();
    defer store.deinit();
    const json = try indicesCommand(std.testing.allocator, MAX_SUBSCRIBED_PARAMS);
    defer std.testing.allocator.free(json);

    const client = try store.expectSubscribed(json);
    try std.testing.expectEqual(trackfxparam_subscriptions.Mode.indices, client.mode);
    try std.testing.expectEqual(@as(usize, MAX_SUBSCRIBED_PARAMS), client.indices_count);
}

test "trackFxParams/subscribe rejects more than MAX_SUBSCRIBED_PARAMS indices with TOO_MANY_PARAMS rather than keeping the first ones" {
    var store = TestStore.init();
    defer store.deinit();
    const json = try indicesCommand(std.testing.allocator, MAX_SUBSCRIBED_PARAMS + 1);
    defer std.testing.allocator.free(json);

    try store.expectRejected(json, "TOO_MANY_PARAMS");
}

test "trackFxParams/subscribe accepts a range of exactly MAX_SUBSCRIBED_PARAMS parameters" {
    var store = TestStore.init();
    defer store.deinit();

    const client = try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":0,\"end\":99}"));
    try std.testing.expectEqual(trackfxparam_subscriptions.Mode.range, client.mode);
    try std.testing.expectEqual(@as(c_int, 0), client.range_start);
    try std.testing.expectEqual(@as(c_int, 99), client.range_end);
}

test "trackFxParams/subscribe rejects a range wider than MAX_SUBSCRIBED_PARAMS parameters with TOO_MANY_PARAMS" {
    var store = TestStore.init();
    defer store.deinit();

    try store.expectRejected(subscribeCommand("\"range\":{\"start\":0,\"end\":100}"), "TOO_MANY_PARAMS");
    try store.expectRejected(subscribeCommand("\"rangeStart\":0,\"rangeEnd\":100000"), "TOO_MANY_PARAMS");
}

test "trackFxParams/subscribe rejects a negative range start in either range form with INVALID_RANGE" {
    var store = TestStore.init();
    defer store.deinit();

    try store.expectRejected(subscribeCommand("\"range\":{\"start\":-1,\"end\":5}"), "INVALID_RANGE");
    try store.expectRejected(subscribeCommand("\"rangeStart\":-1,\"rangeEnd\":5"), "INVALID_RANGE");
    try store.expectRejected(subscribeCommand("\"range\":{\"start\":6,\"end\":5}"), "INVALID_RANGE");
}

test "trackFxParams/subscribe rejects a negative index with INVALID_INDEX" {
    var store = TestStore.init();
    defer store.deinit();

    try store.expectRejected(subscribeCommand("\"indices\":[2,-1,4]"), "INVALID_INDEX");
}

test "trackFxParams/subscribe with indices that are not integers is rejected with INVALID_PARAMS, not read as a range" {
    var store = TestStore.init();
    defer store.deinit();

    try store.expectRejected(subscribeCommand("\"indices\":[1.5]"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"indices\":[1,\"2\"]"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"indices\":[99999999999]"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"indices\":null,\"range\":{\"start\":0,\"end\":5}"), "INVALID_PARAMS");
}

test "trackFxParams/subscribe with an empty indices list subscribes to no parameter values, not a range" {
    var store = TestStore.init();
    defer store.deinit();

    const client = try store.expectSubscribed(subscribeCommand("\"indices\":[],\"range\":{\"start\":0,\"end\":5}"));
    try std.testing.expectEqual(trackfxparam_subscriptions.Mode.indices, client.mode);
    try std.testing.expectEqual(@as(usize, 0), client.indices_count);
}

test "trackFxParams/subscribe rejects range bounds that are not integers with INVALID_PARAMS instead of using the defaults" {
    var store = TestStore.init();
    defer store.deinit();

    // A known subscription, which every rejection below must leave alone
    _ = try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":3,\"end\":7}"));

    try store.expectRejected(subscribeCommand("\"range\":{\"start\":-1.5,\"end\":5}"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"range\":{\"start\":0,\"end\":1e9}"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"range\":{\"start\":99999999999,\"end\":5}"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"range\":{\"start\":\"0\",\"end\":5}"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"range\":{\"start\":null,\"end\":5}"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"rangeStart\":0,\"rangeEnd\":1e9"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"rangeStart\":2.5,\"rangeEnd\":5"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"rangeStart\":0,\"rangeEnd\":99999999999"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"range\":5"), "INVALID_PARAMS");
    try store.expectRejected(subscribeCommand("\"range\":null"), "INVALID_PARAMS");
}

test "trackFxParams/subscribe uses the default for a range bound that is absent" {
    var store = TestStore.init();
    defer store.deinit();

    var client = try store.expectSubscribed(subscribeCommand("\"range\":{\"end\":5}"));
    try std.testing.expectEqual(@as(c_int, 0), client.range_start);
    try std.testing.expectEqual(@as(c_int, 5), client.range_end);

    client = try store.expectSubscribed(subscribeCommand("\"rangeStart\":4"));
    try std.testing.expectEqual(@as(c_int, 4), client.range_start);
    try std.testing.expectEqual(@as(c_int, 20), client.range_end);

    // A bound missing from the range object falls back to the flat form
    client = try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":2},\"rangeEnd\":9"));
    try std.testing.expectEqual(@as(c_int, 2), client.range_start);
    try std.testing.expectEqual(@as(c_int, 9), client.range_end);

    client = try store.expectSubscribed(subscribeCommand("\"rangeStart\":0,\"rangeEnd\":0"));
    try std.testing.expectEqual(@as(c_int, 0), client.range_end);
}
