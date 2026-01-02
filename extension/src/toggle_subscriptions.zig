const std = @import("std");
const reaper = @import("reaper.zig");
const ws_server = @import("ws_server.zig");
const logging = @import("logging.zig");

const Allocator = std.mem.Allocator;

// Limits
pub const MAX_COMMAND_IDS_PER_CLIENT: usize = 256;
pub const MAX_CLIENTS: usize = 16;

/// Manages toggle state subscriptions across multiple clients.
/// Uses reference counting so we only poll commandIds that someone cares about.
pub const ToggleSubscriptions = struct {
    allocator: Allocator,

    /// Reference count for each commandId (number of clients subscribed)
    ref_counts: std.AutoHashMap(u32, u8),

    /// Previous toggle state for each commandId (for change detection)
    /// Values: -1 = not a toggle, 0 = off, 1 = on
    prev_states: std.AutoHashMap(u32, i8),

    /// Per-client subscription sets (for cleanup on disconnect)
    client_subscriptions: [MAX_CLIENTS]std.AutoHashMap(u32, void),

    /// Map from client_id to client slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Next available slot
    next_slot: usize,

    pub fn init(allocator: Allocator) ToggleSubscriptions {
        var subs = ToggleSubscriptions{
            .allocator = allocator,
            .ref_counts = std.AutoHashMap(u32, u8).init(allocator),
            .prev_states = std.AutoHashMap(u32, i8).init(allocator),
            .client_subscriptions = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .next_slot = 0,
        };

        // Initialize all client subscription maps
        for (&subs.client_subscriptions) |*map| {
            map.* = std.AutoHashMap(u32, void).init(allocator);
        }

        return subs;
    }

    pub fn deinit(self: *ToggleSubscriptions) void {
        self.ref_counts.deinit();
        self.prev_states.deinit();
        self.client_id_to_slot.deinit();

        for (&self.client_subscriptions) |*map| {
            map.deinit();
        }
    }

    /// Get or create a slot for a client
    fn getOrCreateSlot(self: *ToggleSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Find an available slot
        if (self.next_slot >= MAX_CLIENTS) {
            // Try to find a reusable slot (client that disconnected)
            // For now, just fail - we'll clean up on disconnect
            return null;
        }

        const slot = self.next_slot;
        self.next_slot += 1;
        self.client_id_to_slot.put(client_id, slot) catch return null;
        return slot;
    }

    /// Subscribe a client to a list of commandIds.
    /// Returns the current states for all subscribed commandIds.
    pub fn subscribe(
        self: *ToggleSubscriptions,
        api: *const reaper.Api,
        client_id: usize,
        command_ids: []const u32,
    ) !std.AutoHashMap(u32, i8) {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client_subs = &self.client_subscriptions[slot];

        // Enforce per-client limit
        if (client_subs.count() + command_ids.len > MAX_COMMAND_IDS_PER_CLIENT) {
            return error.TooManySubscriptions;
        }

        var states = std.AutoHashMap(u32, i8).init(self.allocator);
        errdefer states.deinit();

        for (command_ids) |cmd_id| {
            // Skip if already subscribed
            if (client_subs.contains(cmd_id)) {
                // Still include current state in response
                const state = api.getCommandState(@intCast(cmd_id));
                try states.put(cmd_id, @intCast(state));
                continue;
            }

            // Add to client's subscription set
            try client_subs.put(cmd_id, {});

            // Increment ref count
            const current_count = self.ref_counts.get(cmd_id) orelse 0;
            try self.ref_counts.put(cmd_id, current_count + 1);

            // Get current state and cache it
            const state = api.getCommandState(@intCast(cmd_id));
            try self.prev_states.put(cmd_id, @intCast(state));
            try states.put(cmd_id, @intCast(state));
        }

        return states;
    }

    /// Unsubscribe a client from a list of commandIds.
    pub fn unsubscribe(
        self: *ToggleSubscriptions,
        client_id: usize,
        command_ids: []const u32,
    ) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client_subs = &self.client_subscriptions[slot];

        for (command_ids) |cmd_id| {
            if (!client_subs.contains(cmd_id)) continue;

            // Remove from client's subscription set
            _ = client_subs.remove(cmd_id);

            // Decrement ref count
            if (self.ref_counts.get(cmd_id)) |count| {
                if (count <= 1) {
                    // No more subscribers - remove from tracking
                    _ = self.ref_counts.remove(cmd_id);
                    _ = self.prev_states.remove(cmd_id);
                } else {
                    self.ref_counts.put(cmd_id, count - 1) catch |e| {
                        logging.warn("toggle unsubscribe ref_count update failed for cmd {d}: {}", .{ cmd_id, e });
                    };
                }
            }
        }
    }

    /// Remove all subscriptions for a client (called on disconnect).
    pub fn removeClient(self: *ToggleSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client_subs = &self.client_subscriptions[slot];

        // Collect all command IDs to unsubscribe
        var cmd_ids_buf: [MAX_COMMAND_IDS_PER_CLIENT]u32 = undefined;
        var count: usize = 0;

        var iter = client_subs.keyIterator();
        while (iter.next()) |cmd_id| {
            if (count < cmd_ids_buf.len) {
                cmd_ids_buf[count] = cmd_id.*;
                count += 1;
            }
        }

        // Unsubscribe from all
        self.unsubscribe(client_id, cmd_ids_buf[0..count]);

        // Clear client's subscription set
        client_subs.clearRetainingCapacity();

        // Remove client from slot mapping
        _ = self.client_id_to_slot.remove(client_id);
    }

    /// Poll all subscribed commandIds and return changes.
    /// Returns a map of commandId -> new_state for any states that changed.
    pub fn poll(self: *ToggleSubscriptions, api: *const reaper.Api) std.AutoHashMap(u32, i8) {
        var changes = std.AutoHashMap(u32, i8).init(self.allocator);

        var iter = self.ref_counts.keyIterator();
        while (iter.next()) |cmd_id_ptr| {
            const cmd_id = cmd_id_ptr.*;
            const new_state: i8 = @intCast(api.getCommandState(@intCast(cmd_id)));
            const prev = self.prev_states.get(cmd_id) orelse -2;

            if (new_state != prev) {
                self.prev_states.put(cmd_id, new_state) catch |e| {
                    logging.warn("toggle poll prev_states update failed for cmd {d}: {}", .{ cmd_id, e });
                };
                changes.put(cmd_id, new_state) catch |e| {
                    logging.warn("toggle poll changes update failed for cmd {d}: {}", .{ cmd_id, e });
                };
            }
        }

        return changes;
    }

    /// Check if there are any active subscriptions
    pub fn hasSubscriptions(self: *const ToggleSubscriptions) bool {
        return self.ref_counts.count() > 0;
    }

    /// Format changes as JSON event message
    pub fn changesToJson(changes: *const std.AutoHashMap(u32, i8), buf: []u8) ?[]const u8 {
        if (changes.count() == 0) return null;

        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"actionToggleState\",\"changes\":{") catch return null;

        var first = true;
        var iter = changes.iterator();
        while (iter.next()) |entry| {
            if (!first) writer.writeAll(",") catch return null;
            first = false;

            writer.print("\"{d}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return null;
        }

        writer.writeAll("}}") catch return null;

        return stream.getWritten();
    }

    /// Format states as JSON for subscribe response
    pub fn statesToJson(states: *const std.AutoHashMap(u32, i8), buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        writer.writeAll("{") catch return null;

        var first = true;
        var iter = states.iterator();
        while (iter.next()) |entry| {
            if (!first) writer.writeAll(",") catch return null;
            first = false;

            writer.print("\"{d}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return null;
        }

        writer.writeAll("}") catch return null;

        return stream.getWritten();
    }
};

// Tests
test "subscribe and unsubscribe" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    // Can't test subscribe without a real REAPER API, but we can test unsubscribe logic
    // by manually adding entries
    const slot = subs.getOrCreateSlot(1).?;
    try subs.client_subscriptions[slot].put(100, {});
    try subs.ref_counts.put(100, 1);
    try subs.prev_states.put(100, 1);

    try std.testing.expect(subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 1), subs.ref_counts.count());

    subs.unsubscribe(1, &[_]u32{100});

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.ref_counts.count());
}

test "multiple clients same commandId" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    // Simulate two clients subscribing to the same commandId
    const slot1 = subs.getOrCreateSlot(1).?;
    const slot2 = subs.getOrCreateSlot(2).?;

    try subs.client_subscriptions[slot1].put(100, {});
    try subs.client_subscriptions[slot2].put(100, {});
    try subs.ref_counts.put(100, 2);
    try subs.prev_states.put(100, 1);

    // First client unsubscribes - should still have 1 ref
    subs.unsubscribe(1, &[_]u32{100});
    try std.testing.expectEqual(@as(u8, 1), subs.ref_counts.get(100).?);
    try std.testing.expect(subs.hasSubscriptions());

    // Second client unsubscribes - should remove entirely
    subs.unsubscribe(2, &[_]u32{100});
    try std.testing.expect(!subs.hasSubscriptions());
}

test "removeClient cleans up all subscriptions" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    const slot = subs.getOrCreateSlot(1).?;
    try subs.client_subscriptions[slot].put(100, {});
    try subs.client_subscriptions[slot].put(200, {});
    try subs.client_subscriptions[slot].put(300, {});
    try subs.ref_counts.put(100, 1);
    try subs.ref_counts.put(200, 1);
    try subs.ref_counts.put(300, 1);
    try subs.prev_states.put(100, 0);
    try subs.prev_states.put(200, 1);
    try subs.prev_states.put(300, -1);

    try std.testing.expectEqual(@as(usize, 3), subs.ref_counts.count());

    subs.removeClient(1);

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.ref_counts.count());
}

test "changesToJson formats correctly" {
    const allocator = std.testing.allocator;
    var changes = std.AutoHashMap(u32, i8).init(allocator);
    defer changes.deinit();

    try changes.put(40001, 1);
    try changes.put(40002, 0);

    var buf: [256]u8 = undefined;
    const json = ToggleSubscriptions.changesToJson(&changes, &buf).?;

    // The order of keys in a hashmap isn't guaranteed, so check for both possibilities
    const valid1 = std.mem.eql(u8, json, "{\"type\":\"event\",\"event\":\"actionToggleState\",\"changes\":{\"40001\":1,\"40002\":0}}");
    const valid2 = std.mem.eql(u8, json, "{\"type\":\"event\",\"event\":\"actionToggleState\",\"changes\":{\"40002\":0,\"40001\":1}}");
    try std.testing.expect(valid1 or valid2);
}

test "statesToJson formats correctly" {
    const allocator = std.testing.allocator;
    var states = std.AutoHashMap(u32, i8).init(allocator);
    defer states.deinit();

    try states.put(100, 1);

    var buf: [64]u8 = undefined;
    const json = ToggleSubscriptions.statesToJson(&states, &buf).?;

    try std.testing.expectEqualStrings("{\"100\":1}", json);
}
