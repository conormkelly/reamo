/// Tuner Subscriptions - Per-client subscription for chromatic tuner functionality.
///
/// Key difference from other subscriptions: **per-track reference counting** for JSFX lifecycle.
/// Multiple clients can subscribe to the same track's tuner, sharing a single JSFX instance.
/// JSFX is inserted on first subscriber, removed when last subscriber leaves.
///
/// Usage:
///   var subs = TunerSubscriptions.init(allocator);
///   defer subs.deinit();
///   const result = try subs.subscribe(client_id, "{track-guid}", api);
///   // ... tuner events broadcast at 30Hz ...
///   subs.unsubscribe(client_id, api);
const std = @import("std");
const logging = @import("../core/logging.zig");
const constants = @import("../core/constants.zig");

const Allocator = std.mem.Allocator;

pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const GUID_LEN = 40;
pub const MAX_TRACK_TUNERS = 32; // Max concurrent tuner tracks

/// Input FX index offset - all TrackFX_* calls for Input FX chain need this added to the index
pub const INPUT_FX_OFFSET: c_int = 0x1000000;

/// JSFX identifier for the tuner plugin
pub const TUNER_JSFX_NAME = "JS:REAmo/PitchDetect";

/// Tuner parameter indices (slider numbers in JSFX)
pub const TunerParam = enum(c_int) {
    frequency = 0, // Read: detected frequency (Hz)
    note = 1, // Read: MIDI note number
    cents = 2, // Read: cents deviation from note
    confidence = 3, // Read: detection confidence (0-1)
    reference = 4, // Write: A4 reference frequency
    threshold = 5, // Write: silence threshold (dB)
};

/// Result from subscribe operation
pub const SubscribeResult = struct {
    track_guid: []const u8,
    fx_guid: []const u8,
    track_name: []const u8,
    reference_hz: f32,
    threshold_db: f32,
};

/// Per-track tuner state (shared across clients subscribing to same track)
pub const TrackTuner = struct {
    track_guid: [GUID_LEN]u8 = undefined,
    track_guid_len: u8 = 0,
    fx_guid: [GUID_LEN]u8 = undefined,
    fx_guid_len: u8 = 0,
    fx_index: c_int = -1, // Raw index in Input FX chain (0, 1, 2...)
    ref_count: u8 = 0, // Number of clients subscribed to this track

    // Configurable params (shared across subscribers to this track)
    reference_hz: f32 = 440.0, // A4 reference frequency
    silence_threshold: f32 = -60.0, // dB threshold for "no signal"

    /// Get the FX index for use with TrackFX_* API calls
    pub fn getApiFxIndex(self: *const TrackTuner) c_int {
        return self.fx_index + INPUT_FX_OFFSET;
    }

    pub fn getTrackGuid(self: *const TrackTuner) []const u8 {
        return self.track_guid[0..self.track_guid_len];
    }

    pub fn getFxGuid(self: *const TrackTuner) []const u8 {
        return self.fx_guid[0..self.fx_guid_len];
    }
};

/// Per-client subscription (which track they're subscribed to)
pub const ClientSubscription = struct {
    active: bool = false,
    track_guid: [GUID_LEN]u8 = undefined,
    track_guid_len: u8 = 0,
    consecutive_failures: u8 = 0, // Auto-unsub after 3 failures

    pub fn getTrackGuid(self: *const ClientSubscription) ?[]const u8 {
        if (!self.active or self.track_guid_len == 0) return null;
        return self.track_guid[0..self.track_guid_len];
    }

    pub fn clear(self: *ClientSubscription) void {
        self.active = false;
        self.track_guid_len = 0;
        self.consecutive_failures = 0;
    }
};

/// Subscription errors
pub const SubscribeError = error{
    TooManyClients,
    TrackNotFound,
    FxInsertFailed,
    TooManyTuners,
};

pub const TunerSubscriptions = struct {
    allocator: Allocator,

    /// Per-client subscriptions (slot-based storage)
    clients: [MAX_CLIENTS]ClientSubscription,

    /// Map from client_id to slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Per-track tuner state (keyed by track GUID)
    /// Using fixed array instead of HashMap for simplicity
    track_tuners: [MAX_TRACK_TUNERS]TrackTuner,
    track_tuner_count: usize,

    /// Previous state hash per client (for change detection)
    prev_hash: [MAX_CLIENTS]u64,

    /// Force broadcast flag per client (set on subscribe)
    force_broadcast_clients: [MAX_CLIENTS]bool,

    /// Free list for slot recycling
    free_slots: [MAX_CLIENTS]usize,
    free_count: usize,

    /// Next available slot
    next_slot: usize,

    pub fn init(allocator: Allocator) TunerSubscriptions {
        var subs = TunerSubscriptions{
            .allocator = allocator,
            .clients = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .track_tuners = undefined,
            .track_tuner_count = 0,
            .prev_hash = [_]u64{0} ** MAX_CLIENTS,
            .force_broadcast_clients = [_]bool{false} ** MAX_CLIENTS,
            .free_slots = undefined,
            .free_count = 0,
            .next_slot = 0,
        };

        // Initialize all client slots
        for (&subs.clients) |*client| {
            client.* = ClientSubscription{};
        }

        // Initialize all track tuner slots
        for (&subs.track_tuners) |*tuner| {
            tuner.* = TrackTuner{};
        }

        return subs;
    }

    pub fn deinit(self: *TunerSubscriptions) void {
        self.client_id_to_slot.deinit();
    }

    /// Get or create a slot for a client.
    fn getOrCreateSlot(self: *TunerSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Try to reuse a freed slot first
        if (self.free_count > 0) {
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            self.client_id_to_slot.put(client_id, slot) catch |e| {
                logging.warn("tuner_subscriptions: slot reuse failed for client {d}: {}", .{ client_id, e });
                return null;
            };
            return slot;
        }

        // Allocate a new slot if available
        if (self.next_slot >= MAX_CLIENTS) {
            return null;
        }

        const slot = self.next_slot;
        self.next_slot += 1;
        self.client_id_to_slot.put(client_id, slot) catch |e| {
            logging.warn("tuner_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return null;
        };
        return slot;
    }

    /// Find a track tuner by GUID
    fn findTrackTuner(self: *TunerSubscriptions, track_guid: []const u8) ?*TrackTuner {
        // Search all slots - ref_count > 0 check filters out unused ones
        for (&self.track_tuners) |*tuner| {
            if (tuner.ref_count > 0 and std.mem.eql(u8, tuner.getTrackGuid(), track_guid)) {
                return tuner;
            }
        }
        return null;
    }

    /// Find or create a track tuner slot
    fn getOrCreateTrackTuner(self: *TunerSubscriptions) ?*TrackTuner {
        // First, look for an empty slot (ref_count == 0)
        for (&self.track_tuners) |*tuner| {
            if (tuner.ref_count == 0) {
                return tuner;
            }
        }

        // If no empty slot, expand if possible
        if (self.track_tuner_count < MAX_TRACK_TUNERS) {
            const tuner = &self.track_tuners[self.track_tuner_count];
            self.track_tuner_count += 1;
            return tuner;
        }

        return null;
    }

    /// Subscribe to tuner on a track.
    /// Inserts JSFX if first subscriber to this track.
    /// Returns subscribe result with track info.
    pub fn subscribe(
        self: *TunerSubscriptions,
        client_id: usize,
        track_guid: []const u8,
        guid_cache: anytype,
        api: anytype,
    ) SubscribeError!SubscribeResult {
        // Get or create client slot
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        // If client was previously subscribed to a different track, unsubscribe first
        if (client.active) {
            self.unsubscribeInternal(client_id, slot, api);
        }

        // Resolve track GUID to track pointer
        const track = guid_cache.resolve(track_guid) orelse return error.TrackNotFound;

        // Check if there's already a tuner for this track
        var tuner = self.findTrackTuner(track_guid);

        if (tuner == null) {
            // Need to insert new JSFX
            tuner = self.getOrCreateTrackTuner() orelse return error.TooManyTuners;

            // Insert JSFX into Input FX chain at end (position -1)
            // Note: position 0 doesn't work for Input FX in REAPER's API
            const fx_idx = api.trackFxAddByName(track, TUNER_JSFX_NAME, true, -1);
            if (fx_idx < 0) {
                return error.FxInsertFailed;
            }

            // Get FX GUID before moving (GUID stays the same after move)
            var guid_buf: [64]u8 = undefined;
            const fx_guid = api.trackFxGetGuid(track, fx_idx + INPUT_FX_OFFSET, &guid_buf);
            const fx_len: u8 = @intCast(@min(fx_guid.len, GUID_LEN));
            @memcpy(tuner.?.fx_guid[0..fx_len], fx_guid[0..fx_len]);
            tuner.?.fx_guid_len = fx_len;

            // Move to position 0 (first in chain) so tuner sees raw input
            // If already at 0, this is a no-op
            api.trackFxCopyToTrack(track, fx_idx + INPUT_FX_OFFSET, track, 0 + INPUT_FX_OFFSET, true);

            // Store track GUID
            const track_len: u8 = @intCast(@min(track_guid.len, GUID_LEN));
            @memcpy(tuner.?.track_guid[0..track_len], track_guid[0..track_len]);
            tuner.?.track_guid_len = track_len;

            tuner.?.fx_index = 0; // Always at position 0 after move
            tuner.?.ref_count = 0;
            tuner.?.reference_hz = 440.0;
            tuner.?.silence_threshold = -60.0;

            logging.info("tuner: inserted JSFX for track {s} at Input FX index 0", .{track_guid});
        }

        // Increment ref count
        tuner.?.ref_count += 1;

        // Store client subscription
        client.active = true;
        const client_guid_len: u8 = @intCast(@min(track_guid.len, GUID_LEN));
        @memcpy(client.track_guid[0..client_guid_len], track_guid[0..client_guid_len]);
        client.track_guid_len = client_guid_len;
        client.consecutive_failures = 0;

        // Force broadcast on new subscription
        self.force_broadcast_clients[slot] = true;
        self.prev_hash[slot] = 0;

        // Get track name for response
        var name_buf: [256]u8 = undefined;
        const track_name = api.getTrackNameStr(track, &name_buf);

        logging.debug("tuner: client {d} subscribed to track {s} (ref_count={d})", .{ client_id, track_guid, tuner.?.ref_count });

        return SubscribeResult{
            .track_guid = tuner.?.getTrackGuid(),
            .fx_guid = tuner.?.getFxGuid(),
            .track_name = track_name,
            .reference_hz = tuner.?.reference_hz,
            .threshold_db = tuner.?.silence_threshold,
        };
    }

    /// Internal unsubscribe (doesn't remove client from map)
    fn unsubscribeInternal(self: *TunerSubscriptions, client_id: usize, slot: usize, api: anytype) void {
        const client = &self.clients[slot];
        if (!client.active) return;

        const track_guid = client.getTrackGuid() orelse return;

        // Find the track tuner
        if (self.findTrackTuner(track_guid)) |tuner| {
            tuner.ref_count -= 1;

            if (tuner.ref_count == 0) {
                // Last subscriber - remove JSFX
                // Note: We need to resolve track first, but it might be gone
                // In that case, the JSFX is already gone with the track
                logging.info("tuner: removing JSFX for track {s} (last subscriber)", .{track_guid});

                const stored_fx_guid = tuner.getFxGuid();

                // Try to delete the JSFX if track still exists
                // We iterate through tracks to find the one with matching GUID
                const track_count = api.trackCount();
                var i: c_int = 0;
                track_loop: while (i <= track_count) : (i += 1) {
                    if (api.getTrackByIdx(i)) |track| {
                        var guid_buf: [64]u8 = undefined;
                        const this_guid = api.formatTrackGuid(track, &guid_buf);
                        if (std.mem.eql(u8, this_guid, track_guid)) {
                            // Found the track - search ALL Input FX by GUID
                            // This handles when user has reordered the FX chain
                            const input_fx_count = api.trackFxRecCount(track);

                            var fx_idx: c_int = 0;
                            while (fx_idx < input_fx_count) : (fx_idx += 1) {
                                var fx_guid_buf: [64]u8 = undefined;
                                const api_fx_idx = fx_idx + INPUT_FX_OFFSET;
                                const current_fx_guid = api.trackFxGetGuid(track, api_fx_idx, &fx_guid_buf);

                                if (current_fx_guid.len > 0 and std.mem.eql(u8, current_fx_guid, stored_fx_guid)) {
                                    // Found our JSFX - delete it
                                    _ = api.trackFxDelete(track, api_fx_idx);
                                    logging.info("tuner: deleted JSFX from track {s} at Input FX position {d}", .{ track_guid, fx_idx });
                                    break :track_loop;
                                }
                            }

                            // If we get here, the FX was not found in the Input FX chain
                            // User might have manually deleted it - just log and continue
                            logging.warn("tuner: JSFX with GUID {s} not found in Input FX chain on track {s}", .{
                                stored_fx_guid,
                                track_guid,
                            });
                            break :track_loop;
                        }
                    }
                }

                // Clean up our state
                tuner.track_guid_len = 0;
                tuner.fx_guid_len = 0;
                tuner.fx_index = -1;
            }
        }

        client.clear();
        self.prev_hash[slot] = 0;

        logging.debug("tuner: client {d} unsubscribed", .{client_id});
    }

    /// Unsubscribe a client from their current tuner.
    /// Removes JSFX if this was the last subscriber.
    pub fn unsubscribe(self: *TunerSubscriptions, client_id: usize, api: anytype) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        self.unsubscribeInternal(client_id, slot, api);
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *TunerSubscriptions, client_id: usize, api: anytype) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;

        // Unsubscribe first (handles JSFX cleanup)
        self.unsubscribeInternal(client_id, slot, api);

        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        logging.debug("tuner: client {d} removed", .{client_id});
    }

    /// Remove all clients and clean up all JSFXs (called on shutdown).
    pub fn removeAllClients(self: *TunerSubscriptions, api: anytype) void {
        // Collect all client IDs first (can't iterate and modify)
        var client_ids: [MAX_CLIENTS]usize = undefined;
        var count: usize = 0;

        var key_iter = self.client_id_to_slot.keyIterator();
        while (key_iter.next()) |client_id_ptr| {
            if (count < MAX_CLIENTS) {
                client_ids[count] = client_id_ptr.*;
                count += 1;
            }
        }

        // Now remove each client
        for (client_ids[0..count]) |client_id| {
            self.removeClient(client_id, api);
        }
    }

    /// Set a tuner parameter (reference or threshold).
    pub fn setParam(
        self: *TunerSubscriptions,
        track_guid: []const u8,
        param: TunerParam,
        value: f32,
        guid_cache: anytype,
        api: anytype,
    ) !void {
        const tuner = self.findTrackTuner(track_guid) orelse return error.NotSubscribed;
        const track = guid_cache.resolve(track_guid) orelse return error.TrackNotFound;

        switch (param) {
            .reference => {
                tuner.reference_hz = value;
                _ = api.trackFxSetParamNormalized(track, tuner.getApiFxIndex(), @intFromEnum(TunerParam.reference), @as(f64, value) / 480.0); // Normalize to 0-1 range assuming 400-480 range
            },
            .threshold => {
                tuner.silence_threshold = value;
                _ = api.trackFxSetParamNormalized(track, tuner.getApiFxIndex(), @intFromEnum(TunerParam.threshold), (@as(f64, value) + 96.0) / 96.0); // Normalize -96..0 to 0..1
            },
            else => return error.InvalidParam,
        }
    }

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const TunerSubscriptions) bool {
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) return true;
        }
        return false;
    }

    /// Get track tuner for a subscription
    pub fn getTrackTuner(self: *TunerSubscriptions, track_guid: []const u8) ?*TrackTuner {
        return self.findTrackTuner(track_guid);
    }

    /// Check if data changed by comparing hash. Returns true if changed (or force broadcast).
    pub fn checkChanged(self: *TunerSubscriptions, slot: usize, data_hash: u64) bool {
        if (slot >= MAX_CLIENTS) return false;

        // Force broadcast always triggers change
        if (self.force_broadcast_clients[slot]) {
            self.force_broadcast_clients[slot] = false;
            self.prev_hash[slot] = data_hash;
            return true;
        }

        // Compare with previous
        if (self.prev_hash[slot] != data_hash) {
            self.prev_hash[slot] = data_hash;
            return true;
        }

        return false;
    }

    /// Increment consecutive failure count for a client.
    /// Returns true if auto-unsubscribe threshold reached (3 failures).
    pub fn recordFailure(self: *TunerSubscriptions, client_id: usize) bool {
        const slot = self.client_id_to_slot.get(client_id) orelse return false;
        const client = &self.clients[slot];
        if (!client.active) return false;

        client.consecutive_failures += 1;
        return client.consecutive_failures >= 3;
    }

    /// Reset failure count (called on successful resolution).
    pub fn resetFailures(self: *TunerSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.consecutive_failures = 0;
    }

    /// Iterator for processing subscriptions.
    pub const SubscriptionIterator = struct {
        subs: *TunerSubscriptions,
        key_iter: std.AutoHashMap(usize, usize).KeyIterator,

        pub const Entry = struct {
            client_id: usize,
            slot: usize,
            track_guid: []const u8,
        };

        pub fn next(self_iter: *SubscriptionIterator) ?Entry {
            while (self_iter.key_iter.next()) |client_id| {
                const slot = self_iter.subs.client_id_to_slot.get(client_id.*) orelse continue;
                const client = &self_iter.subs.clients[slot];
                if (client.active) {
                    const track_guid = client.getTrackGuid() orelse continue;
                    return Entry{
                        .client_id = client_id.*,
                        .slot = slot,
                        .track_guid = track_guid,
                    };
                }
            }
            return null;
        }
    };

    /// Get an iterator over active subscriptions.
    pub fn activeSubscriptions(self: *TunerSubscriptions) SubscriptionIterator {
        return .{
            .subs = self,
            .key_iter = self.client_id_to_slot.keyIterator(),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TunerSubscriptions init and deinit" {
    const allocator = std.testing.allocator;
    var subs = TunerSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscriptions());
}

test "INPUT_FX_OFFSET constant" {
    try std.testing.expectEqual(@as(c_int, 0x1000000), INPUT_FX_OFFSET);
}

test "TrackTuner.getApiFxIndex adds offset" {
    var tuner = TrackTuner{};
    tuner.fx_index = 0;
    try std.testing.expectEqual(@as(c_int, 0x1000000), tuner.getApiFxIndex());

    tuner.fx_index = 2;
    try std.testing.expectEqual(@as(c_int, 0x1000002), tuner.getApiFxIndex());
}

test "ClientSubscription clear" {
    var client = ClientSubscription{};
    client.active = true;
    client.track_guid_len = 10;
    client.consecutive_failures = 5;

    client.clear();

    try std.testing.expect(!client.active);
    try std.testing.expectEqual(@as(u8, 0), client.track_guid_len);
    try std.testing.expectEqual(@as(u8, 0), client.consecutive_failures);
}
