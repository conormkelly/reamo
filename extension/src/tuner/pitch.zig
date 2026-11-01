//! The tuner's pitch analyser: mono samples in, a frequency, note, cents
//! and confidence out, whenever the caller asks (the tuner asks at 30 Hz).
//!
//! The pitch detector is YIN as PitchDetect.jsfx runs it (FFT
//! autocorrelation, the difference function with exact energy terms, the
//! first dip of the cumulative mean normalised difference under 0.15,
//! parabolic interpolation on the raw difference), with three changes, each
//! chosen by measuring it on synthetic signals:
//!
//! - The input passes a 2 kHz Butterworth low-pass first. Upper harmonics
//!   narrow the difference function's dip until a parabola no longer fits
//!   it: unfiltered, a sawtooth at E6 reads 1.3-1.9 cents off; filtered, under
//!   0.1. The filter also takes out most of a wide-band noise floor (tones
//!   at 10 dB SNR stay on the note) and tempers the pull of a stiff
//!   string's sharp upper partials. The tuner's range ends near 2 kHz, so
//!   no fundamental it reads is lost.
//! - The window is a fixed 92.9 ms (the JSFX's 4096 samples at 44.1 kHz)
//!   at every sample rate, analysed at 44.1-48 kHz: above 48 kHz only every
//!   D-th filtered sample is kept (D = 2 at 88.2 and 96 kHz, 4 at 176.4
//!   and 192 kHz), the low-pass doubling as the anti-alias filter. Bass E1
//!   and B0 read at any rate, and the cost and memory stay those of the
//!   48 kHz case. Analysing at 22-24 kHz would halve the cost but misses
//!   the +-1 cent target at E6.
//! - A pitch is reported only when the signal is periodic enough: with no
//!   dip under 0.15, the deepest one must still be under 0.3, or there is
//!   no pitch. Noise, which the JSFX turns into notes, reads as no pitch.
//!
//! The window is analysed only when `analyse` is called, not every hop.
//! Nothing is allocated after `init`: the caller owns the `Analyser`
//! (about 330 KB, so not on the stack) and calls `push` and `analyse` from
//! one thread, not the audio thread.
const std = @import("std");
const fft_mod = @import("fft.zig");

/// What the tuner's user sets.
pub const Settings = struct {
    /// A4's frequency. Readings are none unless it is positive and finite;
    /// tuner/setParam holds it to 400-480 Hz.
    reference_hz: f64 = 440,
    /// A window whose input RMS is under this many dBFS is silence.
    silence_db: f64 = -60,
};

pub const Reading = struct {
    /// 0 when there is no pitch: silence, noise, or no periodicity.
    freq_hz: f64,
    /// MIDI note nearest the frequency (A4 = 69).
    note: i32,
    /// From the note, -50 to +50.
    cents: f64,
    /// 1 minus the aperiodicity at the detected period, 0 to 1.
    confidence: f64,

    pub const none: Reading = .{ .freq_hz = 0, .note = 0, .cents = 0, .confidence = 0 };
};

pub const min_sample_rate = 8000;
pub const max_sample_rate = 384000;

const window_seconds = 4096.0 / 44100.0;
/// The shortest period searched, as a frequency (as in the JSFX).
const max_pitch_hz = 2000.0;
/// YIN's absolute threshold: the first dip under it is the period.
const dip_threshold = 0.15;

/// How the analyser is built. The defaults are the tuner's; the other
/// values exist so the bench can measure what each choice buys.
pub const Options = struct {
    /// Cut-off of the input low-pass; null for none.
    lowpass_hz: ?f64 = 2000,
    /// Above this rate only every D-th filtered sample is analysed, with D
    /// the smallest whole number that brings the rate down to it.
    max_analysis_rate: f64 = 48000,
    /// With no dip under the dip threshold, the deepest dip must be under
    /// this for a pitch; null reports the deepest dip whatever its depth,
    /// as the JSFX does.
    voicing_threshold: ?f64 = 0.3,
};

/// The tuner's analyser.
pub const Analyser = AnalyserWith(.{});

pub fn AnalyserWith(comptime options: Options) type {
    const max_window: usize = @intFromFloat(@ceil(window_seconds * options.max_analysis_rate));
    const max_fft = std.math.ceilPowerOfTwo(usize, max_window + max_window / 2) catch unreachable;
    return struct {
        const Self = @This();

        sample_rate: f64,
        /// Every `decimation`-th filtered input sample is analysed.
        decimation: usize,
        analysis_rate: f64,
        /// Window length in analysed samples.
        window: usize,
        fft_size: usize,

        lowpass: Biquad,
        /// Input samples since the last kept one.
        phase: usize,
        /// Sum of squares of the unfiltered input since the last kept sample.
        energy_acc: f64,

        /// The last `window` kept samples, a ring starting at `write_pos`.
        history: [max_window]f64,
        /// Per kept sample, the unfiltered input energy it stands for.
        energy: [max_window]f64,
        write_pos: usize,

        fft: fft_mod.Fft(max_fft),
        fft_work: [max_fft / 2]fft_mod.Complex,
        /// The window, oldest sample first.
        frame: [max_window]f64,
        autocorr: [max_window / 2]f64,
        cum_energy: [max_window]f64,
        diff: [max_window / 2]f64,
        cmnd: [max_window / 2]f64,

        /// Sets up for `sample_rate` and starts from silence.
        pub fn init(self: *Self, sample_rate: f64) error{UnsupportedSampleRate}!void {
            if (!(sample_rate >= min_sample_rate and sample_rate <= max_sample_rate)) return error.UnsupportedSampleRate;
            const decimation: usize = @intFromFloat(@ceil(sample_rate / options.max_analysis_rate));
            const analysis_rate = sample_rate / @as(f64, @floatFromInt(decimation));
            const window: usize = @intFromFloat(@round(window_seconds * analysis_rate));
            self.sample_rate = sample_rate;
            self.decimation = decimation;
            self.analysis_rate = analysis_rate;
            self.window = window;
            self.fft_size = std.math.ceilPowerOfTwo(usize, window + window / 2) catch unreachable;
            self.lowpass = if (options.lowpass_hz) |hz| Biquad.lowpass(sample_rate, hz) else Biquad.passthrough;
            self.fft.init();
            self.reset();
        }

        /// Forgets all input, as if the analyser had only heard silence.
        pub fn reset(self: *Self) void {
            self.lowpass.clear();
            self.phase = 0;
            self.energy_acc = 0;
            @memset(&self.history, 0);
            @memset(&self.energy, 0);
            self.write_pos = 0;
        }

        /// Adds mono input. Non-finite samples count as silence, so one bad
        /// sample can't poison the filter.
        pub fn push(self: *Self, samples: []const f32) void {
            for (samples) |s| {
                const x: f64 = if (std.math.isFinite(s)) s else 0;
                self.energy_acc += x * x;
                const y = self.lowpass.step(x);
                self.phase += 1;
                if (self.phase == self.decimation) {
                    self.phase = 0;
                    self.history[self.write_pos] = y;
                    self.energy[self.write_pos] = self.energy_acc;
                    self.energy_acc = 0;
                    self.write_pos += 1;
                    if (self.write_pos == self.window) self.write_pos = 0;
                }
            }
        }

        /// The pitch of the last 92.9 ms of input.
        pub fn analyse(self: *Self, settings: Settings) Reading {
            if (!(settings.reference_hz > 0 and std.math.isFinite(settings.reference_hz))) return Reading.none;
            const w = self.window;

            var energy: f64 = 0;
            for (self.energy[0..w]) |e| energy += e;
            const rms = @sqrt(energy / @as(f64, @floatFromInt(w * self.decimation)));
            if (20 * std.math.log10(@max(rms, 1e-7)) < settings.silence_db) return Reading.none;

            self.difference();
            const best = self.pickPeriod() orelse return Reading.none;
            const freq = self.analysis_rate / self.interpolate(best);
            const midi = 69 + 12 * @log2(freq / settings.reference_hz);
            const note = @floor(midi + 0.5);
            return .{
                .freq_hz = freq,
                .note = @intFromFloat(note),
                .cents = (midi - note) * 100,
                .confidence = std.math.clamp(1 - self.cmnd[best], 0, 1),
            };
        }

        /// YIN's difference function d(tau) over the window, through the FFT
        /// autocorrelation r(tau): d(tau) = E(0, W-tau) + E(tau, W) - 2 r(tau),
        /// and its cumulative mean normalised form.
        fn difference(self: *Self) void {
            const w = self.window;
            var sum: f64 = 0;
            for (0..w) |i| {
                const x = self.history[(self.write_pos + i) % w];
                self.frame[i] = x;
                sum += x * x;
                self.cum_energy[i] = sum;
            }
            self.fft.autocorrelate(self.frame[0..w], self.fft_size, &self.fft_work, self.autocorr[0 .. w / 2]);

            self.diff[0] = 0;
            self.cmnd[0] = 1;
            var running: f64 = 0;
            for (1..w / 2) |tau| {
                const head = self.cum_energy[w - tau - 1];
                const tail = self.cum_energy[w - 1] - self.cum_energy[tau - 1];
                const d = @max(0, head + tail - 2 * self.autocorr[tau]);
                self.diff[tau] = d;
                running += d;
                self.cmnd[tau] = if (running > 0) d * @as(f64, @floatFromInt(tau)) / running else 1;
            }
        }

        /// The period in analysed samples: the first local minimum of the
        /// normalised difference under `dip_threshold`, or else the deepest
        /// one if it is under `options.voicing_threshold`.
        fn pickPeriod(self: *const Self) ?usize {
            const half = self.window / 2;
            const min_tau: usize = @max(2, @as(usize, @intFromFloat(self.analysis_rate / max_pitch_hz)));
            const c = self.cmnd[0..half];
            var tau = min_tau;
            while (tau < half - 2) : (tau += 1) {
                if (c[tau] < dip_threshold and c[tau] < c[tau - 1] and c[tau] <= c[tau + 1]) return tau;
            }
            var best = min_tau;
            for (min_tau + 1..half - 1) |t| {
                if (c[t] < c[best]) best = t;
            }
            const limit = options.voicing_threshold orelse return best;
            return if (c[best] < limit) best else null;
        }

        /// The period to a fraction of a sample: a parabola through the raw
        /// difference at tau - 1, tau and tau + 1.
        fn interpolate(self: *const Self, tau: usize) f64 {
            const period: f64 = @floatFromInt(tau);
            if (tau < 2 or tau >= self.window / 2 - 2) return period;
            const s0 = self.diff[tau - 1];
            const s1 = self.diff[tau];
            const s2 = self.diff[tau + 1];
            const curvature = s0 - 2 * s1 + s2;
            if (curvature == 0) return period;
            return period + std.math.clamp((s0 - s2) / (2 * curvature), -1, 1);
        }
    };
}

/// Second-order Butterworth low-pass (RBJ cookbook, Q = 1/sqrt(2)),
/// transposed direct form II.
const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64 = 0,
    z2: f64 = 0,

    fn lowpass(sample_rate: f64, cutoff_hz: f64) Biquad {
        const w0 = 2 * std.math.pi * cutoff_hz / sample_rate;
        const cos_w0 = @cos(w0);
        const alpha = @sin(w0) / (2 * std.math.sqrt1_2);
        const a0 = 1 + alpha;
        return .{
            .b0 = (1 - cos_w0) / 2 / a0,
            .b1 = (1 - cos_w0) / a0,
            .b2 = (1 - cos_w0) / 2 / a0,
            .a1 = -2 * cos_w0 / a0,
            .a2 = (1 - alpha) / a0,
        };
    }

    const passthrough: Biquad = .{ .b0 = 1, .b1 = 0, .b2 = 0, .a1 = 0, .a2 = 0 };

    fn clear(self: *Biquad) void {
        self.z1 = 0;
        self.z2 = 0;
    }

    fn step(self: *Biquad, x: f64) f64 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const signals = @import("signals.zig");

const required_rates = [_]f64{ 44100, 48000, 88200, 96000 };

fn newAnalyser(sample_rate: f64) !*Analyser {
    const a = try testing.allocator.create(Analyser);
    errdefer testing.allocator.destroy(a);
    try a.init(sample_rate);
    return a;
}

/// Pushes `seconds` of `signal` in 256-sample blocks, as an audio callback
/// would, and returns the reading at the end.
fn readAfter(a: *Analyser, signal: []const f32, settings: Settings) Reading {
    var pos: usize = 0;
    while (pos < signal.len) : (pos += 256) a.push(signal[pos..@min(signal.len, pos + 256)]);
    return a.analyse(settings);
}

fn generate(comptime len: usize) !*[len]f32 {
    return testing.allocator.create([len]f32);
}

fn centsOff(r: Reading, truth: f64) f64 {
    return signals.cents(r.freq_hz, truth);
}

test "reads a steady sine within two hundredths of a cent from B0 to E6 at every required rate" {
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    for (required_rates) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        for ([_]f64{ 30.8677, 41.2034, 82.4069, 110, 196, 329.628, 659.255, 1318.51 }) |f0| {
            const s = buf[0..@intFromFloat(sr * 0.5)];
            signals.sine(s, sr, f0, 0.5, 0.3);
            a.reset();
            const r = readAfter(a, s, .{});
            errdefer std.debug.print("{d} Hz at {d}: {any}\n", .{ f0, sr, r });
            try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, f0), 0.02);
            try testing.expect(r.confidence > 0.95);
        }
    }
}

test "reads bass E1 and B0 at 88.2 and 96 kHz, where the JSFX's 4096 samples are too short" {
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 88200, 96000 }) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        for ([_]f64{ 30.8677, 41.2034 }) |f0| {
            const s = buf[0..@intFromFloat(sr)];
            signals.pluck(s, sr, f0, .{ .t60_s = 5, .excitation_lowpass = 0.9 });
            a.reset();
            const r = readAfter(a, s[0..@intFromFloat(sr * 0.6)], .{});
            try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, f0), 0.5);
        }
    }
}

test "a sawtooth's upper harmonics do not pull the reading at the top of the guitar's range" {
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 44100, 48000 }) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        const s = buf[0..@intFromFloat(sr * 0.5)];
        signals.sawtooth(s, sr, 1318.51, 0.3);
        // Unfiltered, YIN reads this 1.3-1.9 cents off (the JSFX does).
        try testing.expectApproxEqAbs(@as(f64, 0), centsOff(readAfter(a, s, .{}), 1318.51), 0.2);
    }
}

test "reads the fundamental of a tone whose fundamental is missing" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(24000);
    defer testing.allocator.destroy(buf);
    signals.harmonics(buf, 48000, 98, &.{ 0, 0.3, 0.25, 0.2, 0.15, 0.1 });
    try testing.expectApproxEqAbs(@as(f64, 0), centsOff(readAfter(a, buf, .{}), 98), 0.1);
}

test "a DC offset doesn't move the reading" {
    const a = try newAnalyser(44100);
    defer testing.allocator.destroy(a);
    const buf = try generate(22050);
    defer testing.allocator.destroy(buf);
    signals.sawtooth(buf, 44100, 146.832, 0.3);
    const without = readAfter(a, buf, .{});
    signals.addDc(buf, 0.3);
    a.reset();
    const with = readAfter(a, buf, .{});
    try testing.expect(without.freq_hz > 0);
    try testing.expectApproxEqAbs(@as(f64, 0), signals.cents(with.freq_hz, without.freq_hz), 0.001);
}

test "names the note and its cents against the reference pitch" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(24000);
    defer testing.allocator.destroy(buf);
    signals.sine(buf, 48000, 440, 0.5, 0);
    a.push(buf);
    const at_440 = a.analyse(.{ .reference_hz = 440 });
    try testing.expectEqual(@as(i32, 69), at_440.note);
    try testing.expectApproxEqAbs(@as(f64, 0), at_440.cents, 0.01);
    // A4 = 442: 440 Hz is A4, 7.85 cents flat.
    const at_442 = a.analyse(.{ .reference_hz = 442 });
    try testing.expectEqual(@as(i32, 69), at_442.note);
    try testing.expectApproxEqAbs(@as(f64, -7.851), at_442.cents, 0.01);
    // E2 30 cents sharp is E2 +30, not F2 -70.
    a.reset();
    signals.sine(buf, 48000, signals.midiToHz(40.3, 440), 0.5, 0);
    a.push(buf);
    const e2_sharp = a.analyse(.{});
    try testing.expectEqual(@as(i32, 40), e2_sharp.note);
    try testing.expectApproxEqAbs(@as(f64, 30), e2_sharp.cents, 0.01);
}

test "reports no pitch for silence, and for a tone under the silence threshold" {
    const a = try newAnalyser(44100);
    defer testing.allocator.destroy(a);
    const buf = try generate(22050);
    defer testing.allocator.destroy(buf);
    @memset(buf, 0);
    try testing.expectEqual(Reading.none, readAfter(a, buf, .{}));
    // 196 Hz at -66 dBFS RMS: under -60, over -70.
    signals.sine(buf, 44100, 196, 0.0007, 0);
    try testing.expectEqual(Reading.none, readAfter(a, buf, .{ .silence_db = -60 }));
    try testing.expect(readAfter(a, buf, .{ .silence_db = -70 }).freq_hz > 0);
}

test "reports no pitch for noise above the silence threshold" {
    // The JSFX reports a note for any noise louder than its threshold.
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    for (required_rates, 0..) |sr, i| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        const s = buf[0..@intFromFloat(sr)];
        for ([_]f64{ -50, -30, -10 }) |level_db| {
            @memset(s, 0);
            signals.addNoise(s, std.math.pow(f64, 10, level_db / 20), 40 + i);
            a.reset();
            var pos: usize = 0;
            while (pos < s.len) : (pos += 1470) {
                a.push(s[pos..@min(s.len, pos + 1470)]);
                try testing.expectEqual(Reading.none, a.analyse(.{}));
            }
        }
    }
}

test "a pluck after silence reads within 5 cents in under 100 ms" {
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 82.4069, 329.628, 41.2034 }) |f0| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        @memset(buf, 0);
        a.push(buf[0..14400]); // 0.3 s of silence
        signals.pluck(buf, 48000, f0, .{ .seed = 7 });
        a.push(buf[0..4800]); // 100 ms of pluck
        try testing.expectApproxEqAbs(@as(f64, 0), centsOff(a.analyse(.{}), f0), 5);
    }
}

test "the reading does not depend on how the input is split into pushes" {
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    signals.pluck(buf, 96000, 110, .{});
    const whole = try newAnalyser(96000);
    defer testing.allocator.destroy(whole);
    whole.push(buf);
    const pieces = try newAnalyser(96000);
    defer testing.allocator.destroy(pieces);
    var pos: usize = 0;
    var size: usize = 1;
    while (pos < buf.len) : (size = size * 3 % 1021 + 1) {
        const end = @min(buf.len, pos + size);
        pieces.push(buf[pos..end]);
        pos = end;
    }
    try testing.expectEqual(whole.analyse(.{}), pieces.analyse(.{}));
}

test "analysing twice without new input gives the same reading" {
    const a = try newAnalyser(44100);
    defer testing.allocator.destroy(a);
    const buf = try generate(22050);
    defer testing.allocator.destroy(buf);
    signals.pluck(buf, 44100, 196, .{});
    a.push(buf);
    const first = a.analyse(.{});
    try testing.expect(first.freq_hz > 0);
    try testing.expectEqual(first, a.analyse(.{}));
}

test "a non-finite input sample doesn't stop later readings" {
    const a = try newAnalyser(44100);
    defer testing.allocator.destroy(a);
    const buf = try generate(22050);
    defer testing.allocator.destroy(buf);
    signals.sine(buf, 44100, 220, 0.5, 0);
    buf[100] = std.math.nan(f32);
    buf[200] = std.math.inf(f32);
    a.push(buf);
    try testing.expectApproxEqAbs(@as(f64, 0), centsOff(a.analyse(.{}), 220), 0.01);
}

test "reset forgets earlier input" {
    const a = try newAnalyser(44100);
    defer testing.allocator.destroy(a);
    const buf = try generate(22050);
    defer testing.allocator.destroy(buf);
    signals.sine(buf, 44100, 220, 0.5, 0);
    a.push(buf);
    try testing.expect(a.analyse(.{}).freq_hz > 0);
    a.reset();
    try testing.expectEqual(Reading.none, a.analyse(.{}));
}

test "reads the same at 176.4 and 192 kHz and at rates between the common ones" {
    const buf = try generate(192000 / 2);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 22050, 32000, 64000, 176400, 192000 }) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        const s = buf[0..@intFromFloat(sr * 0.5)];
        signals.sawtooth(s, sr, 110, 0.3);
        errdefer std.debug.print("at {d}\n", .{sr});
        try testing.expectApproxEqAbs(@as(f64, 0), centsOff(readAfter(a, s, .{}), 110), 0.05);
    }
}

test "refuses sample rates it can't analyse" {
    var a: Analyser = undefined;
    for ([_]f64{ 0, -44100, 4000, 400000, std.math.nan(f64), std.math.inf(f64) }) |sr| {
        try testing.expectError(error.UnsupportedSampleRate, a.init(sr));
    }
}

test "reports no pitch for a reference pitch that isn't a positive number" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(24000);
    defer testing.allocator.destroy(buf);
    signals.sine(buf, 48000, 440, 0.5, 0);
    a.push(buf);
    for ([_]f64{ 0, -440, std.math.nan(f64), std.math.inf(f64) }) |ref| {
        try testing.expectEqual(Reading.none, a.analyse(.{ .reference_hz = ref }));
    }
}
