/// Audio hook module: one registration with REAPER's Audio_RegHardwareHook,
/// shared by everything that needs the post-master output, on the real-time
/// audio thread.
///
/// Two users hold it: audio streaming (stream.zig) and the master tuner
/// (subscriptions/master_tuner.zig). The hook is registered while either
/// holds it and unregistered when the last lets go, so the two never fight
/// over registration. Its post callback copies hardware output channels 0/1
/// into each holding user's lock-free single-producer/single-consumer ring:
/// interleaved i16 for the stream's network thread, mono f32, (L + R) / 2,
/// for the tuner's main-thread analysis.
///
/// acquire and release run on the main thread only; the audio thread reads
/// which users hold the hook from one atomic.
const std = @import("std");
const raw = @import("../reaper/raw.zig");
const ring_buffer = @import("ring_buffer.zig");
const mono_ring = @import("mono_ring.zig");
const logging = @import("../core/logging.zig");

pub const User = enum(u8) {
    stream = 1,
    tuner = 2,
};

pub const Hook = struct {
    /// The registration REAPER holds a pointer to while registered.
    reg: raw.AudioHookRegister = .{ .OnAudioBuffer = onAudioBuffer },
    /// The users holding the hook, as a set of `User` bits. Written on the
    /// main thread, read by the audio thread at each post callback.
    users: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Whether REAPER has the hook. Main thread only.
    registered: bool = false,
    /// Interleaved stereo i16 for the stream's network thread.
    stream_ring: ring_buffer.AudioRingBuffer = .{},
    /// Mono f32 for the tuner.
    tuner_ring: mono_ring.MonoRing = .{},

    /// Take the hook for `user`, registering it with REAPER if nobody held
    /// it. `api` is anything with REAPER's registerAudioHook and
    /// unregisterAudioHook (raw.Api, or a backend). Returns false, leaving
    /// `user` without it, if REAPER refuses. Holding it already is a no-op.
    /// Main thread.
    pub fn acquire(self: *Hook, api: anytype, user: User) bool {
        const bit = @intFromEnum(user);
        const held = self.users.load(.acquire);
        if (held & bit != 0) return true;
        if (!self.registered) {
            // No producer runs: the rings can start from empty.
            self.stream_ring.reset();
            self.tuner_ring.reset();
            self.users.store(held | bit, .release);
            if (!api.registerAudioHook(&self.reg)) {
                self.users.store(held, .release);
                return false; // the caller logs it, with its context
            }
            self.registered = true;
            logging.debug("Audio hook registered (for the {s})", .{@tagName(user)});
            return true;
        }
        // The audio thread writes this user's ring from its next callback.
        // Anything left in it from an earlier hold is stale: drop it, as its
        // consumer may (the stream's thread hasn't started; the tuner reads
        // only on the main thread).
        self.users.store(held | bit, .release);
        switch (user) {
            .stream => self.stream_ring.discard(),
            .tuner => self.tuner_ring.discard(),
        }
        return true;
    }

    /// Let go of the hook for `user`, unregistering it once nobody holds it.
    /// Not holding it is a no-op. Main thread.
    pub fn release(self: *Hook, api: anytype, user: User) void {
        const bit = @intFromEnum(user);
        const held = self.users.load(.acquire);
        if (held & bit == 0) return;
        self.users.store(held & ~bit, .release);
        if (held & ~bit == 0 and self.registered) {
            api.unregisterAudioHook(&self.reg);
            self.registered = false;
            logging.debug("Audio hook unregistered", .{});
        }
    }

    /// Unregister whatever still holds the hook: for shutdown, so REAPER
    /// never calls into an unloaded extension. Main thread.
    pub fn releaseAll(self: *Hook, api: anytype) void {
        self.users.store(0, .release);
        if (self.registered) {
            api.unregisterAudioHook(&self.reg);
            self.registered = false;
            logging.debug("Audio hook unregistered at shutdown", .{});
        }
    }

    pub fn holds(self: *const Hook, user: User) bool {
        return self.users.load(.acquire) & @intFromEnum(user) != 0;
    }

    /// The callback's work, on the audio thread. REAL-TIME SAFE: no
    /// allocation, no lock, no I/O, no logging.
    fn process(self: *Hook, is_post: bool, len: c_int, srate: f64) void {
        _ = diag_callback_count.fetchAdd(1, .monotonic);

        const sample_count: usize = if (len > 0) @intCast(len) else return;

        // GetBuffer is set by REAPER host — must check
        const get_buffer = self.reg.GetBuffer orelse {
            _ = diag_no_getbuffer.fetchAdd(1, .monotonic);
            return;
        };

        if (!is_post) {
            // PRE-CALLBACK: Zero output buffers before REAPER's mixer runs.
            // When transport is playing, the mixer overwrites these with fresh audio.
            // When transport is stopped, the buffers stay zeroed — eliminating stale
            // data that would otherwise repeat as a loud buzz at sampleRate/bufferSize Hz.
            // Monitoring input (guitar/vocals) still works because the mixer processes
            // live signal even when stopped, overwriting our zeros with real audio.
            // Don't iterate output_nch — REAPER may not set it in the struct.
            if (get_buffer(true, 0)) |buf| @memset(buf[0..sample_count], 0.0);
            if (get_buffer(true, 1)) |buf| @memset(buf[0..sample_count], 0.0);
            return;
        }

        _ = diag_post_count.fetchAdd(1, .monotonic);

        // Store last observed output_nch for diagnostics
        diag_last_nch.store(self.reg.output_nch, .monotonic);

        // Get left and right output channels directly from GetBuffer.
        // Don't check output_nch — REAPER may not set it in the struct.
        const left = get_buffer(true, 0) orelse {
            _ = diag_no_left.fetchAdd(1, .monotonic);
            return;
        };
        const right = get_buffer(true, 1) orelse return;

        const users = self.users.load(.acquire);
        if (users & @intFromEnum(User.stream) != 0) {
            // A rate outside u32, or NaN, can't be stored; the stream keeps
            // the last good one.
            if (srate >= 1 and srate <= std.math.maxInt(u32)) {
                self.stream_ring.sample_rate.store(@intFromFloat(srate), .release);
            }
            self.stream_ring.writeFromF64(left, right, sample_count);
        }
        if (users & @intFromEnum(User.tuner) != 0) {
            self.tuner_ring.write(left, right, sample_count, srate);
        }
        _ = diag_write_count.fetchAdd(1, .monotonic);
    }
};

/// The hook REAPER is given. Module-level so it, and the pointer REAPER
/// keeps to its registration, live as long as the extension.
var g_hook: Hook = .{};

// Diagnostic counters (atomic, safe to read from any thread)
pub var diag_callback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_post_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_no_getbuffer: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_low_nch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_no_left: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_write_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var diag_last_nch: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

// ============================================================================
// Public API
// ============================================================================

/// The extension's one hook.
pub fn instance() *Hook {
    return &g_hook;
}

/// The stream's ring, for its network thread to read from.
pub fn getRingBuffer() *ring_buffer.AudioRingBuffer {
    return &g_hook.stream_ring;
}

/// Whether REAPER has the hook now.
pub fn isRegistered() bool {
    return g_hook.registered;
}

// ============================================================================
// Audio thread callback
// ============================================================================

/// Called by REAPER on the audio thread, twice per buffer (pre and post processing).
fn onAudioBuffer(isPost: bool, len: c_int, srate: f64, reg: *raw.AudioHookRegister) callconv(.c) void {
    const hook: *Hook = @fieldParentPtr("reg", reg);
    hook.process(isPost, len, srate);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Stands in for REAPER's Audio_RegHardwareHook.
pub const FakeRegistrar = struct {
    holding: ?*raw.AudioHookRegister = null,
    registers: u32 = 0,
    unregisters: u32 = 0,
    refuse: bool = false,

    pub fn registerAudioHook(self: *FakeRegistrar, reg: *raw.AudioHookRegister) bool {
        if (self.refuse) return false;
        self.registers += 1;
        self.holding = reg;
        return true;
    }

    pub fn unregisterAudioHook(self: *FakeRegistrar, reg: *raw.AudioHookRegister) void {
        std.debug.assert(self.holding == reg);
        self.unregisters += 1;
        self.holding = null;
    }
};

/// A fake device for driving a hook's callback from a test: two output
/// channels REAPER's GetBuffer hands out. GetBuffer takes no context, so
/// the channels are module-level, as REAPER's own are per-callback.
pub const FakeDevice = struct {
    pub var out: [2][8192]f64 = undefined;

    fn getBuffer(is_output: bool, idx: c_int) callconv(.c) ?[*]f64 {
        if (!is_output or idx < 0 or idx > 1) return null;
        return &out[@intCast(idx)];
    }

    /// One audio block as REAPER runs it: the pre callback, the mixer
    /// writing `left` and `right` to outputs 0/1, the post callback.
    pub fn block(hook: *Hook, left: []const f64, right: []const f64, srate: f64) void {
        hook.reg.GetBuffer = getBuffer;
        const len: c_int = @intCast(left.len);
        hook.reg.OnAudioBuffer(false, len, srate, &hook.reg);
        @memcpy(out[0][0..left.len], left);
        @memcpy(out[1][0..right.len], right);
        hook.reg.OnAudioBuffer(true, len, srate, &hook.reg);
    }
};

fn newHook() !*Hook {
    const hook = try testing.allocator.create(Hook);
    hook.* = .{};
    return hook;
}

test "the stream and the tuner share one registration, held until both let go" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};

    try testing.expect(hook.acquire(&reaper, .stream));
    try testing.expect(hook.acquire(&reaper, .tuner));
    try testing.expectEqual(@as(u32, 1), reaper.registers);

    hook.release(&reaper, .stream);
    try testing.expect(hook.registered);
    try testing.expectEqual(@as(u32, 0), reaper.unregisters);

    hook.release(&reaper, .tuner);
    try testing.expect(!hook.registered);
    try testing.expectEqual(@as(u32, 1), reaper.unregisters);
    try testing.expectEqual(@as(?*raw.AudioHookRegister, null), reaper.holding);
}

test "whichever of the two comes first registers, and the last to go unregisters" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};

    try testing.expect(hook.acquire(&reaper, .tuner));
    try testing.expect(hook.acquire(&reaper, .stream));
    hook.release(&reaper, .tuner);
    try testing.expect(hook.registered);
    try testing.expect(hook.holds(.stream) and !hook.holds(.tuner));
    hook.release(&reaper, .stream);
    try testing.expect(!hook.registered);
    try testing.expectEqual(@as(u32, 1), reaper.registers);
    try testing.expectEqual(@as(u32, 1), reaper.unregisters);
}

test "acquiring twice or releasing what isn't held changes nothing" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};

    hook.release(&reaper, .tuner);
    try testing.expectEqual(@as(u32, 0), reaper.unregisters);
    try testing.expect(hook.acquire(&reaper, .tuner));
    try testing.expect(hook.acquire(&reaper, .tuner));
    try testing.expectEqual(@as(u32, 1), reaper.registers);
    hook.release(&reaper, .stream);
    try testing.expect(hook.registered);
    hook.release(&reaper, .tuner);
    hook.release(&reaper, .tuner);
    try testing.expectEqual(@as(u32, 1), reaper.unregisters);
}

test "a refused registration leaves nobody holding the hook, and a later try can succeed" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{ .refuse = true };

    try testing.expect(!hook.acquire(&reaper, .tuner));
    try testing.expect(!hook.registered and !hook.holds(.tuner));
    reaper.refuse = false;
    try testing.expect(hook.acquire(&reaper, .tuner));
    try testing.expect(hook.registered);
}

test "releaseAll unregisters a hook still held, for shutdown" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    _ = hook.acquire(&reaper, .stream);
    _ = hook.acquire(&reaper, .tuner);
    hook.releaseAll(&reaper);
    try testing.expect(!hook.registered and !hook.holds(.stream) and !hook.holds(.tuner));
    try testing.expectEqual(@as(u32, 1), reaper.unregisters);
    hook.releaseAll(&reaper);
    try testing.expectEqual(@as(u32, 1), reaper.unregisters);
}

test "the post callback feeds only the users holding the hook" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    const left = [_]f64{0.5} ** 64;
    const right = [_]f64{0.25} ** 64;

    _ = hook.acquire(&reaper, .tuner);
    FakeDevice.block(hook, &left, &right, 48000);
    try testing.expectEqual(@as(usize, 64), hook.tuner_ring.available());
    try testing.expectEqual(@as(usize, 0), hook.stream_ring.available());

    _ = hook.acquire(&reaper, .stream);
    FakeDevice.block(hook, &left, &right, 48000);
    try testing.expectEqual(@as(usize, 128), hook.tuner_ring.available());
    try testing.expectEqual(@as(usize, 64), hook.stream_ring.available());

    hook.release(&reaper, .tuner);
    FakeDevice.block(hook, &left, &right, 48000);
    try testing.expectEqual(@as(usize, 128), hook.tuner_ring.available());
    try testing.expectEqual(@as(usize, 128), hook.stream_ring.available());

    var mono: [1]f32 = undefined;
    _ = hook.tuner_ring.read(&mono);
    try testing.expectEqual(@as(f32, 0.375), mono[0]);
}

test "a user taking the hook again starts from fresh audio, not what it left unread" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    const a = [_]f64{0.5} ** 32;
    const b = [_]f64{-0.5} ** 32;

    _ = hook.acquire(&reaper, .stream); // keeps the hook registered throughout
    _ = hook.acquire(&reaper, .tuner);
    FakeDevice.block(hook, &a, &a, 48000);
    hook.release(&reaper, .tuner);
    _ = hook.acquire(&reaper, .tuner);
    FakeDevice.block(hook, &b, &b, 48000);
    var mono: [64]f32 = undefined;
    const got = hook.tuner_ring.read(&mono);
    try testing.expectEqual(@as(usize, 32), got.n);
    try testing.expectEqual(@as(f32, -0.5), mono[0]);

    // The same for the stream, which the tuner kept registered meanwhile.
    hook.release(&reaper, .stream);
    FakeDevice.block(hook, &a, &a, 48000);
    _ = hook.acquire(&reaper, .stream);
    try testing.expectEqual(@as(usize, 0), hook.stream_ring.available());
}

test "a sample rate the stream can't store keeps its last good one" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    const x = [_]f64{0.1} ** 8;
    _ = hook.acquire(&reaper, .stream);
    FakeDevice.block(hook, &x, &x, 44100);
    for ([_]f64{ std.math.nan(f64), -1, 1e12 }) |bad| FakeDevice.block(hook, &x, &x, bad);
    try testing.expectEqual(@as(u32, 44100), hook.stream_ring.sample_rate.load(.acquire));
}

test "the pre callback zeroes outputs 0/1 before the mixer runs" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    hook.reg.GetBuffer = FakeDevice.getBuffer;
    @memset(&FakeDevice.out[0], 0.9);
    @memset(&FakeDevice.out[1], 0.9);
    hook.reg.OnAudioBuffer(false, 16, 48000, &hook.reg);
    for (FakeDevice.out[0][0..16]) |s| try testing.expectEqual(@as(f64, 0), s);
    for (FakeDevice.out[1][0..16]) |s| try testing.expectEqual(@as(f64, 0), s);
}

test "getRingBuffer returns stable pointer" {
    const rb1 = getRingBuffer();
    const rb2 = getRingBuffer();
    try std.testing.expectEqual(rb1, rb2);
}

test "acquire with a REAPER that has no audio hook API fails cleanly" {
    // With a default Api where audioRegHardwareHook is null,
    // acquire should return false (graceful degradation)
    const api = raw.Api{
        .showConsoleMsg = undefined,
        .register = undefined,
    };
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    try std.testing.expect(!hook.acquire(&api, .stream));
    try std.testing.expect(!hook.registered);
}
