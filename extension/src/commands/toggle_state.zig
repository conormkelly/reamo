const std = @import("std");
const logging = @import("../core/logging.zig");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const toggle_subscriptions = @import("../subscriptions/toggle_subscriptions.zig");
const ActionKey = toggle_subscriptions.ActionKey;

/// The actions a subscribe or unsubscribe names, in any of its four forms:
///   - actions (array of {c: commandId, s: sectionId}): Section-aware numeric command IDs
///   - namedActions (array of {n: name, s: sectionId}): Section-aware named commands
///   - commandIds (array of int): Legacy format, defaults to sectionId=0
///   - names (array of string): Legacy format, defaults to sectionId=0
const ToggleParams = struct {
    actions: ?[]const struct { c: i64, s: i64 = 0 } = null,
    namedActions: ?[]const struct { n: []const u8, s: i64 = 0 } = null,
    commandIds: ?[]const i64 = null,
    names: ?[]const []const u8 = null,
};

/// Parse the message as JSON, so any valid spacing, escaping or field order
/// works. Strings come back unescaped. Free with deinit.
fn parseParams(cmd: protocol.CommandMessage) ?std.json.Parsed(ToggleParams) {
    return std.json.parseFromSlice(ToggleParams, std.heap.c_allocator, cmd.raw, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

const NamedKey = struct { name: []const u8, key: ActionKey };

/// The ActionKeys the params name, with how each name resolved (the
/// subscribe response maps names to the command IDs change events carry).
const Collected = struct {
    keys: [512]ActionKey = undefined,
    keys_len: usize = 0,
    named: [256]NamedKey = undefined,
    named_len: usize = 0,

    fn addKey(self: *Collected, key: ActionKey) void {
        if (self.keys_len < self.keys.len) {
            self.keys[self.keys_len] = key;
            self.keys_len += 1;
        }
    }

    fn addNamed(self: *Collected, name: []const u8, key: ActionKey) void {
        self.addKey(key);
        if (self.named_len < self.named.len) {
            self.named[self.named_len] = .{ .name = name, .key = key };
            self.named_len += 1;
        }
    }

    fn slice(self: *const Collected) []const ActionKey {
        return self.keys[0..self.keys_len];
    }
};

/// A key from a command ID and section the client sent. null when either
/// can't be one: REAPER command IDs are c_int (subscribing casts to it),
/// and sections are i32.
fn keyFrom(section: i64, command_id: i64) ?ActionKey {
    const c = std.math.cast(u31, command_id) orelse return null;
    const sec = std.math.cast(i32, section) orelse return null;
    return ActionKey.init(sec, c);
}

/// Every action the params name; unknown names and invalid IDs are skipped.
fn collect(api: anytype, params: ToggleParams, out: *Collected) void {
    for (params.actions orelse &.{}) |act| {
        if (keyFrom(act.s, act.c)) |key| out.addKey(key);
    }
    for (params.namedActions orelse &.{}) |act| {
        const resolved = api.namedCommandLookup(act.n);
        if (resolved <= 0) continue;
        if (keyFrom(act.s, resolved)) |key| out.addNamed(act.n, key);
    }
    for (params.commandIds orelse &.{}) |id| {
        if (keyFrom(0, id)) |key| out.addKey(key);
    }
    for (params.names orelse &.{}) |name| {
        const resolved = api.namedCommandLookup(name);
        if (resolved <= 0) continue;
        if (keyFrom(0, resolved)) |key| out.addNamed(name, key);
    }
}

/// Subscribe to toggle states for a list of commandIds and/or named commands
/// (see ToggleParams). At least one action must be given.
/// Returns current state as array of {s: sectionId, c: commandId, v: state}.
pub fn handleSubscribe(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    const parsed = parseParams(cmd) orelse {
        response.err("INVALID_PARAMS", "actions, namedActions, commandIds or names is malformed");
        return;
    };
    defer parsed.deinit();
    var collected = Collected{};
    collect(api, parsed.value, &collected);

    if (collected.keys_len == 0) {
        response.err("MISSING_PARAMS", "actions, namedActions, commandIds, or names array is required");
        return;
    }

    // Subscribe and get current states
    var states = subs.subscribe(api, response.client_id, collected.slice()) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            error.TooManySubscriptions => response.err("TOO_MANY_SUBSCRIPTIONS", "Maximum 256 actions per client"),
            else => {
                logging.warn("toggle/subscribe failed for client {d}: {s}", .{ response.client_id, @errorName(err) });
                response.err("SUBSCRIBE_FAILED", "Failed to subscribe");
            },
        }
        return;
    };
    defer states.deinit();

    // Use scratch arena for JSON buffers (16KB+8KB+32KB — too large for stack per §1)
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    // Format states as JSON array [{s: sectionId, c: commandId, v: state}, ...]
    const states_buf = scratch.alloc(u8, 16384) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    const states_json = toggle_subscriptions.ToggleSubscriptions.statesToJson(&states, states_buf) orelse {
        response.err("JSON_ERROR", "Failed to format states");
        return;
    };

    // Build nameToId mapping if names were used (frontend needs this to translate change events)
    const mapping_buf = scratch.alloc(u8, 8192) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    const mapping_json = nameMappingJson(collected.named[0..collected.named_len], mapping_buf) orelse {
        response.err("JSON_ERROR", "Failed to format mapping");
        return;
    };

    // Build full response payload: {"states": [...], "nameToId": [...]}
    const payload_buf = scratch.alloc(u8, 32000) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    const payload = std.fmt.bufPrint(payload_buf, "{{\"states\":{s},\"nameToId\":{s}}}", .{ states_json, mapping_json }) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.success(payload);
}

/// [{n: name, s: sectionId, c: commandId}, ...]; names are escaped as sent
/// back (they were unescaped when parsed).
fn nameMappingJson(named: []const NamedKey, buf: []u8) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    w.writeAll("[") catch return null;
    for (named, 0..) |mapping, i| {
        if (i > 0) w.writeAll(",") catch return null;
        w.writeAll("{\"n\":\"") catch return null;
        protocol.writeJsonString(w, mapping.name) catch return null;
        w.print("\",\"s\":{d},\"c\":{d}}}", .{ mapping.key.section_id, mapping.key.command_id }) catch return null;
    }
    w.writeAll("]") catch return null;
    return stream.getWritten();
}

/// Unsubscribe from toggle states, naming actions in any of the forms
/// subscribe accepts (see ToggleParams).
pub fn handleUnsubscribe(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    const parsed = parseParams(cmd) orelse {
        response.err("INVALID_PARAMS", "actions, namedActions, commandIds or names is malformed");
        return;
    };
    defer parsed.deinit();
    var collected = Collected{};
    collect(api, parsed.value, &collected);

    if (collected.keys_len == 0) {
        response.err("MISSING_PARAMS", "actions, namedActions, commandIds, or names array is required");
        return;
    }

    subs.unsubscribe(response.client_id, collected.slice());
    response.success(null);
}

// Tests
fn testCollect(json: []const u8) !Collected {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{};
    const parsed = parseParams(protocol.CommandMessage.parse(json).?) orelse return error.ParseFailed;
    defer parsed.deinit();
    var out = Collected{};
    collect(&m, parsed.value, &out);
    out.named_len = 0; // names point into the freed parse
    return out;
}

test "every action form is read, with any JSON spacing" {
    const out = try testCollect(
        \\{ "type": "command", "command": "actionToggleState/subscribe",
        \\  "actions": [ { "s": 32060, "c": 40001 } ], "commandIds": [ 40364 , 1007 ],
        \\  "namedActions": [ { "n": "_SWS_ABOUT", "s": 0 } ], "names": [ "_RS1234" ] }
    );
    try std.testing.expectEqual(@as(usize, 5), out.keys_len);
    try std.testing.expectEqual(ActionKey.init(32060, 40001), out.keys[0]);
    try std.testing.expectEqual(ActionKey.init(0, 40364), out.keys[2]);
    try std.testing.expectEqual(ActionKey.init(0, 1007), out.keys[3]);
}

test "a named action is looked up by its name as typed, escapes undone" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{};
    const parsed = parseParams(protocol.CommandMessage.parse(
        \\{"type":"command","command":"actionToggleState/unsubscribe","namedActions":[{"n":"_RS\"quoted\" }","s":0}]}
    ).?).?;
    defer parsed.deinit();
    var out = Collected{};
    collect(&m, parsed.value, &out);
    try std.testing.expectEqual(@as(usize, 1), out.named_len);
    try std.testing.expectEqualStrings("_RS\"quoted\" }", out.named[0].name);
    try std.testing.expectEqual(ActionKey.init(0, @intCast(m.namedCommandLookup("_RS\"quoted\" }"))), out.keys[0]);
}

test "toggle params drop command IDs that don't fit REAPER's c_int command type" {
    // Subscribing casts each ID to c_int for GetToggleCommandStateEx; IDs above
    // maxInt(c_int) panicked there.
    const ids = try testCollect(
        \\{"type":"command","command":"actionToggleState/subscribe","commandIds":[2147483648,4294967295,-1,40364]}
    );
    try std.testing.expectEqual(@as(usize, 1), ids.keys_len);
    try std.testing.expectEqual(@as(u32, 40364), ids.keys[0].command_id);

    const actions = try testCollect(
        \\{"type":"command","command":"actionToggleState/subscribe","actions":[{"c":2147483648,"s":0},{"c":40364,"s":0}]}
    );
    try std.testing.expectEqual(@as(usize, 1), actions.keys_len);
    try std.testing.expectEqual(@as(u32, 40364), actions.keys[0].command_id);
}

test "the name mapping escapes names it sends back" {
    var buf: [256]u8 = undefined;
    const json = nameMappingJson(&.{.{ .name = "a\"b", .key = ActionKey.init(0, 7) }}, &buf).?;
    try std.testing.expectEqualStrings("[{\"n\":\"a\\\"b\",\"s\":0,\"c\":7}]", json);
    try std.testing.expect(try std.json.validate(std.testing.allocator, json));
}
