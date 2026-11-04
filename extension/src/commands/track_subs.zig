/// Track subscription command handlers for viewport-driven polling.
///
/// Commands:
/// - track/subscribe: Subscribe to track updates (by range or GUID list)
/// - track/unsubscribe: Clear track subscription for this client
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const track_subscriptions = @import("../subscriptions/track_subscriptions.zig");

const MAX_GUIDS = track_subscriptions.MAX_GUIDS_PER_CLIENT;
const MAX_EXTRA_GUIDS = track_subscriptions.MAX_EXTRA_GUIDS;
const GUID_LEN = track_subscriptions.GUID_LEN;

/// Subscribe to track updates. Supports two mutually exclusive modes:
///
/// Range mode - subscribe to unified indices [start, end]:
/// { "command": "track/subscribe", "range": {"start": 0, "end": 31}, "id": "1" }
///
/// Range mode with extra GUIDs (hybrid) - subscribe to range + specific tracks outside range:
/// { "command": "track/subscribe", "range": {"start": 0, "end": 7}, "extraGuids": ["{GUID}"], "id": "1" }
///
/// GUID mode - subscribe to specific tracks by GUID:
/// { "command": "track/subscribe", "guids": ["master", "{AAA...}"], "id": "2" }
///
/// Optional includeMaster (default false) - always include master track:
/// { "command": "track/subscribe", "range": {"start": 5, "end": 10}, "includeMaster": true, "id": "3" }
///
/// A parameter that is present but malformed, or a GUID list over its limit
/// (64 guids, 8 extraGuids, 64 in all), is INVALID_PARAMS; nothing is
/// subscribed and the client's current subscription stays.
///
/// Response:
/// { "type": "response", "id": "1", "success": true, "payload": {"subscribedCount": 32} }
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.track_subs orelse {
        response.err("NOT_INITIALIZED", "Track subscriptions not initialized");
        return;
    };

    const include_master = (cmd.getFlag("includeMaster") catch
        return response.err("INVALID_PARAMS", "includeMaster must be a boolean")) orelse false;

    var extra_guid_bufs: [MAX_EXTRA_GUIDS][GUID_LEN]u8 = undefined;
    var extra_guid_lens: [MAX_EXTRA_GUIDS]usize = undefined;
    const extra_guid_count = protocol.jsonGetStringArray(cmd.raw, "extraGuids", MAX_EXTRA_GUIDS, GUID_LEN, &extra_guid_bufs, &extra_guid_lens) catch |err|
        return mod.answerGuidListError(response, "extraGuids", MAX_EXTRA_GUIDS, err);

    const range = mod.getIndexRange(cmd) catch
        return response.err("INVALID_PARAMS", "range must be an object of integer start and end");

    if (range) |r| {
        var extra_guid_slices: [MAX_EXTRA_GUIDS][]const u8 = undefined;
        const extra_guids: ?[]const []const u8 = if (extra_guid_count) |egc| blk: {
            for (0..egc) |i| extra_guid_slices[i] = extra_guid_bufs[i][0..extra_guid_lens[i]];
            break :blk extra_guid_slices[0..egc];
        } else null;

        const count = subs.subscribeRangeWithExtras(response.client_id, r.start, r.end, include_master, extra_guids) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            }
            return;
        };
        answerCount(response, count);
        return;
    }

    // GUID mode, with any extraGuids appended to the list
    var guid_bufs: [MAX_GUIDS][GUID_LEN]u8 = undefined;
    var guid_lens: [MAX_GUIDS]usize = undefined;
    const guid_count = (protocol.jsonGetStringArray(cmd.raw, "guids", MAX_GUIDS, GUID_LEN, &guid_bufs, &guid_lens) catch |err|
        return mod.answerGuidListError(response, "guids", MAX_GUIDS, err)) orelse
        return response.err("INVALID_PARAMS", "Either range or guids parameter is required");

    const extra_count = extra_guid_count orelse 0;
    if (guid_count + extra_count > MAX_GUIDS) {
        return response.err("INVALID_PARAMS", std.fmt.comptimePrint("guids and extraGuids together hold more than {d} GUIDs", .{MAX_GUIDS}));
    }

    var guid_slices: [MAX_GUIDS][]const u8 = undefined;
    for (0..guid_count) |i| guid_slices[i] = guid_bufs[i][0..guid_lens[i]];
    for (0..extra_count) |i| guid_slices[guid_count + i] = extra_guid_bufs[i][0..extra_guid_lens[i]];

    const subscribed = subs.subscribeGuids(response.client_id, guid_slices[0 .. guid_count + extra_count], include_master) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
        }
        return;
    };
    answerCount(response, subscribed);
}

fn answerCount(response: *mod.ResponseWriter, count: usize) void {
    var payload_buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedCount\":{d}}}", .{count}) catch unreachable;
    response.success(payload);
}

/// Unsubscribe from track updates.
///
/// Command format:
/// { "command": "track/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.track_subs orelse {
        response.err("NOT_INITIALIZED", "Track subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests

const TestStore = struct {
    subs: track_subscriptions.TrackSubscriptions,
    reply: mod.TestReply = .{},

    fn init() TestStore {
        return .{ .subs = track_subscriptions.TrackSubscriptions.init(std.testing.allocator) };
    }

    fn deinit(self: *TestStore) void {
        self.reply.deinit();
        self.subs.deinit();
    }

    fn client(self: *TestStore) ?*track_subscriptions.ClientSubscription {
        const slot = self.subs.client_id_to_slot.get(1) orelse return null;
        return &self.subs.clients[slot];
    }

    fn run(self: *TestStore, json: []const u8) void {
        const saved = mod.g_ctx.track_subs;
        mod.g_ctx.track_subs = &self.subs;
        defer mod.g_ctx.track_subs = saved;
        const mock = @import("../reaper/mock/mod.zig");
        var m = mock.MockBackend{};
        mod.testRunHandlerReply(&m, handleSubscribe, json, &self.reply);
    }

    /// Run track/subscribe, require success, and return client 1's
    /// subscription.
    fn expectSubscribed(self: *TestStore, json: []const u8) !*track_subscriptions.ClientSubscription {
        self.run(json);
        if (!self.reply.succeeded()) {
            std.debug.print("expected success for {s}, got {s}\n", .{ json, self.reply.json() });
            return error.TestUnexpectedResult;
        }
        return self.client() orelse error.TestUnexpectedResult;
    }

    /// Run track/subscribe and require INVALID_PARAMS, leaving client 1's
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
            try std.testing.expectEqual(b.range_end, after.?.range_end);
            try std.testing.expectEqual(b.guid_count, after.?.guid_count);
            try std.testing.expectEqual(b.extra_guid_count, after.?.extra_guid_count);
            try std.testing.expectEqual(b.include_master, after.?.include_master);
        }
    }
};

/// A track/subscribe command holding `fields`.
fn subscribeCommand(comptime fields: []const u8) []const u8 {
    return "{\"type\":\"command\",\"command\":\"track/subscribe\"," ++ fields ++ "}";
}

/// A track/subscribe command whose `key` lists `count` distinct GUIDs.
fn guidsCommand(allocator: std.mem.Allocator, comptime prefix: []const u8, key: []const u8, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{{\"type\":\"command\",\"command\":\"track/subscribe\",{s}\"{s}\":[", .{ prefix, key });
    for (0..count) |i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(allocator, "\"{{00000000-0000-0000-0000-{d:0>12}}}\"", .{i});
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

test "track/subscribe accepts exactly 64 guids, and exactly 8 extraGuids with a range" {
    var store = TestStore.init();
    defer store.deinit();
    const guids = try guidsCommand(std.testing.allocator, "", "guids", MAX_GUIDS);
    defer std.testing.allocator.free(guids);
    try std.testing.expectEqual(@as(usize, MAX_GUIDS), (try store.expectSubscribed(guids)).guid_count);

    const extras = try guidsCommand(std.testing.allocator, "\"range\":{\"start\":0,\"end\":7},", "extraGuids", MAX_EXTRA_GUIDS);
    defer std.testing.allocator.free(extras);
    try std.testing.expectEqual(@as(usize, MAX_EXTRA_GUIDS), (try store.expectSubscribed(extras)).extra_guid_count);
}

test "track/subscribe rejects more than 64 guids rather than keeping the first 64" {
    var store = TestStore.init();
    defer store.deinit();
    _ = try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":0,\"end\":7}"));
    const json = try guidsCommand(std.testing.allocator, "", "guids", MAX_GUIDS + 1);
    defer std.testing.allocator.free(json);
    try store.expectInvalid(json);
}

test "track/subscribe rejects more than 8 extraGuids rather than keeping the first 8" {
    var store = TestStore.init();
    defer store.deinit();
    const json = try guidsCommand(std.testing.allocator, "\"range\":{\"start\":0,\"end\":7},", "extraGuids", MAX_EXTRA_GUIDS + 1);
    defer std.testing.allocator.free(json);
    try store.expectInvalid(json);
}

test "track/subscribe rejects guids and extraGuids that together pass 64 rather than dropping the extras" {
    var store = TestStore.init();
    defer store.deinit();
    const json = try guidsCommand(std.testing.allocator, "\"extraGuids\":[\"{E}\"],", "guids", MAX_GUIDS);
    defer std.testing.allocator.free(json);
    try store.expectInvalid(json);
}

test "track/subscribe appends extraGuids to the guids list" {
    var store = TestStore.init();
    defer store.deinit();
    const client = try store.expectSubscribed(subscribeCommand("\"guids\":[\"{A}\",\"master\"],\"extraGuids\":[\"{E}\"]"));
    try std.testing.expectEqual(@as(usize, 3), client.guid_count);
    try std.testing.expectEqualStrings("{E}", client.getGuid(2).?);
}

test "track/subscribe rejects a GUID longer than 40 bytes rather than cutting it" {
    var store = TestStore.init();
    defer store.deinit();
    try store.expectInvalid(subscribeCommand("\"guids\":[\"{00000000-0000-0000-0000-000000000000}xyz\"]"));
}

test "track/subscribe rejects malformed parameters rather than falling back" {
    var store = TestStore.init();
    defer store.deinit();
    _ = try store.expectSubscribed(subscribeCommand("\"guids\":[\"{A}\"],\"includeMaster\":true"));
    const malformed = [_][]const u8{
        subscribeCommand("\"range\":{\"start\":1.5,\"end\":7},\"guids\":[\"{A}\"]"),
        subscribeCommand("\"range\":{\"start\":0,\"end\":\"7\"},\"guids\":[\"{A}\"]"),
        subscribeCommand("\"range\":{\"start\":0},\"guids\":[\"{A}\"]"),
        subscribeCommand("\"range\":[0,7],\"guids\":[\"{A}\"]"),
        subscribeCommand("\"guids\":[\"{A}\",]"),
        subscribeCommand("\"guids\":[\"{A}\",7]"),
        subscribeCommand("\"guids\":\"{A}\",\"extraGuids\":[\"{E}\"]"),
        subscribeCommand("\"range\":{\"start\":0,\"end\":7},\"extraGuids\":[null]"),
        subscribeCommand("\"range\":{\"start\":0,\"end\":7},\"includeMaster\":\"yes\""),
    };
    for (malformed) |json| try store.expectInvalid(json);
}

test "track/subscribe still answers INVALID_PARAMS when neither range nor guids is given" {
    var store = TestStore.init();
    defer store.deinit();
    try store.expectInvalid(subscribeCommand("\"includeMaster\":true"));
}

test "track/subscribe reads includeMaster as a boolean or 0/1" {
    var store = TestStore.init();
    defer store.deinit();
    try std.testing.expect((try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":1,\"end\":2},\"includeMaster\":true"))).include_master);
    try std.testing.expect(!(try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":1,\"end\":2},\"includeMaster\":0"))).include_master);
    try std.testing.expect(!(try store.expectSubscribed(subscribeCommand("\"range\":{\"start\":1,\"end\":2}"))).include_master);
}
