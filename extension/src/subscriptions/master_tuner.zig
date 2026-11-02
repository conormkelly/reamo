//! The master tuner: REAmo's pitch analyser (tuner/pitch.zig) reading the
//! audio hook's output channels 0/1, post-master, what audio streaming
//! sends, mixed to mono. Nothing goes into REAPER: no FX, so no undo point,
//! no project change and nothing in the monitoring chain.
//!
//! What it hears is what REAPER sends the audio device's hardware outputs
//! 1/2, after the master's FX, fader, pan and mute, plus anything else
//! routed to those outputs (a track's hardware output, the metronome if it
//! goes there). So a muted or faded-down master, or a master routed to
//! other outputs, reads as silence, the same as nothing playing: the tuner
//! can't tell them apart. On a device with one output it reads output 1
//! alone; on one with none it reads nothing. The worker logs either once
//! per opening (`outputs_reported`, and audio/status's missingOutput1/2).
//!
//! Every phone tuning the master shares one analyser and its thread
//! (tuner_worker.zig), started when the first opens the tuner and stopped
//! when the last closes it.
const std = @import("std");
const pitch = @import("../tuner/pitch.zig");
const audio_hook = @import("../audio/audio_hook.zig");
const tuner_worker = @import("tuner_worker.zig");

const Allocator = std.mem.Allocator;
const Analysis = tuner_worker.Analysis;
const quiet_ticks_limit = tuner_worker.quiet_ticks_limit;

pub const OpenError = error{ OutOfMemory, AudioHookFailed, ThreadFailed };

pub const MasterTuner = struct {
    worker: tuner_worker.Worker = .{},
    subscribers: u8 = 0,

    /// A phone opens the master tuner. The first takes the audio hook and
    /// starts the worker; settings start from the analyser's defaults.
    /// `registrar` is anything with REAPER's registerAudioHook and
    /// unregisterAudioHook. Main thread.
    pub fn open(self: *MasterTuner, allocator: Allocator, hook: *audio_hook.Hook, registrar: anytype) OpenError!void {
        if (self.subscribers > 0) {
            self.subscribers += 1;
            return;
        }
        if (!hook.acquire(registrar, .tuner)) return error.AudioHookFailed;
        errdefer hook.release(registrar, .tuner);
        // acquire left the ring empty, and the worker, its consumer from now
        // on, starts here.
        try self.worker.start(allocator, .{ .ring = &hook.tuner_ring, .outputs = hook }, .{});
        self.subscribers = 1;
    }

    /// A phone closes the master tuner. The last stops the worker and lets
    /// go of the audio hook. Main thread.
    pub fn close(self: *MasterTuner, allocator: Allocator, hook: *audio_hook.Hook, registrar: anytype) void {
        if (self.subscribers == 0) return;
        self.subscribers -= 1;
        if (self.subscribers > 0) return;
        self.worker.stop(allocator);
        hook.release(registrar, .tuner);
    }

    pub fn isOpen(self: *const MasterTuner) bool {
        return self.subscribers > 0;
    }

    pub fn setReference(self: *MasterTuner, hz: f64) void {
        self.worker.setReference(hz);
    }

    pub fn setSilenceDb(self: *MasterTuner, db: f64) void {
        self.worker.setSilenceDb(db);
    }

    pub fn snapshot(self: *MasterTuner) tuner_worker.Worker.Snapshot {
        return self.worker.snapshot();
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
                _ = analysis.tick(&self.hook.tuner_ring, 0, settings);
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
    _ = t.analysis.tick(ring, 0, .{});
    try testing.expectEqual(@as(u32, 0), t.analysis.quiet_ticks);
    for (0..quiet_ticks_limit - 1) |_| _ = t.analysis.tick(ring, 0, .{});
    try testing.expect(t.analysis.reading.freq_hz > 0);
    _ = t.analysis.tick(ring, 0, .{});
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
    for (0..3) |_| _ = t.analysis.tick(ring, 0, .{});
    try testing.expectEqual(@as(f64, 0), t.analysis.reading.freq_hz);
}

test "a plug-in blowing up through the master doesn't stop the tuner reading" {
    var t = try analysisRig(testing.allocator);
    defer t.rig.deinit();
    defer testing.allocator.destroy(t.analysis);

    t.rig.play(t.analysis, .{}, 220, 0, 44100, 0.3);
    var burst: [256]f64 = undefined;
    for (&burst, 0..) |*x, i| x.* = if (i % 2 == 0) 1e10 else std.math.inf(f64);
    FakeDevice.block(t.rig.hook, &burst, &burst, 44100);
    t.rig.play(t.analysis, .{}, 220, 0, 44100, 0.3);
    t.rig.play(t.analysis, .{}, 220, 0.5, 44100, 1.0);
    try expectA3(t.analysis.reading);
}

test "the master's settings are held to the tuner's ranges" {
    var tuner = MasterTuner{};
    tuner.setReference(300);
    tuner.setSilenceDb(20);
    try testing.expectEqual(pitch.Settings{ .reference_hz = 400, .silence_db = -30 }, tuner.snapshot().settings);
}

test "phones share one analyser, worker and hook until the last closes" {
    var rig = try Rig.init();
    defer rig.deinit();
    var tuner = MasterTuner{};
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    const first = tuner.worker.analysis;
    try testing.expect(tuner.worker.isRunning());
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    try testing.expectEqual(first, tuner.worker.analysis);
    try testing.expectEqual(@as(u32, 1), rig.reaper.registers);

    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    try testing.expect(tuner.isOpen() and rig.hook.holds(.tuner) and tuner.worker.isRunning());
    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    try testing.expect(!tuner.isOpen() and !rig.hook.registered);
    try testing.expectEqual(@as(?*Analysis, null), tuner.worker.analysis);
    try testing.expect(!tuner.worker.isRunning());
    // A close too many changes nothing.
    tuner.close(testing.allocator, rig.hook, &rig.reaper);
    try testing.expectEqual(@as(u32, 1), rig.reaper.unregisters);
}

test "the worker reads a pluck the hook delivers in real time" {
    var rig = try Rig.init();
    defer rig.deinit();
    var tuner = MasterTuner{};
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    defer tuner.close(testing.allocator, rig.hook, &rig.reaper);

    // Blocks of 256 samples at 48 kHz, one every 5.3 ms: 0.34 s of
    // silence, then the pluck, sounding until the worker reads it (or 4 s,
    // generous for a loaded machine).
    const block_ns = 5_333_333;
    var timer = try std.time.Timer.start();
    var n: u64 = 0;
    while (n < 64) : (n += 1) {
        rig.block(220, 0, 48000);
        std.Thread.sleep(n * block_ns -| timer.read());
    }
    while (n < 64 + 750) : (n += 1) {
        rig.block(220, 0.5, 48000);
        std.Thread.sleep(n * block_ns -| timer.read());
        if (n > 64 + 60 and tuner.snapshot().reading.note == 57) break;
    }
    try expectA3(tuner.snapshot().reading);
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
    try testing.expectEqual(@as(?*Analysis, null), tuner.worker.analysis);
}

test "the worker reports a device that gives the master no output to read" {
    var rig = try Rig.init();
    defer rig.deinit();
    var tuner = MasterTuner{ .worker = .{ .tick_ns = 2 * std.time.ns_per_ms } };
    try tuner.open(testing.allocator, rig.hook, &rig.reaper);
    defer tuner.close(testing.allocator, rig.hook, &rig.reaper);
    FakeDevice.outputs = 0;
    defer FakeDevice.outputs = 2;

    for (0..20) |_| {
        rig.block(220, 0.5, 48000);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    var waited: u32 = 0;
    while (tuner.worker.outputs_reported.load(.acquire) != .none_from_device and waited < 2000) : (waited += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(tuner_worker.OutputsReport.none_from_device, tuner.worker.outputs_reported.load(.acquire));
}
