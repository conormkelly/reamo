//! The master tuner: REAmo's pitch analyser (tuner/pitch.zig) reading the
//! audio hook's output channels 0/1, post-master, what audio streaming
//! sends, mixed to mono. Nothing goes into REAPER: no FX, so no undo point,
//! no project change and nothing in the monitoring chain.
//!
//! Every phone tuning the master shares one analyser, allocated when the
//! first opens the tuner and freed when the last closes it. Three threads:
//! - the audio thread only copies samples into the hook's mono ring;
//! - a worker thread, running while the tuner is open, drains the ring into
//!   the analyser and analyses at 30 Hz (`Analysis.tick`), once however
//!   many phones are tuning, and publishes the reading;
//! - the main thread's 30 Hz subscription poll sends the latest reading to
//!   each phone, and takes the phones' settings to the worker.
//!
//! The analysis is off the main thread because it is REAPER's UI thread,
//! and a tick isn't always cheap. Measured in ReleaseSafe at 48 kHz (one
//! tick: 1600 samples pushed, one analysis): about 0.15 ms once a note has
//! started, but about 3.4 ms on every tick from the analyser's start until
//! its first onset, which over a mix already playing, or hum, can be
//! indefinitely: a tenth of the UI's 33 ms frame. On the worker that costs
//! the UI nothing, and the reading and settings cross under a lock held
//! only to copy them.
//!
//! The analyser shows a note only from an onset: a string already ringing
//! when the tuner opens shows once it is plucked again.
const std = @import("std");
const logging = @import("../core/logging.zig");
const pitch = @import("../tuner/pitch.zig");
const audio_hook = @import("../audio/audio_hook.zig");
const mono_ring = @import("../audio/mono_ring.zig");
const no_alloc = @import("../core/no_alloc.zig");

const Allocator = std.mem.Allocator;

/// The tuner's A4 range, as the JSFX's slider and the phone's settings
/// offer it.
pub const reference_min_hz = 400.0;
pub const reference_max_hz = 480.0;
/// The silence threshold's range, as the phone's slider offers it. The
/// analyser's default, the lowest, leaves the gating to its learned noise
/// floor.
pub const silence_min_db = -90.0;
pub const silence_max_db = -30.0;

/// The analysis rate: the tuner's 30 Hz. The analyser's `stable` flag needs
/// analyses at most about 128 Hz apart, and the phones are sent readings at
/// 30 Hz.
const tick_ns: u64 = std.time.ns_per_s / 30;

/// Ticks without a sample before the reading clears and the analyser
/// forgets: half a second at 30 Hz, longer than any audio block (8192
/// samples at 22.05 kHz is 0.37 s). The device has stopped, or REAPER has
/// closed it.
const quiet_ticks_limit = 15;

/// Samples drained per push.
const chunk_len = 1024;

/// The analyser and what it needs between ticks. Owned by the worker thread
/// while the tuner is open.
pub const Analysis = struct {
    analyser: pitch.Analyser,
    /// The rate the analyser was set up for: 0 before the hook has
    /// reported one, or while the rate is one the analyser can't take.
    rate: f64 = 0,
    /// The ring's rate as last seen, supported or not.
    seen_rate: f64 = 0,
    reading: pitch.Reading = .none,
    quiet_ticks: u32 = 0,
    chunk: [chunk_len]f32 = undefined,

    /// Allocated once, when the tuner opens: the analyser is about 600 KB.
    pub fn create(allocator: Allocator) Allocator.Error!*Analysis {
        const self = try allocator.create(Analysis);
        self.* = .{ .analyser = undefined };
        return self;
    }

    /// Drain what the hook has written, analyse it, and return the reading
    /// to show. The ring's one consumer. Allocates nothing.
    pub fn tick(self: *Analysis, ring: *mono_ring.MonoRing, settings: pitch.Settings) pitch.Reading {
        const ring_rate = ring.sampleRate();
        if (ring_rate != self.seen_rate) {
            // A new device rate (or the first): set up for it, and drop
            // what came before, which may be at the old rate.
            self.seen_rate = ring_rate;
            ring.discard();
            self.reading = .none;
            self.quiet_ticks = 0;
            self.rate = 0;
            if (ring_rate > 0) {
                if (self.analyser.init(ring_rate)) {
                    self.rate = ring_rate;
                } else |_| {
                    logging.warn("tuner: the master tuner can't analyse audio at {d} Hz", .{ring_rate});
                }
            }
            return self.reading;
        }
        if (self.rate == 0) {
            ring.discard();
            return self.reading;
        }

        var got: usize = 0;
        while (got < mono_ring.capacity) {
            const r = ring.read(&self.chunk);
            if (r.n == 0) break;
            self.analyser.push(self.chunk[0..r.n]);
            got += r.n;
        }
        if (got == 0) {
            self.quiet_ticks +|= 1;
            if (self.quiet_ticks == quiet_ticks_limit) {
                self.analyser.reset();
                self.reading = .none;
            }
            if (self.quiet_ticks >= quiet_ticks_limit) return self.reading;
        } else {
            self.quiet_ticks = 0;
        }
        self.reading = self.analyser.analyse(settings);
        return self.reading;
    }
};

pub const OpenError = error{ OutOfMemory, AudioHookFailed, ThreadFailed };

pub const MasterTuner = struct {
    /// Null while no phone tunes the master.
    analysis: ?*Analysis = null,
    worker: ?std.Thread = null,
    stop: std.Thread.ResetEvent = .{},
    subscribers: u8 = 0,
    /// What crosses between the main thread and the worker.
    lock: std.Thread.Mutex = .{},
    /// The phones' settings; written on the main thread, under `lock`.
    settings: pitch.Settings = .{},
    /// The latest reading; written by the worker, under `lock`.
    reading: pitch.Reading = .none,

    pub const Snapshot = struct { reading: pitch.Reading, settings: pitch.Settings };

    /// A phone opens the master tuner. The first allocates the analyser,
    /// takes the audio hook and starts the worker; settings start from the
    /// analyser's defaults, as a fresh JSFX's did. `registrar` is anything
    /// with REAPER's registerAudioHook and unregisterAudioHook. Main thread.
    pub fn open(self: *MasterTuner, allocator: Allocator, hook: *audio_hook.Hook, registrar: anytype) OpenError!void {
        if (self.subscribers > 0) {
            self.subscribers += 1;
            return;
        }
        const analysis = try Analysis.create(allocator);
        errdefer allocator.destroy(analysis);
        if (!hook.acquire(registrar, .tuner)) return error.AudioHookFailed;
        errdefer hook.release(registrar, .tuner);
        // From the hook's next block: nothing older belongs to this tuner.
        // The worker, the ring's consumer from now on, isn't running yet.
        hook.tuner_ring.discard();
        self.* = .{ .analysis = analysis, .subscribers = 1 };
        self.worker = std.Thread.spawn(.{}, run, .{ self, analysis, &hook.tuner_ring }) catch |err| {
            logging.err("tuner: couldn't start the master tuner's thread: {s}", .{@errorName(err)});
            self.* = .{};
            return error.ThreadFailed;
        };
    }

    /// A phone closes the master tuner. The last stops the worker, lets go
    /// of the audio hook and frees the analyser. Main thread.
    pub fn close(self: *MasterTuner, allocator: Allocator, hook: *audio_hook.Hook, registrar: anytype) void {
        if (self.subscribers == 0) return;
        self.subscribers -= 1;
        if (self.subscribers > 0) return;
        self.stop.set();
        if (self.worker) |t| t.join();
        hook.release(registrar, .tuner);
        if (self.analysis) |a| allocator.destroy(a);
        self.* = .{};
    }

    pub fn isOpen(self: *const MasterTuner) bool {
        return self.subscribers > 0;
    }

    /// A4's frequency, held to the tuner's range. Main thread.
    pub fn setReference(self: *MasterTuner, hz: f64) void {
        if (!std.math.isFinite(hz)) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.settings.reference_hz = std.math.clamp(hz, reference_min_hz, reference_max_hz);
    }

    /// The absolute silence threshold, held to the tuner's range. It takes
    /// effect with the analyser's next input. Main thread.
    pub fn setSilenceDb(self: *MasterTuner, db: f64) void {
        if (!std.math.isFinite(db)) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.settings.silence_db = std.math.clamp(db, silence_min_db, silence_max_db);
    }

    /// The latest reading and the settings, for the phones. Main thread.
    pub fn snapshot(self: *MasterTuner) Snapshot {
        self.lock.lock();
        defer self.lock.unlock();
        return .{ .reading = self.reading, .settings = self.settings };
    }

    /// The worker: a tick every 1/30 s until `stop` is set.
    fn run(self: *MasterTuner, analysis: *Analysis, ring: *mono_ring.MonoRing) void {
        var timer = std.time.Timer.start() catch {
            logging.err("tuner: no monotonic clock; the master tuner reads nothing", .{});
            return;
        };
        var due: u64 = 0;
        while (true) {
            self.lock.lock();
            const settings = self.settings;
            self.lock.unlock();

            const reading = analysis.tick(ring, settings);

            self.lock.lock();
            self.reading = reading;
            self.lock.unlock();

            // Keep to the 30 Hz grid; after an overrun, start a new one.
            due += tick_ns;
            const now = timer.read();
            if (now >= due) {
                due = now;
                if (self.stop.isSet()) return;
                continue;
            }
            self.stop.timedWait(due - now) catch continue;
            return;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const FakeRegistrar = audio_hook.FakeRegistrar;
const FakeDevice = audio_hook.FakeDevice;

/// A hook writing the tuner's ring, as when a tuner holds it.
const Rig = struct {
    hook: *audio_hook.Hook,
    reaper: FakeRegistrar = .{},
    phase: f64 = 0,

    fn init() !Rig {
        const hook = try testing.allocator.create(audio_hook.Hook);
        hook.* = .{};
        return .{ .hook = hook };
    }

    fn deinit(self: *Rig) void {
        testing.allocator.destroy(self.hook);
    }

    /// One 256-sample block of a sine at `hz` and `amp` (0 is silence).
    fn block(self: *Rig, hz: f64, amp: f64, rate: f64) void {
        var left: [256]f64 = undefined;
        for (&left) |*x| {
            x.* = amp * @sin(self.phase);
            self.phase += 2 * std.math.pi * hz / rate;
        }
        self.phase = @mod(self.phase, 2 * std.math.pi);
        FakeDevice.block(self.hook, &left, &left, rate);
    }

    /// `seconds` of audio through the hook, ticking `analysis` every 1/30 s
    /// of it, as the worker would.
    fn play(self: *Rig, analysis: *Analysis, settings: pitch.Settings, hz: f64, amp: f64, rate: f64, seconds: f64) void {
        const per_tick = rate / 30.0;
        var since_tick: f64 = 0;
        var done: f64 = 0;
        while (done < seconds * rate) : (done += 256) {
            self.block(hz, amp, rate);
            since_tick += 256;
            if (since_tick >= per_tick) {
                since_tick -= per_tick;
                _ = analysis.tick(&self.hook.tuner_ring, settings);
            }
        }
    }
};

/// An Analysis on a rig whose hook the tuner holds, without the worker.
fn analysisRig(allocator: Allocator) !struct { rig: Rig, analysis: *Analysis } {
    var rig = try Rig.init();
    try testing.expect(rig.hook.acquire(&rig.reaper, .tuner));
    return .{ .rig = rig, .analysis = try Analysis.create(allocator) };
}

fn expectA3(reading: pitch.Reading) !void {
    try testing.expectEqual(@as(i32, 57), reading.note);
    try testing.expect(@abs(reading.freq_hz - 220.0) < 0.05);
    try testing.expect(@abs(reading.cents) < 1.0);
}

test "a tone plucked after silence reads through the hook as its note" {
    var t = try analysisRig(testing.allocator);
    defer t.rig.deinit();
    defer testing.allocator.destroy(t.analysis);

    t.rig.play(t.analysis, .{}, 220, 0, 48000, 0.5);
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
    t.rig.play(t.analysis, .{}, 220, 0.5, 48000, 1.0);
    try expectA3(t.analysis.reading);
    try testing.expect(t.analysis.reading.stable and !t.analysis.reading.settling);
}

test "a tone already sounding when the analysis starts shows only once plucked again" {
    var t = try analysisRig(testing.allocator);
    defer t.rig.deinit();
    defer testing.allocator.destroy(t.analysis);

    t.rig.play(t.analysis, .{}, 220, 0.5, 48000, 1.0);
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
    t.rig.play(t.analysis, .{}, 220, 0, 48000, 0.3);
    t.rig.play(t.analysis, .{}, 220, 0.5, 48000, 1.0);
    try expectA3(t.analysis.reading);
}

test "a sample-rate change sets the analyser up again for the new rate" {
    var t = try analysisRig(testing.allocator);
    defer t.rig.deinit();
    defer testing.allocator.destroy(t.analysis);

    t.rig.play(t.analysis, .{}, 220, 0, 48000, 0.3);
    t.rig.play(t.analysis, .{}, 220, 0.5, 48000, 0.8);
    try expectA3(t.analysis.reading);
    try testing.expectEqual(@as(f64, 48000), t.analysis.rate);

    // Read at the old rate, 96 kHz audio would read an octave down.
    t.rig.play(t.analysis, .{}, 220, 0, 96000, 0.3);
    try testing.expectEqual(@as(f64, 96000), t.analysis.rate);
    t.rig.play(t.analysis, .{}, 220, 0.5, 96000, 0.8);
    try expectA3(t.analysis.reading);
}

test "a rate the analyser can't take reads nothing, and a good one after it reads again" {
    var t = try analysisRig(testing.allocator);
    defer t.rig.deinit();
    defer testing.allocator.destroy(t.analysis);

    t.rig.play(t.analysis, .{}, 220, 0, 768000, 0.1);
    t.rig.play(t.analysis, .{}, 220, 0.5, 768000, 0.5);
    try testing.expectEqual(@as(f64, 0), t.analysis.rate);
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
    try testing.expectEqual(@as(usize, 0), t.rig.hook.tuner_ring.available());

    t.rig.play(t.analysis, .{}, 220, 0, 44100, 0.3);
    t.rig.play(t.analysis, .{}, 220, 0.5, 44100, 0.8);
    try expectA3(t.analysis.reading);
}

test "when the audio stops, the reading clears instead of holding the last note" {
    var t = try analysisRig(testing.allocator);
    defer t.rig.deinit();
    defer testing.allocator.destroy(t.analysis);
    const ring = &t.rig.hook.tuner_ring;

    t.rig.play(t.analysis, .{}, 220, 0, 48000, 0.3);
    t.rig.play(t.analysis, .{}, 220, 0.5, 48000, 0.6);
    try testing.expect(t.analysis.reading.freq_hz > 0);

    // One last block, read; then the device stops and the ticks go on with
    // nothing to read.
    t.rig.block(220, 0.5, 48000);
    _ = t.analysis.tick(ring, .{});
    try testing.expectEqual(@as(u32, 0), t.analysis.quiet_ticks);
    for (0..quiet_ticks_limit - 1) |_| _ = t.analysis.tick(ring, .{});
    try testing.expect(t.analysis.reading.freq_hz > 0);
    _ = t.analysis.tick(ring, .{});
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
    for (0..3) |_| _ = t.analysis.tick(ring, .{});
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
}

test "the analysis tick and its thread have no allocator and call none" {
    // The analysis is allocated once, at open; every tick after that, on
    // the worker at 30 Hz, must not allocate. Checked statically, which
    // catches a global allocator too (core/no_alloc.zig). The analyser's
    // own push and analyse are tuner/pitch.zig's to keep allocation-free.
    if (comptime no_alloc.reachesAllocator(Analysis)) @compileError("an allocator is reachable from Analysis");
    if (comptime no_alloc.paramsReachAllocator(@TypeOf(Analysis.tick))) @compileError("an allocator is reachable from @TypeOf(Analysis.tick)");
    if (comptime no_alloc.paramsReachAllocator(@TypeOf(MasterTuner.run))) @compileError("an allocator is reachable from @TypeOf(MasterTuner.run)");
    const source = @embedFile("master_tuner.zig");
    for ([_][]const u8{ "tick", "run" }, [_]?[]const u8{ try no_alloc.allocationIn(source, "tick"), try no_alloc.allocationIn(source, "run") }) |name, found| {
        if (found) |word| {
            std.debug.print("{s} in fn {s}\n", .{ word, name });
            return error.AllocatesOnTheAnalysisPath;
        }
    }
}

test "settings are held to the tuner's ranges" {
    var tuner = MasterTuner{};
    tuner.setReference(300);
    try testing.expectEqual(@as(f64, 400), tuner.settings.reference_hz);
    tuner.setReference(500);
    try testing.expectEqual(@as(f64, 480), tuner.settings.reference_hz);
    tuner.setReference(std.math.nan(f64));
    try testing.expectEqual(@as(f64, 480), tuner.settings.reference_hz);
    tuner.setSilenceDb(20);
    try testing.expectEqual(@as(f64, -30), tuner.settings.silence_db);
    tuner.setSilenceDb(-120);
    try testing.expectEqual(@as(f64, -90), tuner.settings.silence_db);
}

test "phones share one analyser, worker and hook until the last closes" {
    var rig = try Rig.init();
    defer rig.deinit();
    var tuner = MasterTuner{};
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    const first = tuner.analysis;
    try testing.expect(tuner.worker != null);
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    try testing.expectEqual(first, tuner.analysis);
    try testing.expectEqual(@as(u32, 1), rig.reaper.registers);

    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    try testing.expect(tuner.isOpen() and rig.hook.holds(.tuner) and tuner.worker != null);
    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    try testing.expect(!tuner.isOpen() and !rig.hook.registered);
    try testing.expectEqual(@as(?*Analysis, null), tuner.analysis);
    try testing.expectEqual(@as(?std.Thread, null), tuner.worker);
    // A close too many changes nothing.
    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    try testing.expectEqual(@as(u32, 1), rig.reaper.unregisters);
}

test "the worker reads a pluck the hook delivers in real time, and closing stops it promptly" {
    var rig = try Rig.init();
    defer rig.deinit();
    var tuner = MasterTuner{};
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);

    // 256 samples at 48 kHz is 5.3 ms: silence, then the pluck.
    var timer = try std.time.Timer.start();
    var n: u64 = 0;
    while (n < 64) : (n += 1) {
        rig.block(220, 0, 48000);
        std.Thread.sleep(n * 5_333_333 -| timer.read());
    }
    while (n < 64 + 200) : (n += 1) {
        rig.block(220, 0.5, 48000);
        std.Thread.sleep(n * 5_333_333 -| timer.read());
    }
    try expectA3(tuner.snapshot().reading);

    timer.reset();
    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    // The worker wakes from its wait at once, not at its next tick.
    try testing.expect(timer.read() < 20 * std.time.ns_per_ms);
}

test "reopening starts afresh: default settings and no reading" {
    var rig = try Rig.init();
    defer rig.deinit();
    var tuner = MasterTuner{};
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    tuner.setReference(442);
    tuner.setSilenceDb(-50);
    tuner.close(testing.allocator, rig.hook, &rig.reaper);

    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    defer tuner.close(testing.allocator, rig.hook, &rig.reaper);
    const s = tuner.snapshot();
    try testing.expectEqual(pitch.Settings{}, s.settings);
    try testing.expectEqual(@as(f64, 0), s.reading.freq_hz);
    try testing.expectEqual(@as(u32, 2), rig.reaper.registers);
}

test "a refused hook frees the analyser and leaves the tuner closed" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.reaper.refuse = true;
    var tuner = MasterTuner{};
    try testing.expectError(error.AudioHookFailed, tuner.open(testing.allocator, rig.hook, &rig.reaper));
    try testing.expect(!tuner.isOpen());
    try testing.expectEqual(@as(?*Analysis, null), tuner.analysis);
}
