/// Tuner Subscriptions - Per-client subscription for chromatic tuner functionality.
///
/// Each phone tunes one source at a time, independent of the other phones;
/// phones on the same source share its analyser and its settings:
/// - a track: REAmo's native analyser on the hardware input the track's
///   record input names (input_tuners.zig), armed or not, shared by every
///   phone tuning a track on that input. Each poll checks the track's
///   record input again, and a phone follows its track to a new input;
/// - the master ("master"): the same analyser on the audio hook's
///   post-master output (master_tuner.zig).
/// Neither puts anything in REAPER: no FX, no undo point, no project change.
///
/// Usage:
///   var subs = TunerSubscriptions.init(allocator);
///   defer subs.deinit();
///   const result = try subs.subscribe(client_id, "{track-guid}", guid_cache, api);
///   // ... tuner events: each change at once (30 Hz polls), a reading
///   // that holds again every resend_interval_ms ...
///   subs.unsubscribe(client_id, api);
const std = @import("std");
const logging = @import("../core/logging.zig");
const constants = @import("../core/constants.zig");
const audio_hook = @import("../audio/audio_hook.zig");
const master_tuner = @import("master_tuner.zig");
const tuner_worker = @import("tuner_worker.zig");
const input_tuners = @import("input_tuners.zig");
const pitch = @import("../tuner/pitch.zig");

pub const CantTune = input_tuners.CantTune;

const Allocator = std.mem.Allocator;

pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const GUID_LEN = 40;

/// The settings a phone can set (tuner/setParam).
pub const TunerParam = enum {
    /// A4, Hz (400-480).
    reference,
    /// The silence threshold, dB (-90 to -30).
    threshold,
};

/// Result from subscribe operation. The track name is held in the result
/// itself: it is read after subscribe() returns.
pub const SubscribeResult = struct {
    track_guid: []const u8,
    track_name_buf: [256]u8 = undefined,
    track_name_len: usize = 0,
    reference_hz: f32,
    threshold_db: f32,

    pub fn trackName(self: *const SubscribeResult) []const u8 {
        return self.track_name_buf[0..self.track_name_len];
    }
};

/// Per-client subscription (which track they're subscribed to)
pub const ClientSubscription = struct {
    active: bool = false,
    track_guid: [GUID_LEN]u8 = undefined,
    track_guid_len: u8 = 0,
    consecutive_failures: u8 = 0, // Auto-unsub after 3 failures
    /// A track tuner on its input: the source in `inputs`, or null while
    /// the track's input can't be tuned (`cant` says why).
    source: ?u8 = null,
    cant: ?CantTune = null,
    /// The settings this phone's tuner last had, for an event while it has
    /// no source, and for a source opened when its track moves input.
    settings: pitch.Settings = .{},
    /// Polls left before opening a source that failed to open is tried
    /// again (`open_retry_polls`).
    retry_polls: u8 = 0,

    pub fn getTrackGuid(self: *const ClientSubscription) ?[]const u8 {
        if (!self.active or self.track_guid_len == 0) return null;
        return self.track_guid[0..self.track_guid_len];
    }

    pub fn clear(self: *ClientSubscription) void {
        self.* = .{};
    }
};

/// Subscription errors
pub const SubscribeError = error{
    TooManyClients,
    TrackNotFound,
    TooManyTuners,
    OutOfMemory,
    AudioHookFailed,
    ThreadFailed,
    // A track whose record input can't be tuned (CantTune).
    InputNone,
    InputMidi,
    InputNotOnDevice,
    InputReaRoute,
    InputMultichannel,
};

/// The subscribe error for a reason a track can't be tuned.
pub fn cantTuneError(why: CantTune) SubscribeError {
    return switch (why) {
        .input_none => error.InputNone,
        .input_midi => error.InputMidi,
        .input_not_on_device => error.InputNotOnDevice,
        .input_rearoute => error.InputReaRoute,
        .input_multichannel => error.InputMultichannel,
        .too_many_inputs => error.TooManyTuners,
        .audio_hook_failed => error.AudioHookFailed,
        .out_of_memory => error.OutOfMemory,
        .thread_failed => error.ThreadFailed,
    };
}

/// The reason a track can't be tuned behind a subscribe error, if it is one.
pub fn cantTuneOf(err: SubscribeError) ?CantTune {
    return switch (err) {
        error.InputNone => .input_none,
        error.InputMidi => .input_midi,
        error.InputNotOnDevice => .input_not_on_device,
        error.InputReaRoute => .input_rearoute,
        error.InputMultichannel => .input_multichannel,
        else => null,
    };
}

/// Polls between tries at opening a source that failed to (REAPER refused
/// the hook, or the analyser couldn't start): once a second at 30 Hz, so a
/// failure isn't retried, and logged, at every poll.
pub const open_retry_polls = 30;

/// How often a phone is sent a reading again while it holds (silence, a
/// steady tone, a state that doesn't change). Every change is sent at the
/// next poll; without a resend a reading that holds would be sent once, and
/// a phone couldn't tell it from a connection, or a REAPER, that has
/// stopped sending: it would keep showing that reading, green included,
/// until the heartbeat let the connection go. The page takes a reading as
/// gone after a few intervals without an event (useTuner.ts). A resend
/// goes at the first 30 Hz poll once due, so about 267 ms apart. A tuner
/// event is about 330 bytes: about 1.3 KB/s per phone while nothing
/// changes, against up to 10 KB/s while a note sounds and each poll's
/// reading differs.
pub const resend_interval_ms = 250;

/// What a poll finds of a phone's track tuner.
pub const TrackStatus = union(enum) {
    /// The track can't be found (deleted, or in another project tab).
    gone,
    /// The track's input can't be tuned now.
    cant: CantTune,
    /// Tuning: the source in `inputs`.
    source: u8,
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

    /// Previous state hash per client (for change detection)
    prev_hash: [MAX_CLIENTS]u64,

    /// Force broadcast flag per client (set on subscribe)
    force_broadcast_clients: [MAX_CLIENTS]bool,

    /// When each client was last sent an event (`nowMs`), for its resend.
    last_sent_ms: [MAX_CLIENTS]u64,

    /// The poll's monotonic clock; null if the OS has none.
    clock: ?std.time.Timer,

    /// A reading its analysis thread published longer ago than this isn't
    /// sent (tuner_generator.analyserEvent): the thread has stopped
    /// ticking, and resending its last reading every resend_interval_ms
    /// would keep it, green included, fresh on the phone. 15 of the
    /// worker's 30 Hz ticks; an overrun starts a new tick at once. Tests
    /// shorten it.
    worker_stall_ns: u64 = 500 * std.time.ns_per_ms,

    /// Free list for slot recycling
    free_slots: [MAX_CLIENTS]usize,
    free_count: usize,

    /// Next available slot
    next_slot: usize,

    /// The master's tuner, shared by every client tuning the master.
    master: master_tuner.MasterTuner = .{},
    /// The track tuners' input sources.
    inputs: input_tuners.InputTuners = .{},
    /// Each source's snapshot for the poll under way (`sourceSnapshot`),
    /// and the master's, so every phone on a source is sent the same
    /// reading at a poll: the worker may publish between two phones.
    poll_snapshots: [audio_hook.max_taps]?tuner_worker.Worker.Snapshot = [_]?tuner_worker.Worker.Snapshot{null} ** audio_hook.max_taps,
    poll_master: ?tuner_worker.Worker.Snapshot = null,
    /// The audio hook the tuners read.
    hook: *audio_hook.Hook,

    pub fn init(allocator: Allocator) TunerSubscriptions {
        var subs = TunerSubscriptions{
            .allocator = allocator,
            .clients = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .prev_hash = [_]u64{0} ** MAX_CLIENTS,
            .force_broadcast_clients = [_]bool{false} ** MAX_CLIENTS,
            .last_sent_ms = [_]u64{0} ** MAX_CLIENTS,
            .clock = std.time.Timer.start() catch null,
            .free_slots = undefined,
            .free_count = 0,
            .next_slot = 0,
            .hook = audio_hook.instance(),
        };

        // Initialize all client slots
        for (&subs.clients) |*client| {
            client.* = ClientSubscription{};
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

    /// Subscribe a client to the tuner on a track's input, or on the master,
    /// leaving any other tuner it was on. Returns the track's name and the
    /// source's settings.
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
            // it and its settings, rather than tearing down and resetting
            // its analyser.
            if (client.getTrackGuid()) |current| if (std.mem.eql(u8, current, track_guid)) {
                if (isMaster(track_guid)) {
                    self.activate(slot, MASTER_GUID);
                    return self.masterResult(api);
                }
                // Still on the input it is tuning: keep the source.
                if (client.source) |index| if (resolveTrack(guid_cache, api, track_guid)) |track| {
                    const now = input_tuners.classify(api.getTrackRecInput(track), api.numAudioInputs(), api.isAudioRunning());
                    if (now == .channels and now.channels.eql(self.inputs.source(index).channels)) {
                        self.activate(slot, track_guid);
                        self.clients[slot].source = index;
                        return self.inputResult(slot, track, api);
                    }
                };
            };
        }
        // A phone choosing its track again keeps the settings its tuner had
        // (it may have no source now, or its track has moved input).
        const same_track = if (client.getTrackGuid()) |current| std.mem.eql(u8, current, track_guid) else false;
        const carried: pitch.Settings = if (same_track) client.settings else .{};
        // Otherwise leave the previous tuner first.
        if (client.active) self.unsubscribeInternal(client_id, slot, api);

        if (isMaster(track_guid)) return self.subscribeMaster(slot, api);
        return self.subscribeInput(slot, track_guid, guid_cache, api, carried);
    }

    /// The track a GUID names now, or null.
    fn resolveTrack(guid_cache: anytype, api: anytype, track_guid: []const u8) ?*anyopaque {
        const track = guid_cache.resolve(api, track_guid) orelse return null;
        return if (api.validateTrackPtr(track)) track else null;
    }

    /// Subscribe a client to the tuner on a track's input, a new source
    /// starting from `settings`. A track whose record input can't be tuned
    /// is refused, and the phone still follows it: its polls say why, until
    /// the input can be tuned and tuning starts. A source that fails to open
    /// is refused and not followed.
    fn subscribeInput(self: *TunerSubscriptions, slot: usize, track_guid: []const u8, guid_cache: anytype, api: anytype, settings: pitch.Settings) SubscribeError!SubscribeResult {
        const track = resolveTrack(guid_cache, api, track_guid) orelse return error.TrackNotFound;
        const channels = switch (input_tuners.classify(api.getTrackRecInput(track), api.numAudioInputs(), api.isAudioRunning())) {
            .cant => |why| {
                self.activate(slot, track_guid);
                self.clients[slot].cant = why;
                self.clients[slot].settings = settings;
                return cantTuneError(why);
            },
            .channels => |c| c,
        };
        const index = self.inputs.open(self.allocator, self.hook, api, channels, settings) catch |err|
            return cantTuneError(CantTune.fromOpenError(err));
        self.activate(slot, track_guid);
        self.clients[slot].source = index;
        return self.inputResult(slot, track, api);
    }

    fn inputResult(self: *TunerSubscriptions, slot: usize, track: *anyopaque, api: anytype) SubscribeResult {
        const client = &self.clients[slot];
        const settings = self.inputs.source(client.source.?).worker.snapshot().settings;
        client.settings = settings;
        var result = SubscribeResult{
            .track_guid = client.getTrackGuid().?,
            .reference_hz = @floatCast(settings.reference_hz),
            .threshold_db = @floatCast(settings.silence_db),
        };
        result.track_name_len = api.getTrackNameStr(track, &result.track_name_buf).len;
        return result;
    }

    /// For a poll: check a phone's track tuner against its track's record
    /// input now, and follow it. A track gone stays as it was, for the
    /// poll's failure count to end. An input that can no longer be tuned
    /// closes the phone's source and says why; one that can again, or a
    /// new input, opens (or joins) the source on it, a new source taking
    /// the settings the phone's tuner had. `device_open` is
    /// api.isAudioRunning(), once per poll. Main thread.
    pub fn refreshTrack(self: *TunerSubscriptions, slot: usize, guid_cache: anytype, api: anytype, device_open: bool) TrackStatus {
        const client = &self.clients[slot];
        const track_guid = client.getTrackGuid() orelse return .gone;
        const track = resolveTrack(guid_cache, api, track_guid) orelse return .gone;
        const now = input_tuners.classify(api.getTrackRecInput(track), api.numAudioInputs(), device_open);
        if (client.source) |index| {
            const s = self.inputs.source(index);
            if (now == .channels and now.channels.eql(s.channels)) return .{ .source = index };
            client.settings = s.worker.snapshot().settings;
            self.closeSource(api, index);
            client.source = null;
            logging.info("tuner: track {s} changed its record input", .{track_guid});
        }
        switch (now) {
            .cant => |why| {
                client.cant = why;
                client.retry_polls = 0;
                return .{ .cant = why };
            },
            .channels => |channels| {
                if (client.retry_polls > 0) {
                    client.retry_polls -= 1;
                    return .{ .cant = client.cant.? };
                }
                const index = self.inputs.open(self.allocator, self.hook, api, channels, client.settings) catch |err| {
                    const why = CantTune.fromOpenError(err);
                    client.cant = why;
                    client.retry_polls = open_retry_polls - 1;
                    return .{ .cant = why };
                };
                client.source = index;
                client.cant = null;
                return .{ .source = index };
            },
        }
    }

    /// Start a poll: sources' readings are taken afresh, once each.
    pub fn beginPoll(self: *TunerSubscriptions) void {
        @memset(&self.poll_snapshots, null);
        self.poll_master = null;
    }

    /// A source's reading and settings for this poll: taken from its worker
    /// the first time a phone on it asks, the same for the rest. Main thread.
    pub fn sourceSnapshot(self: *TunerSubscriptions, index: u8) tuner_worker.Worker.Snapshot {
        if (self.poll_snapshots[index]) |snap| return snap;
        const snap = self.inputs.source(index).worker.snapshot();
        self.poll_snapshots[index] = snap;
        return snap;
    }

    /// The master's reading and settings for this poll, as sourceSnapshot.
    pub fn masterSnapshot(self: *TunerSubscriptions) tuner_worker.Worker.Snapshot {
        if (self.poll_master) |snap| return snap;
        const snap = self.master.snapshot();
        self.poll_master = snap;
        return snap;
    }

    /// A phone leaves source `index`; a source opened in the slot later in
    /// the same poll is a new one, with no snapshot yet.
    fn closeSource(self: *TunerSubscriptions, api: anytype, index: u8) void {
        self.inputs.close(self.allocator, self.hook, api, index);
        if (self.inputs.source(index).phones == 0) self.poll_snapshots[index] = null;
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
            .reference_hz = @floatCast(settings.reference_hz),
            .threshold_db = @floatCast(settings.silence_db),
        };
        if (api.masterTrack()) |master| result.track_name_len = api.getTrackNameStr(master, &result.track_name_buf).len;
        return result;
    }

    /// Internal unsubscribe (doesn't remove client from map)
    fn unsubscribeInternal(self: *TunerSubscriptions, client_id: usize, slot: usize, api: anytype) void {
        const client = &self.clients[slot];
        if (!client.active) return;

        const track_guid = client.getTrackGuid() orelse return;

        if (isMaster(track_guid)) {
            self.master.close(self.allocator, self.hook, api);
            if (!self.master.isOpen()) logging.info("tuner: master tuner closed (last subscriber)", .{});
        } else if (client.source) |index| {
            self.closeSource(api, index);
        }

        client.clear();
        self.prev_hash[slot] = 0;

        logging.debug("tuner: client {d} unsubscribed", .{client_id});
    }

    /// Unsubscribe a client from their current tuner. The last phone on a
    /// source closes it.
    pub fn unsubscribe(self: *TunerSubscriptions, client_id: usize, api: anytype) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        self.unsubscribeInternal(client_id, slot, api);
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *TunerSubscriptions, client_id: usize, api: anytype) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;

        self.unsubscribeInternal(client_id, slot, api);

        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        logging.debug("tuner: client {d} removed", .{client_id});
    }

    /// Remove all clients, closing every source and the master tuner
    /// (called on shutdown).
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

    /// Set a tuner parameter (reference or threshold) on the master, or on
    /// a track's source and every phone tuning that track.
    pub fn setParam(
        self: *TunerSubscriptions,
        track_guid: []const u8,
        param: TunerParam,
        value: f32,
    ) error{ InvalidParam, NotSubscribed }!void {
        const held = heldToRange(param, value) orelse return error.InvalidParam;
        if (isMaster(track_guid)) {
            if (!self.master.isOpen()) return error.NotSubscribed;
            switch (param) {
                .reference => self.master.setReference(held),
                .threshold => self.master.setSilenceDb(held),
            }
            return;
        }
        return self.setInputParam(track_guid, param, held);
    }

    /// setParam on a track tuner on its input: the source the phones on
    /// that track are tuning, and each of those phones' own settings (which
    /// a phone whose input can't be tuned now takes to its next source).
    fn setInputParam(self: *TunerSubscriptions, track_guid: []const u8, param: TunerParam, held: f64) error{NotSubscribed}!void {
        var found = false;
        for (&self.clients) |*client| {
            const guid = client.getTrackGuid() orelse continue;
            if (!std.mem.eql(u8, guid, track_guid)) continue;
            found = true;
            switch (param) {
                .reference => client.settings.reference_hz = held,
                .threshold => client.settings.silence_db = held,
            }
            if (client.source) |index| {
                const w = &self.inputs.source(index).worker;
                switch (param) {
                    .reference => w.setReference(held),
                    .threshold => w.setSilenceDb(held),
                }
            }
        }
        if (!found) return error.NotSubscribed;
    }

    /// A setParam value held to the tuner's range, the same for a track
    /// tuner and the master: A4 400-480 Hz, the silence threshold -90 to
    /// -30 dB. Null for a value that isn't a finite number.
    pub fn heldToRange(param: TunerParam, value: f64) ?f64 {
        if (!std.math.isFinite(value)) return null;
        return switch (param) {
            .reference => std.math.clamp(value, tuner_worker.reference_min_hz, tuner_worker.reference_max_hz),
            .threshold => std.math.clamp(value, tuner_worker.silence_min_db, tuner_worker.silence_max_db),
        };
    }

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const TunerSubscriptions) bool {
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) return true;
        }
        return false;
    }

    /// Milliseconds on the poll's monotonic clock, or null if there is none.
    pub fn nowMs(self: *TunerSubscriptions) ?u64 {
        const clock = if (self.clock) |*c| c else return null;
        return clock.read() / std.time.ns_per_ms;
    }

    /// Whether a poll sends a client its event (by hash): its first since
    /// subscribing, a change, or the same again once resend_interval_ms
    /// has passed since the last it was sent. `now_ms` is nowMs(); with no
    /// clock every event is sent, as a phone shown a reading that holds
    /// and isn't sent again would take it for gone.
    pub fn shouldSend(self: *TunerSubscriptions, slot: usize, data_hash: u64, now_ms: ?u64) bool {
        if (slot >= MAX_CLIENTS) return false;
        const due = if (now_ms) |now| now -| self.last_sent_ms[slot] >= resend_interval_ms else true;
        if (!self.force_broadcast_clients[slot] and self.prev_hash[slot] == data_hash and !due) return false;
        self.force_broadcast_clients[slot] = false;
        self.prev_hash[slot] = data_hash;
        if (now_ms) |now| self.last_sent_ms[slot] = now;
        return true;
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
    try rig.subs.setParam(MASTER_GUID, .reference, 442);
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
    try rig.subs.setParam(MASTER_GUID, .threshold, -50);
    try std.testing.expectEqual(@as(f64, -50), rig.subs.master.snapshot().settings.silence_db);

    // Phone 1 subscribing again to the master is a resubscribe, not a third phone.
    _ = try rig.sub(1);
    try std.testing.expectEqual(@as(u8, 2), rig.subs.master.subscribers);

    rig.subs.removeClient(1, &rig.api); // phone 1's connection drops
    try std.testing.expect(rig.subs.master.isOpen() and rig.hook.holds(.tuner));
    try std.testing.expectEqual(@as(f64, -50), rig.subs.master.snapshot().settings.silence_db);
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
    try std.testing.expectError(error.NotSubscribed, rig.subs.setParam(MASTER_GUID, .reference, 442));
}

test "a phone subscribing again to the master it is on keeps the tuner and its settings" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();

    _ = try rig.sub(1);
    try rig.subs.setParam(MASTER_GUID, .reference, 442);
    const analysis = rig.subs.master.worker.analysis;
    const r = try rig.sub(1); // the page re-sends its subscribe, e.g. after a re-render
    try std.testing.expectEqual(@as(f32, 442), r.reference_hz);
    try std.testing.expectEqual(analysis, rig.subs.master.worker.analysis);
    try std.testing.expectEqual(@as(u8, 1), rig.subs.master.subscribers);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_registers);
    try std.testing.expectEqual(@as(u32, 0), rig.api.audio_hook_unregisters);
}

test "setParam values are held to the tuner's range, for track tuners and the master alike" {
    const H = TunerSubscriptions.heldToRange;
    try std.testing.expectEqual(@as(?f64, 400), H(.reference, 300));
    try std.testing.expectEqual(@as(?f64, 480), H(.reference, 1e9));
    try std.testing.expectEqual(@as(?f64, 442), H(.reference, 442));
    try std.testing.expectEqual(@as(?f64, -30), H(.threshold, 20));
    try std.testing.expectEqual(@as(?f64, -90), H(.threshold, -120));
    try std.testing.expectEqual(@as(?f64, null), H(.reference, std.math.nan(f64)));
    try std.testing.expectEqual(@as(?f64, null), H(.threshold, std.math.inf(f64)));
}

test "setParam on the master holds an out-of-range value and refuses a non-finite one" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1);
    try rig.subs.setParam(MASTER_GUID, .reference, 300);
    try std.testing.expectEqual(@as(f64, 400), rig.subs.master.snapshot().settings.reference_hz);
    try std.testing.expectError(error.InvalidParam, rig.subs.setParam(MASTER_GUID, .threshold, std.math.nan(f32)));
    try std.testing.expectEqual(@as(f64, -90), rig.subs.master.snapshot().settings.silence_db);
}

// -----------------------------------------------------------------------------
// Track tuners on their inputs
// -----------------------------------------------------------------------------

/// A GUID cache that knows "{T1}" to "{T3}", the mock's tracks 1 to 3.
const ThreeTracks = struct {
    fn resolve(_: *const ThreeTracks, api: anytype, guid: []const u8) ?*anyopaque {
        if (isMaster(guid)) return api.masterTrack();
        const names = [_][]const u8{ "{T1}", "{T2}", "{T3}" };
        for (names, 1..) |n, i| {
            if (std.mem.eql(u8, guid, n)) return @import("../reaper/mock/state.zig").encodeTrackPtr(@intCast(i));
        }
        return null;
    }
};

const InputRig = struct {
    subs: TunerSubscriptions,
    hook: *audio_hook.Hook,
    api: MockBackend,
    cache: ThreeTracks = .{},

    /// Three tracks, Bass on input 1, Guitar on input 2 and Keys on input
    /// 2 (I_RECINPUT 0, 1, 1), none armed, on a four-input device.
    fn init(self: *InputRig) !void {
        self.hook = try std.testing.allocator.create(audio_hook.Hook);
        self.hook.* = .{};
        self.subs = TunerSubscriptions.init(std.testing.allocator);
        self.subs.hook = self.hook;
        self.api = .{ .track_count = 3, .audio_input_count = 4 };
        self.api.tracks[1].setName("Bass");
        self.api.tracks[2].setName("Guitar");
        self.api.tracks[3].setName("Keys");
        self.setInput(1, 0);
        self.setInput(2, 1);
        self.setInput(3, 1);
    }

    fn deinit(self: *InputRig) void {
        self.subs.removeAllClients(&self.api);
        self.subs.deinit();
        std.testing.allocator.destroy(self.hook);
    }

    fn setInput(self: *InputRig, track: usize, rec_input: c_int) void {
        self.api.tracks[track].rec_input = rec_input;
    }

    fn sub(self: *InputRig, client: usize, guid: []const u8) !SubscribeResult {
        return self.subs.subscribe(client, guid, &self.cache, &self.api);
    }

    fn refresh(self: *InputRig, client: usize) TrackStatus {
        const slot = self.subs.client_id_to_slot.get(client).?;
        return self.subs.refreshTrack(slot, &self.cache, &self.api, self.api.audio_running);
    }

    fn sourceOf(self: *InputRig, client: usize) ?u8 {
        return self.subs.clients[self.subs.client_id_to_slot.get(client).?].source;
    }

    fn settingsOf(self: *InputRig, client: usize) pitch.Settings {
        return self.subs.inputs.source(self.sourceOf(client).?).worker.snapshot().settings;
    }
};

test "a track tuner opens on the track's record input, unarmed, with no plugin" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();

    const r = try rig.sub(1, "{T2}");
    try std.testing.expectEqualStrings("{T2}", r.track_guid);
    try std.testing.expectEqualStrings("Guitar", r.trackName());
    try std.testing.expectEqual(@as(f32, 440), r.reference_hz);
    try std.testing.expectEqual(@as(f32, -90), r.threshold_db);
    const s = rig.subs.inputs.source(rig.sourceOf(1).?);
    try std.testing.expect(s.channels.eql(.{ .first = 1, .stereo = false }));
    try std.testing.expect(rig.hook.holds(.inputs) and rig.hook.openTaps() == 1);
    try std.testing.expectEqual(@as(usize, 0), rig.api.getCallCount(.trackFxAddByName));
    try std.testing.expectEqual(@as(usize, 0), rig.api.getCallCount(.trackFxCopyToTrack));

    rig.subs.unsubscribe(1, &rig.api);
    try std.testing.expect(!rig.hook.registered);
    try std.testing.expectEqual(@as(usize, 0), rig.api.getCallCount(.trackFxDelete));
}

test "a stereo record input tunes its pair" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.setInput(1, 1024 + 2);
    _ = try rig.sub(1, "{T1}");
    try std.testing.expect(rig.subs.inputs.source(rig.sourceOf(1).?).channels.eql(.{ .first = 2, .stereo = true }));
}

test "a track whose record input can't be tuned is refused, and nothing opens" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cases = [_]struct { rec: c_int, err: SubscribeError }{
        .{ .rec = -1, .err = error.InputNone },
        .{ .rec = 4096 | (63 << 5), .err = error.InputMidi },
        .{ .rec = 512, .err = error.InputReaRoute },
        .{ .rec = 2048, .err = error.InputMultichannel },
        .{ .rec = 4, .err = error.InputNotOnDevice }, // a four-input device: inputs 0-3
        .{ .rec = 1024 + 3, .err = error.InputNotOnDevice },
    };
    for (cases) |c| {
        rig.setInput(1, c.rec);
        try std.testing.expectError(c.err, rig.sub(1, "{T1}"));
        try std.testing.expect(!rig.hook.registered);
        try std.testing.expectEqual(@as(usize, 0), rig.hook.openTaps());
        // The handler tells the phone the reason's own code and message.
        try std.testing.expect(cantTuneOf(c.err) != null);
    }
    // The phone can then tune a track that can be.
    _ = try rig.sub(1, "{T2}");
    try std.testing.expectEqual(@as(usize, 1), rig.hook.openTaps());
}

test "with the device closed a track's channel isn't checked, and refreshing doesn't take it for missing" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.api.audio_running = false;
    rig.api.audio_input_count = 0; // what REAPER reports while it has the device closed
    _ = try rig.sub(1, "{T2}");
    const before = rig.sourceOf(1).?;
    try std.testing.expectEqual(TrackStatus{ .source = before }, rig.refresh(1));
    // The device opens again: the same source carries on.
    rig.api.audio_running = true;
    rig.api.audio_input_count = 4;
    try std.testing.expectEqual(TrackStatus{ .source = before }, rig.refresh(1));
}

test "phones on tracks on one input share its source and settings; another input is independent" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}"); // bassist, input 1
    _ = try rig.sub(2, "{T2}"); // guitarist, input 2
    try std.testing.expect(rig.sourceOf(1).? != rig.sourceOf(2).?);
    try std.testing.expectEqual(@as(usize, 2), rig.hook.openTaps());

    try rig.subs.setParam("{T2}", .reference, 442);
    try std.testing.expectEqual(@as(f64, 442), rig.settingsOf(2).reference_hz);
    try std.testing.expectEqual(@as(f64, 440), rig.settingsOf(1).reference_hz);

    // A third phone, on Keys, also on input 2: the guitar's source and settings.
    const r = try rig.sub(3, "{T3}");
    try std.testing.expectEqual(rig.sourceOf(2).?, rig.sourceOf(3).?);
    try std.testing.expectEqual(@as(f32, 442), r.reference_hz);
    try std.testing.expectEqual(@as(usize, 2), rig.hook.openTaps());
    try std.testing.expectEqual(@as(u8, 2), rig.subs.inputs.source(rig.sourceOf(2).?).phones);

    // A fourth on Guitar itself joins the same.
    _ = try rig.sub(4, "{T2}");
    try std.testing.expectEqual(@as(u8, 3), rig.subs.inputs.source(rig.sourceOf(2).?).phones);
}

test "a phone leaving or disconnecting gives up its share; the last on an input closes it" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T2}");
    _ = try rig.sub(2, "{T3}");
    const index = rig.sourceOf(1).?;
    rig.subs.removeClient(1, &rig.api); // phone 1's connection drops
    try std.testing.expectEqual(@as(u8, 1), rig.subs.inputs.source(index).phones);
    try std.testing.expect(rig.hook.registered);
    rig.subs.unsubscribe(2, &rig.api);
    try std.testing.expectEqual(@as(usize, 0), rig.subs.inputs.openCount());
    try std.testing.expect(!rig.hook.registered);
    try std.testing.expect(!rig.subs.hasSubscriptions());
}

test "a phone subscribing again to its track keeps its source and settings" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    try rig.subs.setParam("{T1}", .threshold, -60);
    const index = rig.sourceOf(1).?;
    const tag = rig.subs.inputs.source(index).tap.tag;
    const r = try rig.sub(1, "{T1}");
    try std.testing.expectEqual(@as(f32, -60), r.threshold_db);
    try std.testing.expectEqual(index, rig.sourceOf(1).?);
    try std.testing.expectEqual(tag, rig.subs.inputs.source(index).tap.tag);
    try std.testing.expectEqual(@as(u8, 1), rig.subs.inputs.source(index).phones);
}

test "a track's input changing moves its phone to the new input, with its settings" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    try rig.subs.setParam("{T1}", .reference, 445);
    const old = rig.sourceOf(1).?;
    try std.testing.expectEqual(TrackStatus{ .source = old }, rig.refresh(1));

    rig.setInput(1, 3); // the bass moves to input 4
    const now = rig.refresh(1);
    try std.testing.expect(now == .source);
    try std.testing.expect(rig.subs.inputs.source(now.source).channels.eql(.{ .first = 3, .stereo = false }));
    try std.testing.expectEqual(@as(f64, 445), rig.settingsOf(1).reference_hz);
    // The old input had no one else: its source and tap are closed.
    try std.testing.expectEqual(@as(usize, 1), rig.subs.inputs.openCount());
    try std.testing.expectEqual(@as(usize, 1), rig.hook.openTaps());
}

test "a track moving to an input another phone tunes joins that phone's source" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    _ = try rig.sub(2, "{T2}");
    try rig.subs.setParam("{T2}", .reference, 432);
    rig.setInput(1, 1); // Bass now records from input 2, as Guitar does
    try std.testing.expectEqual(TrackStatus{ .source = rig.sourceOf(2).? }, rig.refresh(1));
    try std.testing.expectEqual(@as(f64, 432), rig.settingsOf(1).reference_hz);
    try std.testing.expectEqual(@as(usize, 1), rig.hook.openTaps());
    try std.testing.expectEqual(@as(u8, 2), rig.subs.inputs.source(rig.sourceOf(2).?).phones);
}

test "an input changing to one that can't be tuned says why, and tuning resumes when it can" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    try rig.subs.setParam("{T1}", .threshold, -70);

    rig.setInput(1, 4096); // MIDI
    try std.testing.expectEqual(TrackStatus{ .cant = .input_midi }, rig.refresh(1));
    try std.testing.expect(!rig.hook.registered);
    try std.testing.expect(rig.subs.hasSubscriptions()); // still on the track
    // Settings set meanwhile are kept for when it can be tuned again.
    try rig.subs.setParam("{T1}", .reference, 441);

    rig.setInput(1, 6); // an input the device doesn't have
    try std.testing.expectEqual(TrackStatus{ .cant = .input_not_on_device }, rig.refresh(1));
    rig.setInput(1, 2);
    const back = rig.refresh(1);
    try std.testing.expect(back == .source);
    try std.testing.expectEqual(pitch.Settings{ .reference_hz = 441, .silence_db = -70 }, rig.settingsOf(1));
}

test "a device losing an input mid-tune says so" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T2}");
    rig.api.audio_input_count = 1; // another device, with one input
    try std.testing.expectEqual(TrackStatus{ .cant = .input_not_on_device }, rig.refresh(1));
    try std.testing.expectEqual(@as(usize, 0), rig.hook.openTaps());
}

test "a deleted track is gone to the poll, which ends the phone's subscription" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T3}");
    rig.api.track_count = 2; // Keys deleted
    try std.testing.expectEqual(TrackStatus.gone, rig.refresh(1));
    // The poll ends it after three failures.
    try std.testing.expect(!rig.subs.recordFailure(1));
    try std.testing.expect(!rig.subs.recordFailure(1));
    try std.testing.expect(rig.subs.recordFailure(1));
    rig.subs.unsubscribe(1, &rig.api);
    try std.testing.expect(!rig.hook.registered);
}

test "setParam on a track nobody tunes is refused" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    try std.testing.expectError(error.NotSubscribed, rig.subs.setParam("{T2}", .reference, 442));
    try std.testing.expectError(error.InvalidParam, rig.subs.setParam("{T1}", .reference, std.math.nan(f32)));
}

test "the master and track tuners on inputs share the one hook registration" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    _ = try rig.sub(2, MASTER_GUID);
    try std.testing.expectEqual(@as(u32, 1), rig.api.audio_hook_registers);
    rig.subs.unsubscribe(1, &rig.api);
    try std.testing.expect(rig.hook.registered and rig.hook.holds(.tuner) and !rig.hook.holds(.inputs));
    rig.subs.unsubscribe(2, &rig.api);
    try std.testing.expect(!rig.hook.registered);
}

/// Whether a mock method may change REAPER (FX, tracks, items, transport,
/// the undo history, the project), by its name. Only names that read are
/// let through, so a method added to the mock later counts as a write
/// unless it is named as a read; a read taken for a write only fails the
/// test that calls it, visibly.
fn writesToReaper(name: []const u8) bool {
    const write_words = [_][]const u8{ "Set", "Delete", "Add", "Copy", "Navigate", "Toggle", "Insert", "Remove", "Move", "OnCommand" };
    for (write_words) |w| if (std.mem.indexOf(u8, name, w) != null) return true;
    const read_prefixes = [_][]const u8{ "get", "is", "can", "validate", "enum", "format", "num", "max", "time", "play", "cursor", "project", "bar", "beats", "tempo", "major", "reverse", "master", "namedCommandLookup", "midiEditorGetActive", "midiInputName", "audioInputName", "audioOutputName", "itemNotes", "itemTakeCount", "markerCount", "trackCount", "trackItemCount" };
    for (read_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return false;
    // track*Get*, track*Count: a track's FX, sends, receives and outputs, read.
    if (std.mem.startsWith(u8, name, "track") and
        (std.mem.indexOf(u8, name, "Get") != null or std.mem.endsWith(u8, name, "Count"))) return false;
    return true;
}

test "no tuner path changes REAPER: no FX, no undo point, no project change, whatever the phones do" {
    const Method = @import("../reaper/mock/state.zig").Method;
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try rig.sub(1, "{T1}");
    _ = try rig.sub(1, "{T1}"); // the page re-sends its subscribe
    try rig.subs.setParam("{T1}", .reference, 442);
    try rig.subs.setParam("{T1}", .threshold, -60);
    _ = try rig.sub(2, "{T2}");
    _ = try rig.sub(3, "{T3}"); // shares the guitar's input
    _ = try rig.sub(4, MASTER_GUID);
    try rig.subs.setParam(MASTER_GUID, .reference, 441);
    rig.subs.beginPoll();
    for ([_]usize{ 1, 2, 3, 4 }) |client| _ = try polledPayload(&rig, client, arena.allocator());
    rig.setInput(1, 3); // the bass moves input
    _ = rig.refresh(1);
    rig.setInput(1, 4096); // then to MIDI
    _ = rig.refresh(1);
    rig.setInput(1, -1);
    try std.testing.expectError(error.InputNone, rig.sub(1, "{T1}"));
    rig.setInput(1, 0);
    _ = rig.refresh(1);
    _ = try rig.sub(2, MASTER_GUID); // a phone moves from a track to the master
    _ = try rig.sub(4, "{T2}"); // and one from the master to a track
    // Keys, phone 3's track, is deleted: the poll finds it gone three times
    // and ends the subscription, as pollTunerSubscriptions does.
    rig.api.track_count = 2;
    const slot3 = rig.subs.client_id_to_slot.get(3).?;
    for (0..3) |_| {
        try std.testing.expectEqual(tuner_generator.AnalyserOutcome.gone, tuner_generator.analyserEvent(arena.allocator(), &rig.subs, slot3, &rig.cache, &rig.api, true));
        if (rig.subs.recordFailure(3)) rig.subs.unsubscribe(3, &rig.api);
    }
    try std.testing.expect(!rig.subs.clients[slot3].active);
    rig.subs.removeClient(2, &rig.api); // a connection drops
    rig.subs.removeAllClients(&rig.api); // REAPER quits

    try std.testing.expect(rig.api.call_count < @import("../reaper/mock/mod.zig").MAX_CALLS); // every call was logged
    inline for (@typeInfo(Method).@"enum".fields) |f| {
        if (writesToReaper(f.name)) {
            const n = rig.api.getCallCount(@field(Method, f.name));
            if (n != 0) std.debug.print("the tuner called {s} {d} times\n", .{ f.name, n });
            try std.testing.expectEqual(@as(usize, 0), n);
        }
    }
    // The name filter catches the calls an FX in the project would need.
    try std.testing.expect(writesToReaper("trackFxAddByName") and writesToReaper("trackFxDelete") and
        writesToReaper("trackFxCopyToTrack") and writesToReaper("trackFxSetParamNormalized") and writesToReaper("undoBeginBlock"));
    try std.testing.expect(!writesToReaper("getTrackRecInput") and !writesToReaper("trackFxGetGuid") and
        !writesToReaper("numAudioInputs") and !writesToReaper("validateTrackPtr"));
    // A name it doesn't know is taken for a write.
    try std.testing.expect(writesToReaper("armTrack") and writesToReaper("saveProject") and writesToReaper("trackFxShow"));
}

test "a phone moving from a track to the master leaves its input" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    _ = try rig.sub(1, MASTER_GUID);
    try std.testing.expectEqual(@as(usize, 0), rig.hook.openTaps());
    try std.testing.expect(rig.subs.master.isOpen());
}

// -----------------------------------------------------------------------------
// What a poll sends phones on the analyser
// -----------------------------------------------------------------------------

const tuner_generator = @import("tuner_generator.zig");

/// The payload of the event a poll sends `client`, parsed.
fn polledPayload(rig: *InputRig, client: usize, arena: Allocator) !std.json.ObjectMap {
    const slot = rig.subs.client_id_to_slot.get(client).?;
    const out = tuner_generator.analyserEvent(arena, &rig.subs, slot, &rig.cache, &rig.api, rig.api.audio_running);
    const json = switch (out) {
        .event => |j| j,
        else => return error.NoEvent,
    };
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return parsed.object.get("payload").?.object;
}

test "a poll tells a phone on a track tuner it is listening, with the analyser's flags" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try rig.sub(1, "{T2}");
    const p = try polledPayload(&rig, 1, arena.allocator());
    try std.testing.expectEqualStrings("{T2}", p.get("trackGuid").?.string);
    try std.testing.expectEqualStrings("listening", p.get("state").?.string);
    for ([_][]const u8{ "settling", "stable", "multiple", "starting" }) |flag| try std.testing.expect(p.get(flag) != null);
    try std.testing.expectEqual(@as(i64, -90), p.get("thresholdDb").?.integer);
}

test "a poll with the device closed says so to every tuner, with no reading" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try rig.sub(1, "{T2}");
    _ = try rig.sub(2, MASTER_GUID);
    // A reading the worker had published before the device closed.
    const w = &rig.subs.inputs.source(rig.sourceOf(1).?).worker;
    w.lock.lock();
    w.reading = .{ .freq_hz = 220, .note = 57, .cents = 0, .clarity = 0.99, .settling = false, .stable = true, .multiple = false, .starting = false };
    w.lock.unlock();

    rig.api.audio_running = false;
    rig.api.audio_input_count = 0;
    for ([_]usize{ 1, 2 }) |client| {
        const p = try polledPayload(&rig, client, arena.allocator());
        try std.testing.expectEqualStrings("deviceClosed", p.get("state").?.string);
        try std.testing.expectEqual(@as(f64, 0), p.get("freq").?.float);
    }
    // Still tuning the same input: readings resume when the device reopens.
    rig.api.audio_running = true;
    rig.api.audio_input_count = 4;
    const p = try polledPayload(&rig, 1, arena.allocator());
    try std.testing.expectEqualStrings("listening", p.get("state").?.string);
}

test "a poll tells a phone why its track's input can't be tuned now, with its settings" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try rig.sub(1, "{T1}");
    try rig.subs.setParam("{T1}", .reference, 442);
    rig.setInput(1, -1);
    const p = try polledPayload(&rig, 1, arena.allocator());
    try std.testing.expectEqualStrings("cantTune", p.get("state").?.string);
    try std.testing.expectEqualStrings("INPUT_NONE", p.get("code").?.string);
    try std.testing.expectEqualStrings(CantTune.input_none.message(), p.get("message").?.string);
    try std.testing.expectEqual(@as(f64, 442), p.get("referenceHz").?.float);
    try std.testing.expectEqual(@as(f64, 0), p.get("freq").?.float);
}

test "a poll finds a deleted track gone" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T3}");
    rig.api.track_count = 2;
    const slot = rig.subs.client_id_to_slot.get(1).?;
    try std.testing.expectEqual(tuner_generator.AnalyserOutcome.gone, tuner_generator.analyserEvent(std.testing.allocator, &rig.subs, slot, &rig.cache, &rig.api, true));
}

test "a refused track is still followed, and tuning starts once its input can be tuned" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.setInput(1, -1);
    try std.testing.expectError(error.InputNone, rig.sub(1, "{T1}"));
    try std.testing.expect(rig.subs.hasSubscriptions());
    try std.testing.expect(!rig.hook.registered);
    try std.testing.expectEqual(TrackStatus{ .cant = .input_none }, rig.refresh(1));
    rig.setInput(1, 0); // the user chooses input 1 in REAPER
    try std.testing.expect(rig.refresh(1) == .source);
}

test "re-choosing a track that can't be tuned keeps following it, with its settings" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    try rig.subs.setParam("{T1}", .reference, 442);
    rig.setInput(1, 4096);
    try std.testing.expectEqual(TrackStatus{ .cant = .input_midi }, rig.refresh(1));
    try std.testing.expectError(error.InputMidi, rig.sub(1, "{T1}"));
    try std.testing.expect(rig.subs.hasSubscriptions());
    rig.setInput(1, 0);
    try std.testing.expect(rig.refresh(1) == .source);
    try std.testing.expectEqual(@as(f64, 442), rig.settingsOf(1).reference_hz);
}

test "subscribing again after the track moved input keeps the tuner's settings" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    try rig.subs.setParam("{T1}", .reference, 445);
    rig.setInput(1, 3);
    const r = try rig.sub(1, "{T1}");
    try std.testing.expectEqual(@as(f32, 445), r.reference_hz);
}

test "a source that won't open is tried again once a second, not at every poll" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1, "{T1}");
    rig.api.audio_hook_refuse = true;
    rig.setInput(1, 3); // the last tap closes, so the hook must be taken again
    try std.testing.expectEqual(TrackStatus{ .cant = .audio_hook_failed }, rig.refresh(1));
    rig.api.audio_hook_refuse = false;
    for (0..open_retry_polls - 1) |_| try std.testing.expectEqual(TrackStatus{ .cant = .audio_hook_failed }, rig.refresh(1));
    try std.testing.expect(rig.refresh(1) == .source);
}

test "a subscribe that fails to open isn't kept" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.api.audio_hook_refuse = true;
    try std.testing.expectError(error.AudioHookFailed, rig.sub(1, "{T1}"));
    try std.testing.expect(!rig.subs.hasSubscriptions());
}

fn publish(w: *tuner_worker.Worker, hz: f64) void {
    w.lock.lock();
    defer w.lock.unlock();
    w.reading = .{ .freq_hz = hz, .note = 55, .cents = 0, .clarity = 0.9, .settling = false, .stable = false, .multiple = false, .starting = false };
}

test "every phone on a source is sent the same reading in a poll, though the worker publishes between them" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Workers that tick once, at start, then wait: what the test publishes stays.
    rig.subs.inputs.tick_ns = 60 * std.time.ns_per_s;
    rig.subs.master.worker.tick_ns = 60 * std.time.ns_per_s;
    _ = try rig.sub(1, "{T2}");
    _ = try rig.sub(2, "{T3}"); // Keys, on the guitar's input
    _ = try rig.sub(3, MASTER_GUID);
    std.Thread.sleep(50 * std.time.ns_per_ms); // their first ticks are done
    const w = &rig.subs.inputs.source(rig.sourceOf(1).?).worker;

    rig.subs.beginPoll();
    publish(w, 196.0);
    publish(&rig.subs.master.worker, 110.0);
    const first = try polledPayload(&rig, 1, arena.allocator());
    const m1 = try polledPayload(&rig, 3, arena.allocator());
    publish(w, 196.5); // the worker's next tick lands mid-poll
    publish(&rig.subs.master.worker, 111.0);
    const second = try polledPayload(&rig, 2, arena.allocator());
    try std.testing.expectEqual(first.get("freq").?.float, second.get("freq").?.float);
    try std.testing.expectEqual(@as(f64, 110), m1.get("freq").?.float);

    rig.subs.beginPoll();
    try std.testing.expectEqual(@as(f64, 196.5), (try polledPayload(&rig, 1, arena.allocator())).get("freq").?.float);
    try std.testing.expectEqual(@as(f64, 111), (try polledPayload(&rig, 3, arena.allocator())).get("freq").?.float);
}

test "a reading from an analysis thread that has stopped publishing isn't sent, so the phone's screen goes stale" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Workers that tick once, at start, then wait: a stalled thread.
    rig.subs.inputs.tick_ns = 60 * std.time.ns_per_s;
    rig.subs.master.worker.tick_ns = 60 * std.time.ns_per_s;
    rig.subs.worker_stall_ns = 20 * std.time.ns_per_ms;
    _ = try rig.sub(1, "{T1}");
    _ = try rig.sub(2, MASTER_GUID);
    std.Thread.sleep(5 * std.time.ns_per_ms); // the first tick is done, and fresh
    rig.subs.beginPoll();
    _ = try polledPayload(&rig, 1, arena.allocator());
    _ = try polledPayload(&rig, 2, arena.allocator());
    std.Thread.sleep(40 * std.time.ns_per_ms);
    rig.subs.beginPoll();
    for ([_]usize{ 1, 2 }) |client| {
        const slot = rig.subs.client_id_to_slot.get(client).?;
        const out = tuner_generator.analyserEvent(arena.allocator(), &rig.subs, slot, &rig.cache, &rig.api, true);
        try std.testing.expect(out == .none);
    }
    // With the device closed nothing of the reading is sent, so the event is.
    rig.subs.beginPoll();
    const slot = rig.subs.client_id_to_slot.get(1).?;
    try std.testing.expect(tuner_generator.analyserEvent(arena.allocator(), &rig.subs, slot, &rig.cache, &rig.api, false) == .event);
}

test "a source closed and opened again in one poll isn't sent the closed one's snapshot" {
    var rig: InputRig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Workers that tick once, at start, then wait: what the test publishes stays.
    rig.subs.inputs.tick_ns = 60 * std.time.ns_per_s;
    rig.subs.master.worker.tick_ns = 60 * std.time.ns_per_s;
    _ = try rig.sub(1, "{T1}");
    const index = rig.sourceOf(1).?;
    std.Thread.sleep(50 * std.time.ns_per_ms); // its first tick is done
    rig.subs.beginPoll();
    publish(&rig.subs.inputs.source(index).worker, 82.0);
    _ = try polledPayload(&rig, 1, arena.allocator());
    rig.setInput(1, 3); // same poll: the phone moves, and the new source may take the same slot
    const p = try polledPayload(&rig, 1, arena.allocator());
    try std.testing.expectEqual(@as(f64, 0), p.get("freq").?.float);
}

// -----------------------------------------------------------------------------
// What a poll sends a phone: a change at once, and a reading that holds again
// every resend_interval_ms
// -----------------------------------------------------------------------------

test "a reading that holds is sent again every resend interval, and a change at once" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1);
    const slot = rig.subs.client_id_to_slot.get(1).?;
    const t0: u64 = 10_000;
    try std.testing.expect(rig.subs.shouldSend(slot, 7, t0)); // the first, at once
    try std.testing.expect(!rig.subs.shouldSend(slot, 7, t0 + 33));
    try std.testing.expect(!rig.subs.shouldSend(slot, 7, t0 + resend_interval_ms - 1));
    try std.testing.expect(rig.subs.shouldSend(slot, 7, t0 + resend_interval_ms));
    // The interval runs from the last send, a resend included.
    try std.testing.expect(!rig.subs.shouldSend(slot, 7, t0 + resend_interval_ms + 33));
    try std.testing.expect(rig.subs.shouldSend(slot, 8, t0 + resend_interval_ms + 66)); // a change
    try std.testing.expect(!rig.subs.shouldSend(slot, 8, t0 + 2 * resend_interval_ms + 65));
    try std.testing.expect(rig.subs.shouldSend(slot, 8, t0 + 2 * resend_interval_ms + 66));
}

test "each phone's resends run on its own clock" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1);
    _ = try rig.sub(2);
    const a = rig.subs.client_id_to_slot.get(1).?;
    const b = rig.subs.client_id_to_slot.get(2).?;
    const t0: u64 = 10_000;
    try std.testing.expect(rig.subs.shouldSend(a, 7, t0));
    // Phone 2's first event goes 100 ms later: its resend is due 100 ms
    // after phone 1's, and phone 1's sends don't move it.
    try std.testing.expect(rig.subs.shouldSend(b, 7, t0 + 100));
    try std.testing.expect(rig.subs.shouldSend(a, 7, t0 + resend_interval_ms));
    try std.testing.expect(!rig.subs.shouldSend(b, 7, t0 + resend_interval_ms));
    try std.testing.expect(rig.subs.shouldSend(b, 7, t0 + 100 + resend_interval_ms));
    // A change for one phone is sent to it alone.
    try std.testing.expect(rig.subs.shouldSend(a, 9, t0 + resend_interval_ms + 133));
    try std.testing.expect(!rig.subs.shouldSend(b, 7, t0 + resend_interval_ms + 133));
}

test "a phone subscribing again is sent its first event at once, though one went out within the interval" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1);
    const slot = rig.subs.client_id_to_slot.get(1).?;
    try std.testing.expect(rig.subs.shouldSend(slot, 7, 10_000));
    _ = try rig.sub(1);
    try std.testing.expect(rig.subs.shouldSend(slot, 7, 10_033));
}

test "with no clock, a poll sends every reading rather than none again" {
    var rig: MasterRig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.sub(1);
    const slot = rig.subs.client_id_to_slot.get(1).?;
    try std.testing.expect(rig.subs.shouldSend(slot, 7, null));
    try std.testing.expect(rig.subs.shouldSend(slot, 7, null));
}

test "the poll's clock moves on in milliseconds" {
    var subs = TunerSubscriptions.init(std.testing.allocator);
    defer subs.deinit();
    const a = subs.nowMs() orelse return error.SkipZigTest;
    std.Thread.sleep(5 * std.time.ns_per_ms);
    const b = subs.nowMs().?;
    try std.testing.expect(b >= a + 4);
}
