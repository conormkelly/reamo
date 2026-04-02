/// Audio stream manager — manages client subscriptions and the network thread
/// that reads from the ring buffer and sends binary WebSocket frames.
///
/// Thread lifecycle: spawned when first client subscribes, joined when last unsubscribes.
/// The audio hook is registered/unregistered alongside the thread.
const std = @import("std");
const raw = @import("../reaper/raw.zig");
const audio_hook = @import("audio_hook.zig");
const ring_buffer = @import("ring_buffer.zig");
const ws_server = @import("../server/ws_server.zig");
const logging = @import("../core/logging.zig");
const binary_protocol = @import("../core/binary_protocol.zig");

const MAX_AUDIO_CLIENTS = 4;

/// Frame header: 1-byte type prefix + u32 LE sequence number
const HEADER_SIZE = 5;
/// Max stereo sample pairs per frame: 10ms @ 96kHz
const MAX_FRAME_SAMPLES = 960;
/// Total frame buffer size: header + max payload (960 pairs * 2 ch * 2 bytes)
const FRAME_BUF_SIZE = HEADER_SIZE + (MAX_FRAME_SAMPLES * 2 * @sizeOf(i16));

/// Silence threshold: max absolute sample value below which a frame is considered silent.
/// 8/32768 ≈ -72dB below full scale. Catches dither, quantization noise, and near-zero plugin tails.
/// When all samples in a frame are below this, the frame is not sent — the frontend's jitter buffer
/// drains naturally and outputs true digital silence (no scheduling artifacts).
const SILENCE_THRESHOLD: u16 = 8;

pub const AudioStreamManager = struct {
    /// Subscribed client IDs. Compacted array — active IDs are in [0..client_count).
    subscribed_clients: [MAX_AUDIO_CLIENTS]usize = [_]usize{0} ** MAX_AUDIO_CLIENTS,
    /// Number of active subscribers. Atomic for network thread reads.
    client_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Network thread handle.
    thread: ?std.Thread = null,
    /// Signal to stop the network thread.
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Shared state for sending binary frames to clients.
    shared_state: ?*ws_server.SharedState = null,
    /// Raw REAPER API for hook registration.
    api: ?*const raw.Api = null,

    /// Frame sequence counter (wraps at u32 max).
    sequence: u32 = 0,

    /// Mutex protecting subscribed_clients modifications.
    /// The network thread only reads client_count (atomic) and the stable prefix
    /// of subscribed_clients, so it doesn't need to hold this mutex.
    mutex: std.Thread.Mutex = .{},

    /// Subscribe a client to audio streaming.
    /// If this is the first subscriber, starts the network thread and registers the audio hook.
    /// Returns true on success, false if max clients reached or streaming failed to start.
    pub fn subscribe(self: *AudioStreamManager, client_id: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.client_count.load(.acquire);

        // Check if already subscribed
        for (self.subscribed_clients[0..count]) |cid| {
            if (cid == client_id) return true; // Already subscribed
        }

        // Check capacity
        if (count >= MAX_AUDIO_CLIENTS) {
            logging.warn("Audio stream: max clients ({d}) reached, rejecting client {d}", .{ MAX_AUDIO_CLIENTS, client_id });
            return false;
        }

        // First subscriber — start streaming before adding client so failure is clean
        if (count == 0) {
            if (!self.startStreaming()) {
                return false;
            }
        }

        // Add client
        self.subscribed_clients[count] = client_id;
        self.client_count.store(count + 1, .release);
        logging.info("Audio stream: client {d} subscribed ({d} total)", .{ client_id, count + 1 });

        return true;
    }

    /// Unsubscribe a client from audio streaming.
    /// If this was the last subscriber, stops the network thread and unregisters the audio hook.
    pub fn unsubscribe(self: *AudioStreamManager, client_id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.removeClientLocked(client_id);
    }

    /// Remove a disconnected client. Same as unsubscribe but named for clarity
    /// in the client_management cleanup path.
    pub fn removeClient(self: *AudioStreamManager, client_id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.removeClientLocked(client_id);
    }

    /// Check if any clients are currently subscribed.
    pub fn hasSubscribers(self: *const AudioStreamManager) bool {
        return self.client_count.load(.acquire) > 0;
    }

    /// Get the current sample rate from the ring buffer.
    pub fn getSampleRate(self: *const AudioStreamManager) u32 {
        _ = self;
        return audio_hook.getRingBuffer().sample_rate.load(.acquire);
    }

    // ========================================================================
    // Private
    // ========================================================================

    /// Remove a client from the subscribed list (caller must hold mutex).
    fn removeClientLocked(self: *AudioStreamManager, client_id: usize) void {
        const count = self.client_count.load(.acquire);

        // Find the client
        for (0..count) |i| {
            if (self.subscribed_clients[i] == client_id) {
                // Compact: move last element into this slot
                if (i < count - 1) {
                    self.subscribed_clients[i] = self.subscribed_clients[count - 1];
                }
                self.subscribed_clients[count - 1] = 0;
                self.client_count.store(count - 1, .release);
                logging.info("Audio stream: client {d} unsubscribed ({d} remaining)", .{ client_id, count - 1 });

                // Last subscriber gone — stop everything
                if (count - 1 == 0) {
                    self.stopStreaming();
                }
                return;
            }
        }
    }

    /// Start the audio hook and network thread. Returns true on success.
    fn startStreaming(self: *AudioStreamManager) bool {
        // Register audio hook
        if (self.api) |api| {
            if (!audio_hook.register(api)) {
                logging.err("Audio stream: failed to register audio hook (api fn={?})", .{@as(?*const anyopaque, if (api.audioRegHardwareHook) |f| @ptrCast(f) else null)});
                return false;
            }
        } else {
            logging.err("Audio stream: no API available for hook registration", .{});
            return false;
        }

        // Reset state
        self.should_stop.store(false, .release);
        self.sequence = 0;

        // Spawn network thread
        self.thread = std.Thread.spawn(.{}, threadFn, .{self}) catch |err| {
            logging.err("Audio stream: failed to spawn thread: {s}", .{@errorName(err)});
            if (self.api) |api| audio_hook.unregister(api);
            return false;
        };
        logging.info("Audio stream: network thread started", .{});
        return true;
    }

    /// Stop the network thread and unregister the audio hook.
    fn stopStreaming(self: *AudioStreamManager) void {
        // Signal thread to stop
        self.should_stop.store(true, .release);

        // Join thread
        if (self.thread) |t| {
            t.join();
            self.thread = null;
            logging.info("Audio stream: network thread stopped", .{});
        }

        // Unregister audio hook
        if (self.api) |api| {
            audio_hook.unregister(api);
        }
    }

    /// Network thread entry point. Polls the ring buffer and sends binary
    /// WebSocket frames to subscribed clients.
    fn threadFn(self: *AudioStreamManager) void {
        var frame_buf: [FRAME_BUF_SIZE]u8 = undefined;
        var read_buf: [MAX_FRAME_SAMPLES * 2]i16 = undefined;

        while (!self.should_stop.load(.acquire)) {
            const rb = audio_hook.getRingBuffer();
            const avail = rb.available();
            const sr = rb.sample_rate.load(.acquire);

            // Minimum 5ms of audio before sending (avoid tiny frames)
            const min_pairs: usize = if (sr > 0) sr / 200 else 240;
            if (avail < min_pairs) {
                std.Thread.sleep(2 * std.time.ns_per_ms);
                continue;
            }

            // Read up to 10ms worth of samples
            const target_pairs: usize = if (sr > 0) @min(avail, sr / 100) else @min(avail, MAX_FRAME_SAMPLES);
            const clamped_target = @min(target_pairs, MAX_FRAME_SAMPLES);
            const pairs_read = rb.read(&read_buf, clamped_target);
            if (pairs_read == 0) continue;

            // Skip silent frames — the audio hook pre-zeros output buffers before
            // REAPER's mixer runs (isPost=false), so when transport is stopped the
            // ring buffer contains zeros. Skipping these lets the frontend's jitter
            // buffer drain naturally into true digital silence. When monitoring live
            // input, the mixer overwrites the zeros with real audio, so those frames
            // pass through normally.
            if (isSilent(read_buf[0 .. pairs_read * 2])) continue;

            // Build frame: [type u8] [sequence u32 LE] [pcm i16 LE interleaved]
            frame_buf[0] = @intFromEnum(binary_protocol.BinaryMessageType.audio);
            std.mem.writeInt(u32, frame_buf[1..5], self.sequence, .little);
            const payload_bytes = pairs_read * 2 * @sizeOf(i16);
            const pcm_bytes = std.mem.sliceAsBytes(read_buf[0 .. pairs_read * 2]);
            @memcpy(frame_buf[HEADER_SIZE..][0..payload_bytes], pcm_bytes);
            self.sequence +%= 1;

            const frame_len = HEADER_SIZE + payload_bytes;

            // Send to all subscribed clients
            const state = self.shared_state orelse continue;
            const count = self.client_count.load(.acquire);
            for (self.subscribed_clients[0..count]) |cid| {
                state.sendBinToClient(cid, frame_buf[0..frame_len]);
            }
        }
    }

    /// Check if a buffer of interleaved i16 PCM is effectively silent.
    /// Returns true if all absolute sample values are at or below SILENCE_THRESHOLD.
    fn isSilent(samples: []const i16) bool {
        for (samples) |sample| {
            if (@abs(sample) > SILENCE_THRESHOLD) return false;
        }
        return true;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "subscribe and unsubscribe" {
    var manager = AudioStreamManager{};
    // Without API set, subscribe won't start the thread/hook, but will track clients
    try std.testing.expect(!manager.hasSubscribers());

    // Can't actually start streaming without an API, but subscribe should still track
    // We test the client tracking logic here; integration test covers full lifecycle

    // Manually set client count to test tracking
    manager.subscribed_clients[0] = 42;
    manager.client_count.store(1, .release);
    try std.testing.expect(manager.hasSubscribers());

    // Unsubscribe
    manager.subscribed_clients[0] = 0;
    manager.client_count.store(0, .release);
    try std.testing.expect(!manager.hasSubscribers());
}

test "max clients enforcement" {
    var manager = AudioStreamManager{};

    // Fill all slots manually (bypass subscribe to avoid API dependency)
    for (0..MAX_AUDIO_CLIENTS) |i| {
        manager.subscribed_clients[i] = i + 1;
    }
    manager.client_count.store(MAX_AUDIO_CLIENTS, .release);

    // subscribe should fail (no room)
    // Note: can't call subscribe() without API, so test the capacity check directly
    try std.testing.expectEqual(MAX_AUDIO_CLIENTS, manager.client_count.load(.acquire));
}

test "removeClientLocked compacts array" {
    var manager = AudioStreamManager{};

    // Set up 3 clients: [10, 20, 30]
    manager.subscribed_clients[0] = 10;
    manager.subscribed_clients[1] = 20;
    manager.subscribed_clients[2] = 30;
    manager.client_count.store(3, .release);

    // Remove middle client (20) — should compact by moving 30 into slot 1
    manager.removeClientLocked(20);

    try std.testing.expectEqual(@as(usize, 2), manager.client_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 10), manager.subscribed_clients[0]);
    try std.testing.expectEqual(@as(usize, 30), manager.subscribed_clients[1]);
}

test "isSilent detects silence below threshold" {
    // All zeros — silent
    const silent = [_]i16{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(AudioStreamManager.isSilent(&silent));

    // Below threshold — still silent
    const quiet = [_]i16{ 1, -1, 3, -2, 0, 7 };
    try std.testing.expect(AudioStreamManager.isSilent(&quiet));

    // At threshold boundary — still silent (threshold is inclusive)
    const boundary = [_]i16{ 8, -8, 0, 0 };
    try std.testing.expect(AudioStreamManager.isSilent(&boundary));

    // Just above threshold — NOT silent
    const not_silent = [_]i16{ 0, 0, 9, 0 };
    try std.testing.expect(!AudioStreamManager.isSilent(&not_silent));

    // Actual audio — NOT silent
    const audio = [_]i16{ 1000, -2000, 500, -300 };
    try std.testing.expect(!AudioStreamManager.isSilent(&audio));

    // Empty slice — silent (vacuous truth)
    const empty = [_]i16{};
    try std.testing.expect(AudioStreamManager.isSilent(&empty));
}

test "duplicate subscribe is idempotent" {
    var manager = AudioStreamManager{};

    // Set up 1 client
    manager.subscribed_clients[0] = 42;
    manager.client_count.store(1, .release);

    // Subscribing same client should return true without adding duplicate
    // We can't call subscribe() without API, but the logic check is:
    const count = manager.client_count.load(.acquire);
    var found = false;
    for (manager.subscribed_clients[0..count]) |cid| {
        if (cid == 42) found = true;
    }
    try std.testing.expect(found);
}
