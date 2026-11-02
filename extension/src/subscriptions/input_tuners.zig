//! Track tuners on the audio hook's input taps: REAmo's pitch analyser
//! reading the hardware input a track records from, as its record input
//! (I_RECINPUT) names it. Nothing goes into REAPER: no FX, so no undo
//! point, no project change, nothing in the .RPP.
//!
//! What can be tuned is decided by the track's record input setting, not
//! by what is on the track (`classify`):
//! - a mono hardware input n (I_RECINPUT n, under 512): hook input n;
//! - a stereo pair (1024 + n): hook inputs n and n + 1, mixed to mono as
//!   (L + R) / 2;
//! - refused, each with its own code and message (`CantTune`): no input,
//!   a MIDI input, a ReaRoute or loopback input (512 and up), a
//!   multichannel input (2048), and an input the current device doesn't
//!   have. ReaRoute, loopback and multichannel inputs map to hook inputs in
//!   ways not yet tested on hardware, so they are refused as not supported
//!   yet rather than guessed at.
//!
//! The input flows whether the track is armed or not, the transport stopped
//! or playing. While REAPER has the device closed (Preferences > Audio,
//! "close audio device when stopped"), no audio arrives at all, and
//! GetNumAudioInputs reports 0: then the channel's existence can't be
//! checked, and the phones are told the device is closed.
//!
//! One analyser per tuned input source (`InputTuners`): phones tuning tracks
//! on the same input share it, and its settings; tracks on different inputs
//! are independent. Each source has a tap on the hook and a worker thread
//! (tuner_worker.zig); the last phone leaving a source closes both.
const std = @import("std");
const logging = @import("../core/logging.zig");
const pitch = @import("../tuner/pitch.zig");
const audio_hook = @import("../audio/audio_hook.zig");
const tuner_worker = @import("tuner_worker.zig");

const Allocator = std.mem.Allocator;
const Channels = audio_hook.Channels;

/// I_RECINPUT's encoding (REAPER SDK, GetSetMediaTrackInfo).
const MIDI_FLAG: c_int = 4096;
const MULTI_FLAG: c_int = 2048;
const STEREO_FLAG: c_int = 1024;
const REAROUTE_START: c_int = 512;
const CHANNEL_MASK: c_int = 1023;

/// Why a track can't be tuned, as the phone is told it.
pub const CantTune = enum {
    input_none,
    input_midi,
    input_not_on_device,
    input_rearoute,
    input_multichannel,
    too_many_inputs,
    audio_hook_failed,
    out_of_memory,
    thread_failed,

    pub fn code(self: CantTune) []const u8 {
        return switch (self) {
            .input_none => "INPUT_NONE",
            .input_midi => "INPUT_MIDI",
            .input_not_on_device => "INPUT_NOT_ON_DEVICE",
            .input_rearoute, .input_multichannel => "INPUT_NOT_SUPPORTED",
            .too_many_inputs => "TOO_MANY_TUNERS",
            .audio_hook_failed => "AUDIO_HOOK_FAILED",
            .out_of_memory => "OUT_OF_MEMORY",
            .thread_failed => "THREAD_FAILED",
        };
    }

    pub fn message(self: CantTune) []const u8 {
        return switch (self) {
            .input_none => "This track has no record input. Choose an audio input for it in REAPER to tune it.",
            .input_midi => "This track records MIDI. Choose an audio input for it in REAPER to tune it.",
            .input_not_on_device => "This track's input isn't on the current audio device. Choose one of the device's inputs in REAPER.",
            .input_rearoute => "The tuner can't read ReaRoute or loopback inputs yet. Choose a hardware input for this track in REAPER.",
            .input_multichannel => "The tuner can't read multichannel inputs yet. Choose a mono or stereo input for this track in REAPER.",
            .too_many_inputs => "Too many inputs are being tuned at once.",
            .audio_hook_failed => "REAPER refused the audio hook the tuner reads.",
            .out_of_memory => "Not enough memory for the tuner.",
            .thread_failed => "Couldn't start the tuner's thread.",
        };
    }

    pub fn fromOpenError(err: OpenError) CantTune {
        return switch (err) {
            error.NoFreeTap => .too_many_inputs,
            error.AudioHookFailed => .audio_hook_failed,
            error.OutOfMemory => .out_of_memory,
            error.ThreadFailed => .thread_failed,
        };
    }
};

/// What a track's record input gives the tuner.
pub const Classification = union(enum) {
    channels: Channels,
    cant: CantTune,
};

/// The hook input channels a track's record input names, or why it can't
/// be tuned. `device_inputs` is GetNumAudioInputs; with the device closed
/// (`device_open` false) it is 0, and a channel's existence isn't checked.
pub fn classify(rec_input: c_int, device_inputs: c_int, device_open: bool) Classification {
    if (rec_input < 0) return .{ .cant = .input_none };
    if (rec_input & MIDI_FLAG != 0) return .{ .cant = .input_midi };
    if (rec_input & MULTI_FLAG != 0) return .{ .cant = .input_multichannel };
    const first = rec_input & CHANNEL_MASK;
    if (first >= REAROUTE_START) return .{ .cant = .input_rearoute };
    const stereo = rec_input & STEREO_FLAG != 0;
    const last = first + @intFromBool(stereo);
    if (device_open and last >= device_inputs) return .{ .cant = .input_not_on_device };
    return .{ .channels = .{ .first = @intCast(first), .stereo = stereo } };
}

pub const OpenError = audio_hook.OpenTapError || tuner_worker.StartError;

/// The input sources being tuned, each shared by every phone on it.
pub const InputTuners = struct {
    sources: [audio_hook.max_taps]Source = [_]Source{.{}} ** audio_hook.max_taps,
    /// Tick period for the workers. Tests lengthen it.
    tick_ns: ?u64 = null,

    pub const Source = struct {
        channels: Channels = .{ .first = 0, .stereo = false },
        tap: audio_hook.TapHandle = .{ .index = 0, .tag = 0 },
        worker: tuner_worker.Worker = .{},
        /// Phones on this source; 0 is a free slot.
        phones: u8 = 0,
    };

    /// A phone starts tuning `channels`. It joins the source on them if
    /// there is one, taking its settings; otherwise a source opens on a
    /// new tap with `settings`. Returns the source's index. Main thread.
    pub fn open(self: *InputTuners, allocator: Allocator, hook: *audio_hook.Hook, registrar: anytype, channels: Channels, settings: pitch.Settings) OpenError!u8 {
        for (&self.sources, 0..) |*s, i| {
            if (s.phones > 0 and s.channels.eql(channels)) {
                s.phones += 1;
                return @intCast(i);
            }
        }
        const index = for (&self.sources, 0..) |*s, i| {
            if (s.phones == 0) break i;
        } else return error.NoFreeTap;
        const s = &self.sources[index];
        const tap = try hook.openTap(registrar, channels);
        errdefer hook.closeTap(registrar, tap.index);
        if (self.tick_ns) |t| s.worker.tick_ns = t;
        try s.worker.start(allocator, .{ .ring = hook.tapRing(tap.index), .tag = tap.tag }, settings);
        s.channels = channels;
        s.tap = tap;
        s.phones = 1;
        logging.info("tuner: listening to input {d}{s}", .{ channels.first + 1, if (channels.stereo) " (stereo pair)" else "" });
        return @intCast(index);
    }

    /// A phone stops tuning source `index`. The last closes its worker and
    /// tap. Main thread.
    pub fn close(self: *InputTuners, allocator: Allocator, hook: *audio_hook.Hook, registrar: anytype, index: u8) void {
        const s = &self.sources[index];
        if (s.phones == 0) return;
        s.phones -= 1;
        if (s.phones > 0) return;
        s.worker.stop(allocator);
        hook.closeTap(registrar, s.tap.index);
        logging.info("tuner: stopped listening to input {d}{s}", .{ s.channels.first + 1, if (s.channels.stereo) " (stereo pair)" else "" });
        s.* = .{};
    }

    pub fn source(self: *InputTuners, index: u8) *Source {
        return &self.sources[index];
    }

    /// Sources open now.
    pub fn openCount(self: *const InputTuners) usize {
        var n: usize = 0;
        for (&self.sources) |*s| n += @intFromBool(s.phones > 0);
        return n;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectChannels(want: Channels, got: Classification) !void {
    switch (got) {
        .channels => |c| try testing.expect(c.eql(want)),
        .cant => |why| {
            std.debug.print("refused: {s}\n", .{why.code()});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectCant(want: CantTune, got: Classification) !void {
    try testing.expectEqual(Classification{ .cant = want }, got);
}

test "a mono input n is hook input n, as the JACK spike measured" {
    try expectChannels(.{ .first = 0, .stereo = false }, classify(0, 2, true));
    try expectChannels(.{ .first = 1, .stereo = false }, classify(1, 2, true));
    try expectChannels(.{ .first = 7, .stereo = false }, classify(7, 8, true));
}

test "a stereo pair 1024 + n is hook inputs n and n + 1" {
    try expectChannels(.{ .first = 0, .stereo = true }, classify(1024, 2, true));
    try expectChannels(.{ .first = 2, .stereo = true }, classify(1024 + 2, 4, true));
}

test "no input, a MIDI input, ReaRoute or loopback, and multichannel are refused with their own reasons" {
    try expectCant(.input_none, classify(-1, 8, true));
    // MIDI: all devices, all channels; and device 2, channel 1.
    try expectCant(.input_midi, classify(4096 | (63 << 5), 8, true));
    try expectCant(.input_midi, classify(4096 | (2 << 5) | 1, 8, true));
    try expectCant(.input_rearoute, classify(512, 8, true));
    try expectCant(.input_rearoute, classify(1024 + 514, 8, true));
    try expectCant(.input_multichannel, classify(2048, 8, true));
    // Each says something different to the phone, except the two not supported yet.
    try testing.expectEqualStrings("INPUT_NOT_SUPPORTED", CantTune.input_rearoute.code());
    try testing.expectEqualStrings("INPUT_NOT_SUPPORTED", CantTune.input_multichannel.code());
    try testing.expect(!std.mem.eql(u8, CantTune.input_rearoute.message(), CantTune.input_multichannel.message()));
}

test "an input the device doesn't have is refused, including a pair's second channel" {
    try expectCant(.input_not_on_device, classify(2, 2, true));
    try expectCant(.input_not_on_device, classify(1024 + 1, 2, true));
    try expectCant(.input_not_on_device, classify(0, 0, true));
}

test "with the device closed a channel's existence isn't checked, but the rest still is" {
    try expectChannels(.{ .first = 5, .stereo = false }, classify(5, 0, false));
    try expectChannels(.{ .first = 4, .stereo = true }, classify(1024 + 4, 0, false));
    try expectCant(.input_none, classify(-1, 0, false));
    try expectCant(.input_midi, classify(4096, 0, false));
}

test "every reason has a code and a message a phone can show" {
    inline for (@typeInfo(CantTune).@"enum".fields) |f| {
        const why: CantTune = @enumFromInt(f.value);
        try testing.expect(why.code().len > 0 and why.message().len > 0);
        // Messages go into JSON as they are.
        try testing.expect(std.mem.indexOfAny(u8, why.message(), "\"\\") == null);
    }
}

const FakeRegistrar = audio_hook.FakeRegistrar;

const Rig = struct {
    hook: *audio_hook.Hook,
    reaper: FakeRegistrar = .{},
    tuners: InputTuners = .{ .tick_ns = 2 * std.time.ns_per_ms },

    fn init() !Rig {
        const hook = try testing.allocator.create(audio_hook.Hook);
        hook.* = .{};
        return .{ .hook = hook };
    }

    fn deinit(self: *Rig) void {
        for (&self.tuners.sources, 0..) |*s, i| {
            while (s.phones > 0) self.close(@intCast(i));
        }
        testing.allocator.destroy(self.hook);
    }

    fn open(self: *Rig, channels: Channels, settings: pitch.Settings) !u8 {
        return self.tuners.open(testing.allocator, self.hook, &self.reaper, channels, settings);
    }

    fn close(self: *Rig, index: u8) void {
        self.tuners.close(testing.allocator, self.hook, &self.reaper, index);
    }
};

const mono0 = Channels{ .first = 0, .stereo = false };
const mono1 = Channels{ .first = 1, .stereo = false };

test "phones on the same input share one source, tap and worker; the last to leave closes it" {
    var rig = try Rig.init();
    defer rig.deinit();
    const a = try rig.open(mono1, .{});
    const b = try rig.open(mono1, .{ .reference_hz = 442 }); // joins: keeps the source's settings
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u8, 2), rig.tuners.source(a).phones);
    try testing.expectEqual(@as(usize, 1), rig.hook.openTaps());
    try testing.expectEqual(@as(f64, 440), rig.tuners.source(a).worker.snapshot().settings.reference_hz);

    rig.close(a);
    try testing.expect(rig.tuners.source(a).worker.isRunning());
    try testing.expectEqual(@as(usize, 1), rig.hook.openTaps());
    rig.close(b);
    try testing.expectEqual(@as(usize, 0), rig.tuners.openCount());
    try testing.expectEqual(@as(usize, 0), rig.hook.openTaps());
    try testing.expect(!rig.hook.registered);
}

test "two inputs are two independent sources, and a third phone joins one of them" {
    var rig = try Rig.init();
    defer rig.deinit();
    const bass = try rig.open(mono0, .{});
    const guitar = try rig.open(mono1, .{});
    try testing.expect(bass != guitar);
    try testing.expectEqual(@as(usize, 2), rig.hook.openTaps());
    rig.tuners.source(bass).worker.setReference(442);
    try testing.expectEqual(@as(f64, 440), rig.tuners.source(guitar).worker.snapshot().settings.reference_hz);

    const third = try rig.open(mono1, .{});
    try testing.expectEqual(guitar, third);
    try testing.expectEqual(@as(usize, 2), rig.hook.openTaps());
    try testing.expectEqual(@as(u8, 2), rig.tuners.source(guitar).phones);
    try testing.expectEqual(@as(u32, 1), rig.reaper.registers);
}

test "mono input 1 and the stereo pair on it are different sources" {
    var rig = try Rig.init();
    defer rig.deinit();
    const m = try rig.open(mono0, .{});
    const s = try rig.open(.{ .first = 0, .stereo = true }, .{});
    try testing.expect(m != s);
}

test "a new source starts from the settings it is given, held to the tuner's range" {
    var rig = try Rig.init();
    defer rig.deinit();
    const i = try rig.open(mono0, .{ .reference_hz = 442, .silence_db = -120 });
    try testing.expectEqual(pitch.Settings{ .reference_hz = 442, .silence_db = -90 }, rig.tuners.source(i).worker.snapshot().settings);
}

test "a refused hook opens no source and leaves no tap" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.reaper.refuse = true;
    try testing.expectError(error.AudioHookFailed, rig.open(mono0, .{}));
    try testing.expectEqual(@as(usize, 0), rig.tuners.openCount());
    try testing.expectEqual(CantTune.audio_hook_failed, CantTune.fromOpenError(error.AudioHookFailed));
}

test "closing a source twice changes nothing" {
    var rig = try Rig.init();
    defer rig.deinit();
    const i = try rig.open(mono0, .{});
    rig.close(i);
    rig.close(i);
    try testing.expectEqual(@as(u32, 1), rig.reaper.unregisters);
}

const FakeDevice = audio_hook.FakeDevice;

/// Sines on hardware inputs 0 and 1, block by block, as the device delivers them.
const Feed = struct {
    phase: [2]f64 = .{ 0, 0 },

    /// One 256-sample block: `hz[i]` at `amp[i]` on input i (0 is silence).
    fn block(self: *Feed, hook: *audio_hook.Hook, hz: [2]f64, amp: [2]f64, rate: f64) void {
        var ins: [2][256]f64 = undefined;
        for (0..2) |c| {
            for (&ins[c]) |*x| {
                x.* = amp[c] * @sin(self.phase[c]);
                self.phase[c] += 2 * std.math.pi * hz[c] / rate;
            }
            self.phase[c] = @mod(self.phase[c], 2 * std.math.pi);
        }
        FakeDevice.inputBlock(hook, &.{ &ins[0], &ins[1] }, rate);
    }
};

fn expectNote(reading: pitch.Reading, note: i32, hz: f64) !void {
    try testing.expectEqual(note, reading.note);
    try testing.expect(@abs(reading.freq_hz - hz) < 0.05);
    try testing.expect(@abs(reading.cents) < 1.0);
}

test "two inputs fed different notes each read only their own, and a third phone on one shares its reading" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.tuners.tick_ns = null; // the tuner's own 30 Hz
    const bass = try rig.open(mono0, .{});
    const guitar = try rig.open(mono1, .{});

    // Blocks of 256 samples at 48 kHz, one every 5.3 ms: 0.34 s of silence,
    // then E2 on input 1 and A3 on input 2, until both read (or 4 s,
    // generous for a loaded machine).
    var feed = Feed{};
    const block_ns = 5_333_333;
    var timer = try std.time.Timer.start();
    var n: u64 = 0;
    while (n < 64) : (n += 1) {
        feed.block(rig.hook, .{ 82.41, 220 }, .{ 0, 0 }, 48000);
        std.Thread.sleep(n * block_ns -| timer.read());
    }
    while (n < 64 + 750) : (n += 1) {
        feed.block(rig.hook, .{ 82.41, 220 }, .{ 0.5, 0.5 }, 48000);
        std.Thread.sleep(n * block_ns -| timer.read());
        const b = rig.tuners.source(bass).worker.snapshot().reading;
        const g = rig.tuners.source(guitar).worker.snapshot().reading;
        if (n > 64 + 60 and b.note == 40 and g.note == 57) break;
    }
    try expectNote(rig.tuners.source(bass).worker.snapshot().reading, 40, 82.41);
    try expectNote(rig.tuners.source(guitar).worker.snapshot().reading, 57, 220);

    // A third phone on the guitar's input shares its source, and its reading.
    const third = try rig.open(mono1, .{});
    try testing.expectEqual(guitar, third);
    try expectNote(rig.tuners.source(third).worker.snapshot().reading, 57, 220);
}

test "a tap's input at a new sample rate is analysed at that rate" {
    const hook = try testing.allocator.create(audio_hook.Hook);
    defer testing.allocator.destroy(hook);
    hook.* = .{};
    var reaper = FakeRegistrar{};
    const tap = try hook.openTap(&reaper, mono1);
    const analysis = try tuner_worker.Analysis.create(testing.allocator);
    defer testing.allocator.destroy(analysis);
    var feed = Feed{};

    for ([_]f64{ 48000, 96000 }) |rate| {
        // 0.3 s of silence, then 0.8 s of A3 on input 2, ticking every 1/30 s.
        const per_tick = rate / 30.0;
        var since: f64 = 0;
        var done: f64 = 0;
        while (done < 1.1 * rate) : (done += 256) {
            const amp: f64 = if (done < 0.3 * rate) 0 else 0.5;
            feed.block(hook, .{ 82.41, 220 }, .{ 0.5, amp }, rate);
            since += 256;
            if (since >= per_tick) {
                since -= per_tick;
                _ = analysis.tick(hook.tapRing(tap.index), tap.tag, .{});
            }
        }
        try testing.expectEqual(rate, analysis.rate);
        // Read at the old rate, 96 kHz audio would read an octave down.
        try expectNote(analysis.reading, 57, 220);
    }
}
