/// Tuner Subscriptions - Per-client subscription for chromatic tuner functionality.
///
/// Two sources, both shared by every client tuning them:
/// - a track: **per-track reference counting** for a PitchDetect JSFX in the
///   track's input FX, inserted on the first subscriber, removed when the
///   last leaves;
/// - the master ("master"): REAmo's native analyser on the audio hook's
///   post-master output (master_tuner.zig), which puts nothing in REAPER.
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
const project = @import("../state/project.zig");
const audio_hook = @import("../audio/audio_hook.zig");
const master_tuner = @import("master_tuner.zig");

const Allocator = std.mem.Allocator;

pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const GUID_LEN = 40;
pub const MAX_TRACK_TUNERS = 32; // Max concurrent tuner tracks

/// Input FX index offset - all TrackFX_* calls for Input FX chain need this added to the index
pub const INPUT_FX_OFFSET: c_int = 0x1000000;

/// The tuner JSFX by its file name as installed, extension included: REAPER
/// 6 finds a JSFX only by its exact file name (REAPER 7 also without the
/// extension).
pub const TUNER_JSFX_NAME = "JS:REAmo/PitchDetect.jsfx";

/// Tuner parameter indices - CONTIGUOUS mapping from JSFX sliders
/// JSFX sliders with gaps (1-5, 10-11) map to contiguous param indices (0-6)
/// slider1→0, slider2→1, slider3→2, slider4→3, slider5→4, slider10→5, slider11→6
pub const TunerParam = enum(c_int) {
    frequency = 0, // Read: detected frequency (Hz) - slider1
    note = 1, // Read: MIDI note number - slider2
    cents = 2, // Read: cents deviation from note - slider3
    confidence = 3, // Read: detection confidence (0-1) - slider4
    reference = 4, // Write: A4 reference frequency (400-480) - slider5
    yin_threshold = 5, // slider10 (not used by frontend)
    threshold = 6, // Write: silence threshold (dB, -90 to -30) - slider11
};

/// Result from subscribe operation. The track name is held in the result
/// itself: it is read after subscribe() returns.
pub const SubscribeResult = struct {
    track_guid: []const u8,
    fx_guid: []const u8,
    track_name_buf: [256]u8 = undefined,
    track_name_len: usize = 0,
    reference_hz: f32,
    threshold_db: f32,

    pub fn trackName(self: *const SubscribeResult) []const u8 {
        return self.track_name_buf[0..self.track_name_len];
    }
};

/// Per-track tuner state (shared across clients subscribing to same track)
pub const TrackTuner = struct {
    track_guid: [GUID_LEN]u8 = undefined,
    track_guid_len: u8 = 0,
    fx_guid: [GUID_LEN]u8 = undefined,
    fx_guid_len: u8 = 0,
    fx_index: c_int = -1, // Raw index in Input FX chain (0, 1, 2...)
    ref_count: u8 = 0, // Number of clients subscribed to this track
    // The track and project tab (ReaProject*) the JSFX went into: the user
    // may have switched tabs by the time it comes out
    track: ?*anyopaque = null,
    project: ?*anyopaque = null,

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
    OutOfMemory,
    AudioHookFailed,
    ThreadFailed,
};

/// The GUID clients tune the master by.
pub const MASTER_GUID = "master";

pub fn isMaster(track_guid: []const u8) bool {
    return std.mem.eql(u8, track_guid, MASTER_GUID);
}

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

    /// The master's tuner, shared by every client tuning the master.
    master: master_tuner.MasterTuner = .{},
    /// The audio hook the master tuner reads.
    hook: *audio_hook.Hook,

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
            .hook = audio_hook.instance(),
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

        if (client.active) {
            // Already on this tuner (a page re-sending its subscribe): keep
            // it and its settings, rather than tearing down and re-inserting
            // a JSFX or resetting the master's analyser.
            if (client.getTrackGuid()) |current| if (std.mem.eql(u8, current, track_guid)) {
                if (isMaster(track_guid)) {
                    self.activate(slot, MASTER_GUID);
                    return self.masterResult(api);
                }
                if (self.findTrackTuner(track_guid)) |tuner| if (guid_cache.resolve(api, track_guid)) |track| {
                    self.activate(slot, track_guid);
                    return trackResult(tuner, track, api);
                };
            };
            // Otherwise leave the previous tuner first.
            self.unsubscribeInternal(client_id, slot, api);
        }

        if (isMaster(track_guid)) return self.subscribeMaster(slot, api);

        // Resolve track GUID to track pointer
        const track = guid_cache.resolve(api, track_guid) orelse return error.TrackNotFound;

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

            tuner.?.track = track;
            tuner.?.project = project.Identity.current(api).pointer;
            tuner.?.fx_index = 0; // Always at position 0 after move
            tuner.?.ref_count = 0;
            tuner.?.reference_hz = 440.0;
            tuner.?.silence_threshold = -60.0;

            logging.info("tuner: inserted JSFX for track {s} at Input FX index 0", .{track_guid});
        }

        // Increment ref count
        tuner.?.ref_count += 1;

        self.activate(slot, track_guid);
        logging.debug("tuner: client {d} subscribed to track {s} (ref_count={d})", .{ client_id, track_guid, tuner.?.ref_count });
        return trackResult(tuner.?, track, api);
    }

    fn trackResult(tuner: *const TrackTuner, track: *anyopaque, api: anytype) SubscribeResult {
        var result = SubscribeResult{
            .track_guid = tuner.getTrackGuid(),
            .fx_guid = tuner.getFxGuid(),
            .reference_hz = tuner.reference_hz,
            .threshold_db = tuner.silence_threshold,
        };
        result.track_name_len = api.getTrackNameStr(track, &result.track_name_buf).len;
        return result;
    }

    /// Record a client's subscription and have its first poll broadcast.
    fn activate(self: *TunerSubscriptions, slot: usize, track_guid: []const u8) void {
        const client = &self.clients[slot];
        client.active = true;
        const len: u8 = @intCast(@min(track_guid.len, GUID_LEN));
        @memcpy(client.track_guid[0..len], track_guid[0..len]);
        client.track_guid_len = len;
        client.consecutive_failures = 0;
        self.force_broadcast_clients[slot] = true;
        self.prev_hash[slot] = 0;
    }

    /// Subscribe a client to the master's tuner, opening it for the first.
    fn subscribeMaster(self: *TunerSubscriptions, slot: usize, api: anytype) SubscribeError!SubscribeResult {
        try self.master.open(self.allocator, self.hook, api);
        if (self.master.subscribers == 1) logging.info("tuner: master tuner opened on the audio hook", .{});
        self.activate(slot, MASTER_GUID);
        return self.masterResult(api);
    }

    fn masterResult(self: *TunerSubscriptions, api: anytype) SubscribeResult {
        const settings = self.master.snapshot().settings;
        var result = SubscribeResult{
            .track_guid = MASTER_GUID,
            .fx_guid = "",
            .reference_hz = @floatCast(settings.reference_hz),
            .threshold_db = @floatCast(settings.silence_db),
        };
        if (api.masterTrack()) |master| result.track_name_len = api.getTrackNameStr(master, &result.track_name_buf).len;
        return result;
    }

    /// The track a track tuner's JSFX went into, checked against the tab it
    /// went into, which needn't be the tab shown now. null once the track or
    /// its tab is gone. Found by pointer, not GUID: REAPER 6.0's
    /// GetTrackGUID gives nothing for a track in a background tab. A stale
    /// pointer reused by another track is harmless: the JSFX is deleted only
    /// where its own FX GUID is found.
    fn findTrack(api: anytype, tuner: *const TrackTuner) ?*anyopaque {
        const track = tuner.track orelse return null;
        if (tuner.project != null and !api.validateProjectPtr(tuner.project)) return null;
        if (!api.validateTrackPtrIn(tuner.project, track)) return null;
        return track;
    }

    /// Internal unsubscribe (doesn't remove client from map)
    fn unsubscribeInternal(self: *TunerSubscriptions, client_id: usize, slot: usize, api: anytype) void {
        const client = &self.clients[slot];
        if (!client.active) return;

        const track_guid = client.getTrackGuid() orelse return;

        if (isMaster(track_guid)) {
            self.master.close(self.allocator, self.hook, api);
            if (!self.master.isOpen()) logging.info("tuner: master tuner closed (last subscriber)", .{});
        } else if (self.findTrackTuner(track_guid)) |tuner| {
            tuner.ref_count -= 1;

            if (tuner.ref_count == 0) {
                // Last subscriber - remove JSFX
                // Note: We need to resolve track first, but it might be gone
                // In that case, the JSFX is already gone with the track
                logging.info("tuner: removing JSFX for track {s} (last subscriber)", .{track_guid});

                const stored_fx_guid = tuner.getFxGuid();

                // Delete the JSFX if the track still exists (deleting a track
                // takes its FX with it). Search all of its Input FX by GUID, in
                // case the user has reordered the chain.
                if (findTrack(api, tuner)) |track| {
                    const input_fx_count = api.trackFxRecCount(track);
                    var found = false;
                    var fx_idx: c_int = 0;
                    while (fx_idx < input_fx_count) : (fx_idx += 1) {
                        var fx_guid_buf: [64]u8 = undefined;
                        const api_fx_idx = fx_idx + INPUT_FX_OFFSET;
                        const current_fx_guid = api.trackFxGetGuid(track, api_fx_idx, &fx_guid_buf);

                        if (current_fx_guid.len > 0 and std.mem.eql(u8, current_fx_guid, stored_fx_guid)) {
                            if (api.trackFxDelete(track, api_fx_idx)) {
                                logging.debug("tuner: deleted JSFX from track {s} at Input FX position {d}", .{ track_guid, fx_idx });
                            } else {
                                logging.warn("tuner: REAPER wouldn't remove the tuner JSFX from track {s}; it stays in the Input FX chain", .{track_guid});
                            }
                            found = true;
                            break;
                        }
                    }
                    // The user may have deleted it by hand.
                    if (!found) logging.warn("tuner: JSFX with GUID {s} not found in Input FX chain on track {s}", .{
                        stored_fx_guid,
                        track_guid,
                    });
                }

                // Clean up our state
                tuner.track_guid_len = 0;
                tuner.fx_guid_len = 0;
                tuner.fx_index = -1;
                tuner.track = null;
                tuner.project = null;
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

    /// Remove all clients, cleaning up all JSFXs and closing the master
    /// tuner (called on shutdown).
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
    /// Searches for FX by GUID to handle user reordering the FX chain.
    pub fn setParam(
        self: *TunerSubscriptions,
        track_guid: []const u8,
        param: TunerParam,
        value: f32,
        guid_cache: anytype,
        api: anytype,
    ) !void {
        if (isMaster(track_guid)) {
            if (!self.master.isOpen()) return error.NotSubscribed;
            switch (param) {
                .reference => self.master.setReference(value),
                .threshold => self.master.setSilenceDb(value),
                else => return error.InvalidParam,
            }
            return;
        }
        const tuner = self.findTrackTuner(track_guid) orelse return error.NotSubscribed;
        const track = guid_cache.resolve(api, track_guid) orelse return error.TrackNotFound;

        // Search Input FX chain by GUID to find current index
        // This handles when user has reordered the FX chain - CRITICAL for safety
        const stored_fx_guid = tuner.getFxGuid();
        const input_fx_count = api.trackFxRecCount(track);
        var api_fx_idx: c_int = -1;
        var fx_idx: c_int = 0;
        while (fx_idx < input_fx_count) : (fx_idx += 1) {
            var guid_buf: [64]u8 = undefined;
            const current_guid = api.trackFxGetGuid(track, fx_idx + INPUT_FX_OFFSET, &guid_buf);
            if (current_guid.len > 0 and std.mem.eql(u8, current_guid, stored_fx_guid)) {
                api_fx_idx = fx_idx + INPUT_FX_OFFSET;
                break;
            }
        }

        if (api_fx_idx < 0) {
            logging.debug("tuner: setParam failed - FX GUID not found in Input FX chain", .{});
            return error.FxNotFound;
        }

        switch (param) {
            .reference => {
                tuner.reference_hz = value;
                // JSFX slider5: 400-480 Hz range → normalize to 0-1
                _ = api.trackFxSetParamNormalized(track, api_fx_idx, @intFromEnum(TunerParam.reference), (@as(f64, value) - 400.0) / 80.0);
            },
            .threshold => {
                tuner.silence_threshold = value;
                // JSFX slider11: -90 to -30 dB range → normalize to 0-1
                _ = api.trackFxSetParamNormalized(track, api_fx_idx, @intFromEnum(TunerParam.threshold), (@as(f64, value) + 90.0) / 60.0);
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

// -----------------------------------------------------------------------------
// The master tuner's lifecycle through the subscriptions
// -----------------------------------------------------------------------------

const MockBackend = @import("../reaper/mock/mod.zig").MockBackend;

/// A GUID cache that knows no track: the master path never asks it.
const NoTracks = struct {
    fn resolve(_: *const NoTracks, _: anytype, _: []const u8) ?*anyopaque {
        return null;
    }
};

const MasterRig = struct {
    subs: TunerSubscriptions,
    hook: *audio_hook.Hook,
    api: MockBackend = .{},
    cache: NoTracks = .{},

    fn init(self: *MasterRig) !void {
        self.hook = try std.testing.allocator.create(audio_hook.Hook);
        self.hook.* = .{};
        self.subs = TunerSubscriptions.init(std.testing.allocator);
        self.subs.hook = self.hook;
        self.api = .{};
        self.api.tracks[0].setName("MASTER");
    }

    fn deinit(self: *MasterRig) void {
        self.subs.removeAllClients(&self.api);
        self.subs.deinit();
        std.testing.allocator.destroy(self.hook);
    }

    fn sub(self: *MasterRig, client: usize) !SubscribeResult {
        return self.subs.subscribe(client, MASTER_GUID, &self.cache, &self.api);
    }
};

test "the master tuner opens on the audio hook, with no plugin, and closes with its last phone" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    const r = try rig.sub(1);
    try std.testing.expectEqualStrings("master", r.track_guid);
    try std.testing.expectEqualStrings("", r.fx_guid);
    try std.testing.expectEqualStrings("MASTER", r.trackName());
    try std.testing.expectEqual(@as(f32, 440), r.reference_hz);
    try std.testing.expectEqual(@as(f32, -90), r.threshold_db);
    try std.testing.expect(rig.hook.holds(.tuner));
    try std.testing.expectEqual(@as(usize, 0), rig.api.getCallCount(.trackFxAddByName));
    try std.testing.expect(rig.subs.hasSubscriptions());

    rig.subs.unsubscribe(1, &rig.api);
    try std.testing.expect(!rig.subs.master.isOpen());
    try std.testing.expect(!rig.hook.registered);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_unregisters);
}

test "reopening the master tuner takes the hook again and starts from the defaults" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.sub(1);
    try rig.subs.setParam(MASTER_GUID, .reference, 442, &rig.cache, &rig.api);
    rig.subs.unsubscribe(1, &rig.api);
    const r = try rig.sub(1);
    try std.testing.expectEqual(@as(f32, 440), r.reference_hz);
    try std.testing.expectEqual(@as(u32, 2), rig.api.audio_hook_registers);
    try std.testing.expect(rig.hook.registered);
}

test "two phones on the master share it; it stays open until both leave" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.sub(1);
    _ = try rig.sub(2);
    try std.testing.expectEqual(@as(u8, 2), rig.subs.master.subscribers);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_registers);
    try rig.subs.setParam(MASTER_GUID, .threshold, -50, &rig.cache, &rig.api);
    try std.testing.expectEqual(@as(f64, -50), rig.subs.master.settings.silence_db);

    // Phone 1 subscribing again to the master is a resubscribe, not a third phone.
    _ = try rig.sub(1);
    try std.testing.expectEqual(@as(u8, 2), rig.subs.master.subscribers);

    rig.subs.removeClient(1, &rig.api); // phone 1's connection drops
    try std.testing.expect(rig.subs.master.isOpen() and rig.hook.holds(.tuner));
    try std.testing.expectEqual(@as(f64, -50), rig.subs.master.settings.silence_db);
    rig.subs.unsubscribe(2, &rig.api);
    try std.testing.expect(!rig.subs.master.isOpen() and !rig.hook.registered);
}

test "a phone leaving the master for a track closes the master tuner even if the track can't be tuned" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.sub(1);
    try std.testing.expectError(error.TrackNotFound, rig.subs.subscribe(1, "{NO-SUCH-TRACK}", &rig.cache, &rig.api));
    try std.testing.expect(!rig.subs.master.isOpen() and !rig.hook.registered);
}

test "the master tuner and the stream hold one registration between them" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    try std.testing.expect(rig.hook.acquire(&rig.api, .stream)); // a phone listens
    _ = try rig.sub(1);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_registers);
    rig.hook.release(&rig.api, .stream); // it stops listening
    try std.testing.expect(rig.hook.registered and rig.hook.holds(.tuner));
    try std.testing.expect(rig.hook.acquire(&rig.api, .stream));
    rig.subs.unsubscribe(1, &rig.api);
    try std.testing.expect(rig.hook.registered and rig.hook.holds(.stream));
    rig.hook.release(&rig.api, .stream);
    try std.testing.expect(!rig.hook.registered);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_registers);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_unregisters);
}

test "a refused audio hook fails the subscribe and leaves nothing open" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    rig.api.audio_hook_refuse = true;
    try std.testing.expectError(error.AudioHookFailed, rig.sub(1));
    try std.testing.expect(!rig.subs.master.isOpen());
    try std.testing.expect(!rig.subs.hasSubscriptions());
}

test "setParam on the master before anyone tunes it is refused" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();
    try std.testing.expectError(error.NotSubscribed, rig.subs.setParam(MASTER_GUID, .reference, 442, &rig.cache, &rig.api));
}

test "a phone subscribing again to the master it is on keeps the tuner and its settings" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.sub(1);
    try rig.subs.setParam(MASTER_GUID, .reference, 442, &rig.cache, &rig.api);
    const analysis = rig.subs.master.analysis;
    const r = try rig.sub(1); // the page re-sends its subscribe, e.g. after a re-render
    try std.testing.expectEqual(@as(f32, 442), r.reference_hz);
    try std.testing.expectEqual(analysis, rig.subs.master.analysis);
    try std.testing.expectEqual(@as(u8, 1), rig.subs.master.subscribers);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_registers);
    try std.testing.expectEqual(@as(u32, 0), rig.api.audio_hook_unregisters);
}

/// A GUID cache that knows one track, "{T1}", the mock's track 1.
const OneTrack = struct {
    fn resolve(_: *const OneTrack, api: anytype, guid: []const u8) ?*anyopaque {
        if (isMaster(guid)) return api.masterTrack();
        return if (std.mem.eql(u8, guid, "{T1}")) @import("../reaper/mock/state.zig").encodeTrackPtr(1) else null;
    }
};

test "a phone subscribing again to the track it is on keeps the JSFX instead of re-inserting it" {
    var api = MockBackend{ .track_count = 1 };
    api.tracks[1].setName("Guitar");
    var subs = TunerSubscriptions.init(std.testing.allocator);
    defer subs.deinit();
    const cache = OneTrack{};

    const first = try subs.subscribe(1, "{T1}", &cache, &api);
    const fx_guid = first.fx_guid;
    const again = try subs.subscribe(1, "{T1}", &cache, &api);
    try std.testing.expectEqualStrings(fx_guid, again.fx_guid);
    try std.testing.expectEqualStrings("Guitar", again.trackName());
    try std.testing.expectEqual(@as(usize, 1), api.getCallCount(.trackFxAddByName));
    try std.testing.expectEqual(@as(usize, 0), api.getCallCount(.trackFxDelete));
    try std.testing.expectEqual(@as(u8, 1), subs.getTrackTuner("{T1}").?.ref_count);
    subs.removeAllClients(&api);
}
