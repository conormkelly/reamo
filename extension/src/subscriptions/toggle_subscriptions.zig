const std = @import("std");
const reaper = @import("../reaper.zig");
const ws_server = @import("../server/ws_server.zig");
const logging = @import("../core/logging.zig");
const constants = @import("../core/constants.zig");

const Allocator = std.mem.Allocator;

// Re-export shared constants for backward compatibility
pub const MAX_COMMAND_IDS_PER_CLIENT = constants.MAX_COMMAND_IDS_PER_CLIENT;
pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;

/// Composite key for (sectionId, commandId) pairs.
/// Action IDs are only unique within a section, so we need both to identify an action.
/// Encoded as u64: high 32 bits = sectionId, low 32 bits = commandId
pub const ActionKey = struct {
    section_id: i32,
    command_id: u32,

    pub fn encode(self: ActionKey) u64 {
        // Cast section_id to u32 for bit manipulation (preserves bit pattern), then to u64
        const section_u32: u32 = @bitCast(self.section_id);
        const section_bits: u64 = section_u32;
        return (section_bits << 32) | @as(u64, self.command_id);
    }

    pub fn decode(key: u64) ActionKey {
        return .{
            .section_id = @bitCast(@as(u32, @truncate(key >> 32))),
            .command_id = @truncate(key),
        };
    }

    pub fn init(section_id: i32, command_id: u32) ActionKey {
        return .{ .section_id = section_id, .command_id = command_id };
    }
};

/// Manages toggle state subscriptions across multiple clients.
/// Uses reference counting so we only poll (sectionId, commandId) pairs that someone cares about.
pub const ToggleSubscriptions = struct {
    allocator: Allocator,

    /// Reference count for each (sectionId, commandId) pair (number of clients subscribed)
    ref_counts: std.AutoHashMap(u64, u8),

    /// Previous toggle state for each (sectionId, commandId) pair (for change detection)
    /// Values: -1 = not a toggle, 0 = off, 1 = on
    prev_states: std.AutoHashMap(u64, i8),

    /// Per-client subscription sets (for cleanup on disconnect)
    client_subscriptions: [MAX_CLIENTS]std.AutoHashMap(u64, void),

    /// Map from client_id to client slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Next available slot
    next_slot: usize,

    pub fn init(allocator: Allocator) ToggleSubscriptions {
        var subs = ToggleSubscriptions{
            .allocator = allocator,
            .ref_counts = std.AutoHashMap(u64, u8).init(allocator),
            .prev_states = std.AutoHashMap(u64, i8).init(allocator),
            .client_subscriptions = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .next_slot = 0,
        };

        // Initialize all client subscription maps
        for (&subs.client_subscriptions) |*map| {
            map.* = std.AutoHashMap(u64, void).init(allocator);
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
        self.client_id_to_slot.put(client_id, slot) catch |e| {
            logging.warn("toggle_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return null;
        };
        return slot;
    }

    /// Subscribe a client to a list of (sectionId, commandId) pairs.
    /// Returns the current states for all subscribed actions, keyed by encoded ActionKey.
    pub fn subscribe(
        self: *ToggleSubscriptions,
        api: anytype,
        client_id: usize,
        action_keys: []const ActionKey,
    ) !std.AutoHashMap(u64, i8) {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client_subs = &self.client_subscriptions[slot];

        // Enforce per-client limit
        if (client_subs.count() + action_keys.len > MAX_COMMAND_IDS_PER_CLIENT) {
            return error.TooManySubscriptions;
        }

        var states = std.AutoHashMap(u64, i8).init(self.allocator);
        errdefer states.deinit();

        for (action_keys) |action_key| {
            const key = action_key.encode();

            // Skip if already subscribed
            if (client_subs.contains(key)) {
                // Still include current state in response
                const state = api.getCommandStateEx(action_key.section_id, @intCast(action_key.command_id));
                try states.put(key, @intCast(state));
                continue;
            }

            // Add to client's subscription set
            try client_subs.put(key, {});

            // Increment ref count
            const current_count = self.ref_counts.get(key) orelse 0;
            try self.ref_counts.put(key, current_count + 1);

            // Get current state and cache it (using section-aware API)
            const state = api.getCommandStateEx(action_key.section_id, @intCast(action_key.command_id));
            try self.prev_states.put(key, @intCast(state));
            try states.put(key, @intCast(state));
        }

        return states;
    }

    /// Unsubscribe a client from a list of (sectionId, commandId) pairs.
    pub fn unsubscribe(
        self: *ToggleSubscriptions,
        client_id: usize,
        action_keys: []const ActionKey,
    ) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client_subs = &self.client_subscriptions[slot];

        for (action_keys) |action_key| {
            const key = action_key.encode();
            if (!client_subs.contains(key)) continue;

            // Remove from client's subscription set
            _ = client_subs.remove(key);

            // Decrement ref count
            if (self.ref_counts.get(key)) |count| {
                if (count <= 1) {
                    // No more subscribers - remove from tracking
                    _ = self.ref_counts.remove(key);
                    _ = self.prev_states.remove(key);
                } else {
                    self.ref_counts.put(key, count - 1) catch |e| {
                        logging.warn("toggle unsubscribe ref_count update failed for key {d}: {}", .{ key, e });
                    };
                }
            }
        }
    }

    /// Unsubscribe a client from a list of encoded keys (for internal use by removeClient).
    fn unsubscribeKeys(
        self: *ToggleSubscriptions,
        client_id: usize,
        keys: []const u64,
    ) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client_subs = &self.client_subscriptions[slot];

        for (keys) |key| {
            if (!client_subs.contains(key)) continue;

            // Remove from client's subscription set
            _ = client_subs.remove(key);

            // Decrement ref count
            if (self.ref_counts.get(key)) |count| {
                if (count <= 1) {
                    // No more subscribers - remove from tracking
                    _ = self.ref_counts.remove(key);
                    _ = self.prev_states.remove(key);
                } else {
                    self.ref_counts.put(key, count - 1) catch |e| {
                        logging.warn("toggle unsubscribe ref_count update failed for key {d}: {}", .{ key, e });
                    };
                }
            }
        }
    }

    /// Remove all subscriptions for a client (called on disconnect).
    pub fn removeClient(self: *ToggleSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client_subs = &self.client_subscriptions[slot];

        // Collect all encoded keys to unsubscribe
        var keys_buf: [MAX_COMMAND_IDS_PER_CLIENT]u64 = undefined;
        var count: usize = 0;

        var iter = client_subs.keyIterator();
        while (iter.next()) |key| {
            if (count < keys_buf.len) {
                keys_buf[count] = key.*;
                count += 1;
            }
        }

        // Unsubscribe from all
        self.unsubscribeKeys(client_id, keys_buf[0..count]);

        // Clear client's subscription set
        client_subs.clearRetainingCapacity();

        // Remove client from slot mapping
        _ = self.client_id_to_slot.remove(client_id);
    }

    /// Poll all subscribed (sectionId, commandId) pairs and return changes.
    /// Returns a map of encoded ActionKey -> new_state for any states that changed.
    pub fn poll(self: *ToggleSubscriptions, api: anytype) std.AutoHashMap(u64, i8) {
        var changes = std.AutoHashMap(u64, i8).init(self.allocator);

        var iter = self.ref_counts.keyIterator();
        while (iter.next()) |key_ptr| {
            const key = key_ptr.*;
            const action_key = ActionKey.decode(key);
            // Use section-aware API to get toggle state
            const new_state: i8 = @intCast(api.getCommandStateEx(action_key.section_id, @intCast(action_key.command_id)));
            const prev = self.prev_states.get(key) orelse -2;

            if (new_state != prev) {
                self.prev_states.put(key, new_state) catch |e| {
                    logging.warn("toggle poll prev_states update failed for key {d}: {}", .{ key, e });
                };
                changes.put(key, new_state) catch |e| {
                    logging.warn("toggle poll changes update failed for key {d}: {}", .{ key, e });
                };
            }
        }

        return changes;
    }

    /// Check if there are any active subscriptions
    pub fn hasSubscriptions(self: *const ToggleSubscriptions) bool {
        return self.ref_counts.count() > 0;
    }

    /// Format changes as JSON event message with structured array format.
    /// Output: {"type":"event","event":"actionToggleState","changes":[{"s":0,"c":40001,"v":1},...]}
    pub fn changesToJson(changes: *const std.AutoHashMap(u64, i8), buf: []u8) ?[]const u8 {
        if (changes.count() == 0) return null;

        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"actionToggleState\",\"changes\":[") catch return null;

        var first = true;
        var iter = changes.iterator();
        while (iter.next()) |entry| {
            if (!first) writer.writeAll(",") catch return null;
            first = false;

            const action_key = ActionKey.decode(entry.key_ptr.*);
            writer.print("{{\"s\":{d},\"c\":{d},\"v\":{d}}}", .{
                action_key.section_id,
                action_key.command_id,
                entry.value_ptr.*,
            }) catch return null;
        }

        writer.writeAll("]}") catch return null;

        return stream.getWritten();
    }

    /// Format states as JSON for subscribe response with structured array format.
    /// Output: [{"s":0,"c":40001,"v":1},...]
    pub fn statesToJson(states: *const std.AutoHashMap(u64, i8), buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        writer.writeAll("[") catch return null;

        var first = true;
        var iter = states.iterator();
        while (iter.next()) |entry| {
            if (!first) writer.writeAll(",") catch return null;
            first = false;

            const action_key = ActionKey.decode(entry.key_ptr.*);
            writer.print("{{\"s\":{d},\"c\":{d},\"v\":{d}}}", .{
                action_key.section_id,
                action_key.command_id,
                entry.value_ptr.*,
            }) catch return null;
        }

        writer.writeAll("]") catch return null;

        return stream.getWritten();
    }

    /// Allocator-based version of changesToJson - dynamically sized.
    /// Returns owned slice from allocator.
    pub fn changesToJsonAlloc(changes: *const std.AutoHashMap(u64, i8), allocator: std.mem.Allocator) ![]const u8 {
        if (changes.count() == 0) return error.NoChanges;
        // Estimate: ~30 bytes per entry ({"s":0,"c":40001,"v":1}) + 80 base overhead
        const estimated_size = 80 + (changes.count() * 30);
        const buf = try allocator.alloc(u8, estimated_size);
        const json = changesToJson(changes, buf) orelse return error.JsonSerializationFailed;
        return json; // Return slice of allocated buffer (arena-owned)
    }

    /// Allocator-based version of statesToJson - dynamically sized.
    /// Returns owned slice from allocator.
    pub fn statesToJsonAlloc(states: *const std.AutoHashMap(u64, i8), allocator: std.mem.Allocator) ![]const u8 {
        // Estimate: ~30 bytes per entry + 10 base overhead
        const estimated_size = 10 + (states.count() * 30);
        const buf = try allocator.alloc(u8, estimated_size);
        const json = statesToJson(states, buf) orelse return error.JsonSerializationFailed;
        return json; // Return slice of allocated buffer (arena-owned)
    }
};

// Tests
test "ActionKey encode/decode roundtrip" {
    const key1 = ActionKey.init(0, 40001);
    const encoded1 = key1.encode();
    const decoded1 = ActionKey.decode(encoded1);
    try std.testing.expectEqual(@as(i32, 0), decoded1.section_id);
    try std.testing.expectEqual(@as(u32, 40001), decoded1.command_id);

    // Test with non-zero section
    const key2 = ActionKey.init(32060, 12345);
    const encoded2 = key2.encode();
    const decoded2 = ActionKey.decode(encoded2);
    try std.testing.expectEqual(@as(i32, 32060), decoded2.section_id);
    try std.testing.expectEqual(@as(u32, 12345), decoded2.command_id);
}

test "subscribe and unsubscribe" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    // Can't test subscribe without a real REAPER API, but we can test unsubscribe logic
    // by manually adding entries
    const key = ActionKey.init(0, 100).encode();
    const slot = subs.getOrCreateSlot(1).?;
    try subs.client_subscriptions[slot].put(key, {});
    try subs.ref_counts.put(key, 1);
    try subs.prev_states.put(key, 1);

    try std.testing.expect(subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 1), subs.ref_counts.count());

    subs.unsubscribe(1, &[_]ActionKey{ActionKey.init(0, 100)});

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.ref_counts.count());
}

test "multiple clients same action key" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    // Simulate two clients subscribing to the same (sectionId, commandId)
    const key = ActionKey.init(0, 100).encode();
    const slot1 = subs.getOrCreateSlot(1).?;
    const slot2 = subs.getOrCreateSlot(2).?;

    try subs.client_subscriptions[slot1].put(key, {});
    try subs.client_subscriptions[slot2].put(key, {});
    try subs.ref_counts.put(key, 2);
    try subs.prev_states.put(key, 1);

    // First client unsubscribes - should still have 1 ref
    subs.unsubscribe(1, &[_]ActionKey{ActionKey.init(0, 100)});
    try std.testing.expectEqual(@as(u8, 1), subs.ref_counts.get(key).?);
    try std.testing.expect(subs.hasSubscriptions());

    // Second client unsubscribes - should remove entirely
    subs.unsubscribe(2, &[_]ActionKey{ActionKey.init(0, 100)});
    try std.testing.expect(!subs.hasSubscriptions());
}

test "same commandId different sections are distinct" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    // Same commandId (100) in two different sections should be tracked separately
    const key_main = ActionKey.init(0, 100).encode();
    const key_midi = ActionKey.init(32060, 100).encode();

    const slot = subs.getOrCreateSlot(1).?;
    try subs.client_subscriptions[slot].put(key_main, {});
    try subs.client_subscriptions[slot].put(key_midi, {});
    try subs.ref_counts.put(key_main, 1);
    try subs.ref_counts.put(key_midi, 1);
    try subs.prev_states.put(key_main, 0);
    try subs.prev_states.put(key_midi, 1);

    try std.testing.expectEqual(@as(usize, 2), subs.ref_counts.count());
    try std.testing.expect(key_main != key_midi); // Keys should be different

    // Unsubscribe from main section only
    subs.unsubscribe(1, &[_]ActionKey{ActionKey.init(0, 100)});
    try std.testing.expectEqual(@as(usize, 1), subs.ref_counts.count());
    try std.testing.expect(subs.ref_counts.contains(key_midi)); // MIDI section still subscribed
}

test "removeClient cleans up all subscriptions" {
    const allocator = std.testing.allocator;
    var subs = ToggleSubscriptions.init(allocator);
    defer subs.deinit();

    const key1 = ActionKey.init(0, 100).encode();
    const key2 = ActionKey.init(32060, 200).encode();
    const key3 = ActionKey.init(100, 300).encode();

    const slot = subs.getOrCreateSlot(1).?;
    try subs.client_subscriptions[slot].put(key1, {});
    try subs.client_subscriptions[slot].put(key2, {});
    try subs.client_subscriptions[slot].put(key3, {});
    try subs.ref_counts.put(key1, 1);
    try subs.ref_counts.put(key2, 1);
    try subs.ref_counts.put(key3, 1);
    try subs.prev_states.put(key1, 0);
    try subs.prev_states.put(key2, 1);
    try subs.prev_states.put(key3, -1);

    try std.testing.expectEqual(@as(usize, 3), subs.ref_counts.count());

    subs.removeClient(1);

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.ref_counts.count());
}

test "changesToJson formats correctly with structured array" {
    const allocator = std.testing.allocator;
    var changes = std.AutoHashMap(u64, i8).init(allocator);
    defer changes.deinit();

    // Single entry for predictable output
    const key = ActionKey.init(0, 40001).encode();
    try changes.put(key, 1);

    var buf: [256]u8 = undefined;
    const json = ToggleSubscriptions.changesToJson(&changes, &buf).?;

    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"actionToggleState\",\"changes\":[{\"s\":0,\"c\":40001,\"v\":1}]}",
        json,
    );
}

test "changesToJson with multiple sections" {
    const allocator = std.testing.allocator;
    var changes = std.AutoHashMap(u64, i8).init(allocator);
    defer changes.deinit();

    // Single entry with non-zero section
    const key = ActionKey.init(32060, 12345).encode();
    try changes.put(key, 0);

    var buf: [256]u8 = undefined;
    const json = ToggleSubscriptions.changesToJson(&changes, &buf).?;

    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"actionToggleState\",\"changes\":[{\"s\":32060,\"c\":12345,\"v\":0}]}",
        json,
    );
}

test "statesToJson formats correctly with structured array" {
    const allocator = std.testing.allocator;
    var states = std.AutoHashMap(u64, i8).init(allocator);
    defer states.deinit();

    const key = ActionKey.init(0, 100).encode();
    try states.put(key, 1);

    var buf: [64]u8 = undefined;
    const json = ToggleSubscriptions.statesToJson(&states, &buf).?;

    try std.testing.expectEqualStrings("[{\"s\":0,\"c\":100,\"v\":1}]", json);
}
