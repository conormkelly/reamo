/// Audio hook module: one registration with REAPER's Audio_RegHardwareHook,
/// shared by everything that needs the device's audio, on the real-time
/// audio thread.
///
/// Three users hold it: audio streaming (stream.zig), the master tuner
/// (subscriptions/master_tuner.zig) and the track tuners' input taps
/// (subscriptions/input_tuners.zig). The hook is registered while any holds
/// it and unregistered when the last lets go, so they never fight over
/// registration. Each callback copies into the holding users' lock-free
/// single-producer/single-consumer rings:
/// - the post callback, hardware output channels 0/1: interleaved i16 for
///   the stream's network thread, mono f32, (L + R) / 2, for the master
///   tuner's analysis thread;
/// - the pre callback, before REAPER's processing, each open input tap's
///   hardware input (one channel, or a pair mixed as (L + R) / 2) into the
///   tap's own mono ring, for that input's analysis thread.
///
/// acquire, release and the taps' open and close run on the main thread
/// only; the audio thread reads which users hold the hook, and each tap's
/// channels, from atomics.
const std = @import("std");
const raw = @import("../reaper/raw.zig");
const ring_buffer = @import("ring_buffer.zig");
const mono_ring = @import("mono_ring.zig");
const logging = @import("../core/logging.zig");
const no_alloc = @import("../core/no_alloc.zig");
const constants = @import("../core/constants.zig");

pub const User = enum(u8) {
    stream = 1,
    tuner = 2,
    inputs = 4,
};

/// Input taps: one per hardware input source a track tuner reads. Each
/// phone tunes one source at a time, so there are as many as phones.
pub const max_taps = constants.MAX_SUBSCRIPTION_CLIENTS;

/// The hardware input channels a tap reads, by the hook's input index
/// (GetBuffer(false, i)), from 0.
pub const Channels = struct {
    first: u16,
    /// `first` and `first + 1`, mixed to mono as (L + R) / 2.
    stereo: bool,

    pub fn eql(a: Channels, b: Channels) bool {
        return a.first == b.first and a.stereo == b.stereo;
    }

    /// As a tap's config: 0 is no tap, so the tag (never 0) is in it.
    fn pack(self: Channels, tag: u32) u64 {
        return (@as(u64, tag) << 32) | (@as(u64, @intFromBool(self.stereo)) << 16) | self.first;
    }

    fn unpack(config: u64) struct { channels: Channels, tag: u32 } {
        return .{
            .channels = .{ .first = @truncate(config), .stereo = (config >> 16) & 1 != 0 },
            .tag = @truncate(config >> 32),
        };
    }
};

/// One input tap: which channels the audio thread copies, and the ring it
/// copies them into.
pub const Tap = struct {
    /// 0 while the tap is closed, else its channels and tag packed.
    /// Written on the main thread, read by the audio thread at each pre
    /// callback.
    config: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Written under the tap's tag, so a reader never gets samples from
    /// the input the tap had before.
    ring: mono_ring.MonoRing = .{},
};

/// An open tap: its index, and the tag its samples are written under.
pub const TapHandle = struct { index: u8, tag: u32 };

pub const OpenTapError = error{ NoFreeTap, AudioHookFailed };

/// Every field's default is zero, so g_hook, about 5 MB of rings, is
/// zero-fill and adds nothing to the extension's file; a non-zero default
/// anywhere in it puts the whole of it in the file's data.
pub const Hook = struct {
    /// The registration REAPER holds a pointer to while registered. Its
    /// callback is set as it is registered.
    reg: raw.AudioHookRegister = .{},
    /// The users holding the hook, as a set of `User` bits. Written on the
    /// main thread, read by the audio thread at each post callback.
    users: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Whether REAPER has the hook. Main thread only.
    registered: bool = false,
    /// Interleaved stereo i16 for the stream's network thread.
    stream_ring: ring_buffer.AudioRingBuffer = .{},
    /// Mono f32 for the tuner.
    tuner_ring: mono_ring.MonoRing = .{},
    /// Post callbacks in which REAPER gave no output 1 (a device with no
    /// outputs), and no output 2 (a mono device). Audio thread writes;
    /// anyone reads.
    missing_output_1: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    missing_output_2: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// The track tuners' input taps.
    taps: [max_taps]Tap = [_]Tap{.{}} ** max_taps,
    /// The last tag a tap was opened under. Main thread only.
    last_tag: u32 = 0,

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
            for (&self.taps) |*tap| tap.ring.reset();
            self.users.store(held | bit, .release);
            self.reg.OnAudioBuffer = onAudioBuffer;
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
        // consumer may, since that consumer hasn't started (the stream's
        // network thread, the master tuner's analysis thread). A tap's
        // reader skips it by the tap's tag instead.
        self.users.store(held | bit, .release);
        switch (user) {
            .stream => self.stream_ring.discard(),
            .tuner => self.tuner_ring.discard(),
            .inputs => {},
        }
        return true;
    }

    /// Open an input tap on `channels`, taking the hook for the inputs if
    /// no tap was open. Its samples are written under the returned tag from
    /// the next pre callback; read them with `tapRing(index).readTagged`.
    /// Main thread.
    pub fn openTap(self: *Hook, api: anytype, channels: Channels) OpenTapError!TapHandle {
        const index = for (&self.taps, 0..) |*tap, i| {
            if (tap.config.load(.acquire) == 0) break i;
        } else return error.NoFreeTap;
        if (!self.acquire(api, .inputs)) return error.AudioHookFailed;
        self.last_tag +%= 1;
        if (self.last_tag == 0) self.last_tag = 1;
        self.taps[index].config.store(channels.pack(self.last_tag), .release);
        return .{ .index = @intCast(index), .tag = self.last_tag };
    }

    /// Close an input tap, letting go of the hook for the inputs once none
    /// is open. The audio thread may still be finishing a block into its
    /// ring; the tap's next reader, on another tag, never reads it. Closing
    /// a closed tap is a no-op. Main thread.
    pub fn closeTap(self: *Hook, api: anytype, index: u8) void {
        if (self.taps[index].config.load(.acquire) == 0) return;
        self.taps[index].config.store(0, .release);
        for (&self.taps) |*tap| {
            if (tap.config.load(.acquire) != 0) return;
        }
        self.release(api, .inputs);
    }

    /// The ring an input tap's samples are written to.
    pub fn tapRing(self: *Hook, index: u8) *mono_ring.MonoRing {
        return &self.taps[index].ring;
    }

    /// The input taps open now. Main thread.
    pub fn openTaps(self: *const Hook) usize {
        var n: usize = 0;
        for (&self.taps) |*tap| n += @intFromBool(tap.config.load(.acquire) != 0);
        return n;
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
        for (&self.taps) |*tap| tap.config.store(0, .release);
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
            // The hardware inputs as the device delivered them, before
            // REAPER processes anything.
            if (self.users.load(.acquire) & @intFromEnum(User.inputs) != 0) {
                for (&self.taps) |*tap| self.copyInput(tap, get_buffer, sample_count, srate);
            }
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
            _ = self.missing_output_1.fetchAdd(1, .monotonic);
            return;
        };
        const maybe_right = get_buffer(true, 1);
        if (maybe_right == null) _ = self.missing_output_2.fetchAdd(1, .monotonic);

        const users = self.users.load(.acquire);
        // The tuner reads output 1 alone on a one-output device; the stream
        // sends stereo pairs, so it has nothing to send there.
        if (users & @intFromEnum(User.tuner) != 0) {
            self.tuner_ring.write(left, maybe_right orelse left, sample_count, srate);
        }
        const right = maybe_right orelse return;
        if (users & @intFromEnum(User.stream) != 0) {
            // A rate outside u32, or NaN, can't be stored; the stream keeps
            // the last good one.
            if (srate >= 1 and srate <= std.math.maxInt(u32)) {
                self.stream_ring.sample_rate.store(@intFromFloat(srate), .release);
            }
            self.stream_ring.writeFromF64(left, right, sample_count);
        }
        _ = diag_write_count.fetchAdd(1, .monotonic);
    }

    /// An open tap's input into its ring, on the audio thread. A channel
    /// REAPER gives no buffer for (past the device's inputs) writes
    /// nothing: a pair isn't read as one channel. REAL-TIME SAFE.
    fn copyInput(_: *Hook, tap: *Tap, get_buffer: *const fn (bool, c_int) callconv(.c) ?[*]f64, len: usize, srate: f64) void {
        const config = tap.config.load(.acquire);
        if (config == 0) return;
        const c = Channels.unpack(config);
        const left = get_buffer(false, c.channels.first) orelse return;
        const right = if (c.channels.stereo) get_buffer(false, @as(c_int, c.channels.first) + 1) orelse return else left;
        tap.ring.writeTagged(left, right, len, srate, c.tag);
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

/// The rate to tell a listener the stream is at, given the open device's
/// rate (0 with no device open): that rate; with no device open, the rate
/// the hook last ran at; before it has ever run, 48 kHz. audio/startStream
/// and the project event both report this, so the rate a phone's player is
/// built at and the rate it restarts on agree, and a device that reopens at
/// another rate changes it.
///
/// An open device's rate wins over the hook's last one, which can predate a
/// project switch that changed the device's rate.
pub fn streamSampleRate(device_rate: u32) u32 {
    if (device_rate > 0) return device_rate;
    const last = g_hook.stream_ring.sample_rate.load(.acquire);
    return if (last > 0) last else 48000;
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
    /// How many of the two outputs GetBuffer hands out: 1 for a mono
    /// device, 0 for one with none.
    pub var outputs: c_int = 2;
    /// Hardware inputs, and how many GetBuffer hands out (it gives none at
    /// and past the device's input count, as REAPER does).
    pub var in: [8][8192]f64 = undefined;
    pub var inputs: c_int = 8;

    fn getBuffer(is_output: bool, idx: c_int) callconv(.c) ?[*]f64 {
        if (idx < 0) return null;
        if (!is_output) return if (idx < inputs and idx < in.len) &in[@intCast(idx)] else null;
        if (idx >= outputs) return null;
        return &out[@intCast(idx)];
    }

    /// One audio block with `ins` arriving at hardware inputs 0, 1, ...
    /// (the rest silent) and silence out.
    pub fn inputBlock(hook: *Hook, ins: []const []const f64, srate: f64) void {
        hook.reg.GetBuffer = getBuffer;
        const len = ins[0].len;
        for (&in, 0..) |*ch, i| {
            if (i < ins.len) @memcpy(ch[0..len], ins[i]) else @memset(ch[0..len], 0);
        }
        onAudioBuffer(false, @intCast(len), srate, &hook.reg);
        @memset(out[0][0..len], 0);
        @memset(out[1][0..len], 0);
        onAudioBuffer(true, @intCast(len), srate, &hook.reg);
    }

    /// One audio block as REAPER runs it: the pre callback, the mixer
    /// writing `left` and `right` to outputs 0/1, the post callback.
    pub fn block(hook: *Hook, left: []const f64, right: []const f64, srate: f64) void {
        hook.reg.GetBuffer = getBuffer;
        const len: c_int = @intCast(left.len);
        onAudioBuffer(false, len, srate, &hook.reg);
        @memcpy(out[0][0..left.len], left);
        @memcpy(out[1][0..right.len], right);
        onAudioBuffer(true, len, srate, &hook.reg);
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
    onAudioBuffer(false, 16, 48000, &hook.reg);
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

test "the audio thread's path has no allocator, calls none and doesn't log" {
    // REAPER's audio thread must never allocate, lock or log. A tripwire,
    // not a proof (core/no_alloc.zig): no allocator or growing container
    // reachable from the hook's types and the callback's parameters, and no
    // allocation or logging named in the callback, the hook's work (input
    // taps included), the two rings' producer sides and the mono ring's
    // consumer side, tagged or not, or in any same-file function they call.
    if (comptime no_alloc.reachesAllocation(Hook)) @compileError("an allocator or a growing container is reachable from Hook");
    if (comptime no_alloc.paramsReachAllocation(@TypeOf(onAudioBuffer))) @compileError("an allocator or a growing container is reachable from @TypeOf(onAudioBuffer)");
    if (comptime no_alloc.paramsReachAllocation(@TypeOf(Hook.process))) @compileError("an allocator or a growing container is reachable from @TypeOf(Hook.process)");
    const Fn = struct { file: []const u8, source: []const u8, name: []const u8 };
    const hook_src = @embedFile("audio_hook.zig");
    const ring_src = @embedFile("ring_buffer.zig");
    const mono_src = @embedFile("mono_ring.zig");
    const fns = [_]Fn{
        .{ .file = "audio_hook.zig", .source = hook_src, .name = "onAudioBuffer" },
        .{ .file = "audio_hook.zig", .source = hook_src, .name = "process" },
        .{ .file = "audio_hook.zig", .source = hook_src, .name = "copyInput" },
        .{ .file = "ring_buffer.zig", .source = ring_src, .name = "writeFromF64" },
        .{ .file = "ring_buffer.zig", .source = ring_src, .name = "f64ToI16" },
        .{ .file = "mono_ring.zig", .source = mono_src, .name = "write" },
        .{ .file = "mono_ring.zig", .source = mono_src, .name = "writeTagged" },
        .{ .file = "mono_ring.zig", .source = mono_src, .name = "read" },
        .{ .file = "mono_ring.zig", .source = mono_src, .name = "readTagged" },
        .{ .file = "mono_ring.zig", .source = mono_src, .name = "discard" },
    };
    for (fns) |f| {
        for ([_][]const []const u8{ &no_alloc.allocating, &no_alloc.logging }) |words| {
            if (try no_alloc.forbiddenIn(f.source, f.name, words)) |word| {
                std.debug.print("{s} in fn {s} ({s}) or a function it calls\n", .{ word, f.name, f.file });
                return error.AllocatesOrLogsOnTheAudioThread;
            }
        }
    }
}

fn readAll(ring: *mono_ring.MonoRing, tag: u32, out: []f32) usize {
    return ring.readTagged(out, tag).n;
}

test "an open tap copies its mono input into its own ring" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    const silent = [_]f64{0} ** 32;
    const half = [_]f64{0.5} ** 32;

    const t = try hook.openTap(&reaper, .{ .first = 1, .stereo = false });
    try testing.expect(hook.registered and hook.holds(.inputs));
    FakeDevice.inputBlock(hook, &.{ &silent, &half }, 48000);
    var mono: [64]f32 = undefined;
    try testing.expectEqual(@as(usize, 32), readAll(hook.tapRing(t.index), t.tag, &mono));
    for (mono[0..32]) |x| try testing.expectEqual(@as(f32, 0.5), x);
    // The master tuner's ring and the stream's aren't written for inputs.
    try testing.expectEqual(@as(usize, 0), hook.tuner_ring.available());
}

test "a stereo tap mixes its pair as (L + R) / 2" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    const a = [_]f64{1.0} ** 16;
    const b = [_]f64{0.5} ** 16;
    const c = [_]f64{-1.0} ** 16;

    const t = try hook.openTap(&reaper, .{ .first = 1, .stereo = true });
    FakeDevice.inputBlock(hook, &.{ &a, &b, &c }, 48000);
    var mono: [16]f32 = undefined;
    try testing.expectEqual(@as(usize, 16), readAll(hook.tapRing(t.index), t.tag, &mono));
    try testing.expectEqual(@as(f32, -0.25), mono[0]);
}

test "taps on two inputs each hear only their own" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    const bass = [_]f64{0.25} ** 16;
    const guitar = [_]f64{-0.75} ** 16;

    const tb = try hook.openTap(&reaper, .{ .first = 0, .stereo = false });
    const tg = try hook.openTap(&reaper, .{ .first = 1, .stereo = false });
    try testing.expect(tb.index != tg.index);
    try testing.expectEqual(@as(u32, 1), reaper.registers);
    FakeDevice.inputBlock(hook, &.{ &bass, &guitar }, 48000);
    var mono: [16]f32 = undefined;
    _ = readAll(hook.tapRing(tb.index), tb.tag, &mono);
    try testing.expectEqual(@as(f32, 0.25), mono[15]);
    _ = readAll(hook.tapRing(tg.index), tg.tag, &mono);
    try testing.expectEqual(@as(f32, -0.75), mono[15]);
}

test "an input the device doesn't have writes nothing, and a pair missing its second isn't read as one channel" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    FakeDevice.inputs = 2;
    defer FakeDevice.inputs = 8;
    const x = [_]f64{0.5} ** 16;

    const past = try hook.openTap(&reaper, .{ .first = 2, .stereo = false });
    const pair = try hook.openTap(&reaper, .{ .first = 1, .stereo = true });
    FakeDevice.inputBlock(hook, &.{ &x, &x, &x }, 48000);
    try testing.expectEqual(@as(usize, 0), hook.tapRing(past.index).available());
    try testing.expectEqual(@as(usize, 0), hook.tapRing(pair.index).available());
}

test "the hook stays registered while any tap is open, and the last closing lets go of it" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};

    const a = try hook.openTap(&reaper, .{ .first = 0, .stereo = false });
    const b = try hook.openTap(&reaper, .{ .first = 0, .stereo = true });
    try testing.expectEqual(@as(usize, 2), hook.openTaps());
    hook.closeTap(&reaper, a.index);
    try testing.expect(hook.registered and hook.holds(.inputs));
    hook.closeTap(&reaper, a.index); // closing it again changes nothing
    try testing.expect(hook.registered);
    hook.closeTap(&reaper, b.index);
    try testing.expect(!hook.registered and !hook.holds(.inputs));
    try testing.expectEqual(@as(u32, 1), reaper.unregisters);

    // With the stream holding the hook, closing the last tap leaves it registered.
    _ = hook.acquire(&reaper, .stream);
    const c = try hook.openTap(&reaper, .{ .first = 3, .stereo = false });
    hook.closeTap(&reaper, c.index);
    try testing.expect(hook.registered and hook.holds(.stream) and !hook.holds(.inputs));
}

test "with every tap in use another is refused, and a closed one can be opened again" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    var handles: [max_taps]TapHandle = undefined;
    for (&handles, 0..) |*h, i| h.* = try hook.openTap(&reaper, .{ .first = @intCast(i), .stereo = false });
    try testing.expectError(error.NoFreeTap, hook.openTap(&reaper, .{ .first = 0, .stereo = false }));
    hook.closeTap(&reaper, handles[5].index);
    const again = try hook.openTap(&reaper, .{ .first = 9, .stereo = false });
    try testing.expectEqual(handles[5].index, again.index);
    try testing.expect(again.tag != handles[5].tag);
}

test "a refused hook opens no tap" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{ .refuse = true };
    try testing.expectError(error.AudioHookFailed, hook.openTap(&reaper, .{ .first = 0, .stereo = false }));
    try testing.expectEqual(@as(usize, 0), hook.openTaps());
}

test "a tap handed to another input gives its new reader none of the old input" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    _ = hook.acquire(&reaper, .stream); // keeps the hook registered, so the ring isn't reset
    const old = [_]f64{0.25} ** 32;
    const new = [_]f64{-0.5} ** 32;

    const first = try hook.openTap(&reaper, .{ .first = 0, .stereo = false });
    FakeDevice.inputBlock(hook, &.{ &old, &new }, 48000);
    hook.closeTap(&reaper, first.index);
    const second = try hook.openTap(&reaper, .{ .first = 1, .stereo = false });
    try testing.expectEqual(first.index, second.index);
    FakeDevice.inputBlock(hook, &.{ &old, &new }, 48000);
    var mono: [128]f32 = undefined;
    const n = readAll(hook.tapRing(second.index), second.tag, &mono);
    try testing.expectEqual(@as(usize, 32), n);
    for (mono[0..n]) |x| try testing.expectEqual(@as(f32, -0.5), x);
}

test "releaseAll closes every tap" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    _ = try hook.openTap(&reaper, .{ .first = 0, .stereo = false });
    hook.releaseAll(&reaper);
    try testing.expectEqual(@as(usize, 0), hook.openTaps());
    try testing.expect(!hook.registered);
}

test "with only output 1, the tuner reads it alone and the hook counts output 2 missing" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    FakeDevice.outputs = 1;
    defer FakeDevice.outputs = 2;
    const left = [_]f64{0.5} ** 16;
    _ = hook.acquire(&reaper, .tuner);
    _ = hook.acquire(&reaper, .stream);
    FakeDevice.block(hook, &left, &left, 48000);

    var mono: [16]f32 = undefined;
    try testing.expectEqual(@as(usize, 16), hook.tuner_ring.read(&mono).n);
    try testing.expectEqual(@as(f32, 0.5), mono[0]);
    try testing.expectEqual(@as(u64, 1), hook.missing_output_2.load(.acquire));
    try testing.expectEqual(@as(u64, 0), hook.missing_output_1.load(.acquire));
    // The stream sends stereo pairs; it has none to send.
    try testing.expectEqual(@as(usize, 0), hook.stream_ring.available());
}

test "with no outputs at all, nothing is written and the hook counts output 1 missing" {
    const hook = try newHook();
    defer testing.allocator.destroy(hook);
    var reaper = FakeRegistrar{};
    FakeDevice.outputs = 0;
    defer FakeDevice.outputs = 2;
    const left = [_]f64{0.5} ** 16;
    _ = hook.acquire(&reaper, .tuner);
    FakeDevice.block(hook, &left, &left, 48000);
    try testing.expectEqual(@as(usize, 0), hook.tuner_ring.available());
    try testing.expectEqual(@as(u64, 1), hook.missing_output_1.load(.acquire));
}
