//! The tuner's pitch-analyser bench: `zig build tuner-bench` (add
//! `-Doptimize=ReleaseFast` or `ReleaseSafe` for CPU figures that mean
//! anything). Runs the ported PitchDetect.jsfx, the tuner's analyser and
//! one variant per design choice over synthetic signals at 44.1, 48, 88.2
//! and 96 kHz, and prints a summary table, per-family detail and CPU cost.
//! A name passed after `--` runs only the candidates whose name contains it.
//!
//! Every candidate hears 100 ms of silence and then the input in 256-sample
//! blocks, and is read every sample_rate / 30 samples, as the tuner reads
//! it. Measures:
//!
//! - Steady tones, read from 0.3 s (0.2 s for plucks) to 1.6 s (1.2 s for
//!   plucks, which decay towards the -60 dB silence threshold). Per tone, the
//!   mean and standard deviation (jitter) of the cents error over readings
//!   within 50 cents of the truth. A reading further off, or none, is
//!   wrong; an octave error is a wrong reading within 50 cents of a whole
//!   number of octaves away. A tone meets the target when its mean is
//!   within 1 cent, its jitter under 0.5 cent and no reading is wrong
//!   (good hardware tuners claim +-1 cent). A tone is on the note when at
//!   least 90% of its readings are within 50 cents.
//! - False notes: the share of readings with a pitch, on silence and noise.
//! - Time to lock: from a pluck's onset (after silence, or over the last
//!   note at -12 dB) to the first reading from which every reading to the
//!   end is within 5 cents.
//! - Vibrato: RMS error against the vibrato's frequency at the middle of
//!   the candidate's window.
//! - Two notes at once: what is read.
//! - CPU: push cost per second of input, and analyse() time (median of
//!   300 calls), giving the share of one core when read at 30 Hz.
const std = @import("std");
const builtin = @import("builtin");
const sig = @import("signals.zig");
const jsfx = @import("jsfx_port.zig");
const pitch = @import("pitch.zig");

const rates = [_]f64{ 44100, 48000, 88200, 96000 };

/// Standard tuning E2-E4, the 12th fret of the high E (E5) and the 24th (E6).
const guitar = [_]f64{ 82.4069, 110.0, 146.832, 195.998, 246.942, 329.628, 659.255, 1318.51 };
/// Drop D's and drop C's low strings (D2 is also the bass's D string).
const drop_tunings = [_]f64{ 73.4162, 65.4064 };
/// Bass E1, A1, G2 and a five-string's B0.
const bass = [_]f64{ 41.2034, 55.0, 97.9989, 30.8677 };
const high = [_]f64{ 880.0, 1046.50, 1760.0 };
const all_pitches = guitar ++ drop_tunings ++ bass ++ high;

const Reading = struct { freq: f64 };

/// One analyser under test, behind a uniform interface.
const Candidate = struct {
    name: []const u8,
    ctx: *anyopaque,
    resetFn: *const fn (*anyopaque, f64) void,
    pushFn: *const fn (*anyopaque, []const f32) void,
    readFn: *const fn (*anyopaque) Reading,
    window_seconds: *const fn (f64) f64,

    fn reset(self: Candidate, sample_rate: f64) void {
        self.resetFn(self.ctx, sample_rate);
    }
    fn push(self: Candidate, samples: []const f32) void {
        self.pushFn(self.ctx, samples);
    }
    fn read(self: Candidate) Reading {
        return self.readFn(self.ctx);
    }
};

fn analyserCandidate(comptime T: type, name: []const u8, allocator: std.mem.Allocator) !Candidate {
    return analyserCandidateWith(T, .{}, name, allocator);
}

fn analyserCandidateWith(comptime T: type, comptime settings: pitch.Settings, name: []const u8, allocator: std.mem.Allocator) !Candidate {
    const Adapter = struct {
        fn reset(ctx: *anyopaque, sample_rate: f64) void {
            const a: *T = @ptrCast(@alignCast(ctx));
            a.init(sample_rate) catch unreachable;
        }
        fn push(ctx: *anyopaque, samples: []const f32) void {
            const a: *T = @ptrCast(@alignCast(ctx));
            a.push(samples);
        }
        fn read(ctx: *anyopaque) Reading {
            const a: *T = @ptrCast(@alignCast(ctx));
            return .{ .freq = a.analyse(settings).freq_hz };
        }
        fn window(_: f64) f64 {
            return 4096.0 / 44100.0;
        }
    };
    return .{
        .name = name,
        .ctx = try allocator.create(T),
        .resetFn = Adapter.reset,
        .pushFn = Adapter.push,
        .readFn = Adapter.read,
        .window_seconds = Adapter.window,
    };
}

fn jsfxCandidate(allocator: std.mem.Allocator) !Candidate {
    const Adapter = struct {
        fn reset(ctx: *anyopaque, sample_rate: f64) void {
            const p: *jsfx.JsfxPort = @ptrCast(@alignCast(ctx));
            p.init(sample_rate);
        }
        fn push(ctx: *anyopaque, samples: []const f32) void {
            const p: *jsfx.JsfxPort = @ptrCast(@alignCast(ctx));
            for (samples) |s| _ = p.pushSample(s);
        }
        fn read(ctx: *anyopaque) Reading {
            const p: *jsfx.JsfxPort = @ptrCast(@alignCast(ctx));
            return .{ .freq = p.outputs().freq };
        }
        fn window(sample_rate: f64) f64 {
            return jsfx.win_size / sample_rate;
        }
    };
    return .{
        .name = "jsfx",
        .ctx = try allocator.create(jsfx.JsfxPort),
        .resetFn = Adapter.reset,
        .pushFn = Adapter.push,
        .readFn = Adapter.read,
        .window_seconds = Adapter.window,
    };
}

const candidate_notes = [_][2][]const u8{
    .{ "jsfx", "PitchDetect.jsfx ported: 4096 samples, analysed every 512, read at 30 Hz" },
    .{ "analyser", "the tuner's: 2 kHz low-pass, analysed at 44.1-48 kHz, voicing gate 0.3, first-partial refinement, octave hold, learned noise floor and onset gate" },
    .{ "no-lowpass", "the analyser without its low-pass, so analysing at the input rate (the JSFX's YIN with a 92.9 ms window and the voicing gate)" },
    .{ "lowpass-1k", "the analyser with a 1 kHz low-pass" },
    .{ "rate-24k", "the analyser analysing at 22.05-24 kHz" },
    .{ "no-voicing", "the analyser reporting the deepest dip whatever its depth, as the JSFX" },
    .{ "yin-only", "the analyser reporting YIN's period, without the first-partial refinement, octave hold, learned noise floor and onset gate" },
    .{ "no-octave-hold", "the analyser without the octave hold" },
    .{ "fixed-gate", "the analyser gated only by a -60 dBFS silence threshold, without the learned floor, the onset gate and the release check" },
    .{ "mains-rule", "the analyser with the mains rule" },
};

var readings_buf: [256]Reading = undefined;

/// Feeds 100 ms of silence, then `signal` in 256-sample blocks, and reads
/// at every 30 Hz tick of the signal: readings[i] is the reading after
/// (i + 1) ticks. The silence makes the signal's start an onset, as a
/// pluck after silence is (the analyser takes the start of its input for
/// something already sounding).
fn run(c: Candidate, sample_rate: f64, signal: []const f32) []const Reading {
    c.reset(sample_rate);
    const zeros = [_]f32{0} ** 256;
    var lead: usize = @intFromFloat(0.1 * sample_rate);
    while (lead > 0) {
        const n = @min(lead, zeros.len);
        c.push(zeros[0..n]);
        lead -= n;
    }
    const tick: usize = @intFromFloat(@round(sample_rate / 30.0));
    var pos: usize = 0;
    var next_tick = tick;
    var n: usize = 0;
    while (pos < signal.len) {
        const end = @min(signal.len, pos + 256, next_tick);
        c.push(signal[pos..end]);
        pos = end;
        if (pos == next_tick) {
            readings_buf[n] = c.read();
            n += 1;
            next_tick += tick;
        }
    }
    return readings_buf[0..n];
}

fn tickTime(i: usize, sample_rate: f64) f64 {
    return @as(f64, @floatFromInt(i + 1)) * @round(sample_rate / 30.0) / sample_rate;
}

// ---------------------------------------------------------------------------
// Steady tones

const Family = enum {
    sine,
    sawtooth,
    square,
    weak_fundamental,
    missing_fundamental,
    pluck,
    bass_pluck,
    detuned,
    dc_offset,
    snr_30db,
    snr_20db,
    snr_10db,
    snr_0db,
    stiff_bright,
    stiff_mellow,
};
const families = std.enums.values(Family);
const clean_families = [_]Family{ .sine, .sawtooth, .square, .weak_fundamental, .missing_fundamental, .pluck, .bass_pluck, .detuned, .dc_offset };

fn familyNote(f: Family) []const u8 {
    return switch (f) {
        .sine => "sine",
        .sawtooth => "band-limited sawtooth",
        .square => "band-limited square",
        .weak_fundamental => "fundamental 20 dB under the 2nd harmonic",
        .missing_fundamental => "harmonics 2-8 only",
        .pluck => "Karplus-Strong pluck, t60 3 s",
        .bass_pluck => "bass pluck: dull attack, t60 5 s",
        .detuned => "sine 7 or 23 cents off a note",
        .dc_offset => "sawtooth + 0.3 DC",
        .snr_30db, .snr_20db, .snr_10db, .snr_0db => "sustained pluck + white noise",
        .stiff_bright => "stiff string, partials n f0 sqrt(1 + B n^2) at 1/n; truth is partial 1",
        .stiff_mellow => "stiff string as above, partials at 1/n^2",
    };
}

/// Inharmonicity: about 1e-4 for a guitar's wound strings, more for bass.
fn stiffness(f0: f64) f64 {
    return if (f0 < 60) 3e-4 else 1e-4;
}

fn makeSteady(out: []f32, f: Family, sr: f64, f0: f64, seed: u64) void {
    switch (f) {
        .sine, .detuned => sig.sine(out, sr, f0, 0.5, 0.3),
        .sawtooth => sig.sawtooth(out, sr, f0, 0.3),
        .square => sig.square(out, sr, f0, 0.3),
        .weak_fundamental => sig.harmonics(out, sr, f0, &.{ 0.03, 0.3, 0.25, 0.2, 0.15, 0.1, 0.08, 0.06 }),
        .missing_fundamental => sig.harmonics(out, sr, f0, &.{ 0, 0.3, 0.25, 0.2, 0.15, 0.1, 0.08, 0.06 }),
        // Loud enough to stay over the -60 dB silence threshold to 1.2 s.
        .pluck => sig.pluck(out, sr, f0, .{ .amp = 0.9, .t60_s = 3, .seed = seed }),
        .bass_pluck => sig.pluck(out, sr, f0, .{ .amp = 0.9, .t60_s = 5, .excitation_lowpass = 0.9, .seed = seed }),
        .snr_30db, .snr_20db, .snr_10db, .snr_0db => {
            sig.pluck(out, sr, f0, .{ .t60_s = 20, .seed = seed });
            const snr: f64 = switch (f) {
                .snr_30db => 30,
                .snr_20db => 20,
                .snr_10db => 10,
                else => 0,
            };
            const from: usize = @intFromFloat(0.2 * sr);
            sig.addNoise(out, sig.rms(out[from..]) / std.math.pow(f64, 10, snr / 20), seed + 7);
        },
        .dc_offset => {
            sig.sawtooth(out, sr, f0, 0.3);
            sig.addDc(out, 0.3);
        },
        .stiff_bright => stiffString(out, sr, f0, 1),
        .stiff_mellow => stiffString(out, sr, f0, 2),
    }
}

fn stiffString(out: []f32, sr: f64, f0: f64, rolloff: f64) void {
    @memset(out, 0);
    const b = stiffness(f0);
    for (1..31) |n| {
        const nf: f64 = @floatFromInt(n);
        const partial = nf * f0 * @sqrt(1 + b * nf * nf);
        if (partial >= sr / 2) break;
        const a = 0.3 / std.math.pow(f64, nf, rolloff);
        for (out, 0..) |*s, i| s.* += @floatCast(a * @sin(2 * std.math.pi * partial * @as(f64, @floatFromInt(i)) / sr));
    }
}

fn truth(f: Family, f0: f64) f64 {
    return switch (f) {
        .stiff_bright, .stiff_mellow => f0 * @sqrt(1 + stiffness(f0)),
        else => f0,
    };
}

fn pitchesOf(f: Family) []const f64 {
    return switch (f) {
        .bass_pluck => &(bass ++ drop_tunings[0..1].*),
        .detuned => &[_]f64{ 82.4069 * 1.00405, 110.0 / 1.0134, 196.0 * 1.0134, 329.628 / 1.00405, 41.2034 * 1.0134 },
        // Harmonics 2-8 of the highest notes are past where any tuner looks.
        .missing_fundamental => &(guitar[0..7].* ++ drop_tunings ++ bass ++ high[0..1].*),
        else => &all_pitches,
    };
}

const ToneStats = struct {
    tones: usize = 0,
    on_note: usize = 0,
    meets: usize = 0,
    sum_abs_mean: f64 = 0,
    worst_abs_mean: f64 = 0,
    worst_mean_tone: [24]u8 = undefined,
    worst_mean_len: usize = 0,
    sum_jitter: f64 = 0,
    worst_jitter: f64 = 0,
    readings: usize = 0,
    wrong: usize = 0,
    octave: usize = 0,
    none: usize = 0,
    misses: [400]u8 = undefined,
    misses_len: usize = 0,
    misses_more: usize = 0,

    fn add(self: *ToneStats, rs: []const Reading, want: f64, label: []const u8) void {
        var sum: f64 = 0;
        var sum2: f64 = 0;
        var good: usize = 0;
        for (rs) |r| {
            self.readings += 1;
            if (r.freq <= 0) {
                self.none += 1;
                continue;
            }
            const c = sig.cents(r.freq, want);
            if (@abs(c) > 50) {
                const k = @round(c / 1200);
                if (k != 0 and @abs(c - 1200 * k) < 50) self.octave += 1;
                continue;
            }
            sum += c;
            sum2 += c * c;
            good += 1;
        }
        const wrong = rs.len - good;
        self.wrong += wrong;
        self.tones += 1;
        var mean: f64 = 0;
        var jitter: f64 = 0;
        if (good * 10 >= rs.len * 9) {
            self.on_note += 1;
            const g: f64 = @floatFromInt(good);
            mean = sum / g;
            jitter = @sqrt(@max(0, sum2 / g - mean * mean));
            self.sum_abs_mean += @abs(mean);
            self.sum_jitter += jitter;
            self.worst_jitter = @max(self.worst_jitter, jitter);
            if (@abs(mean) > self.worst_abs_mean) {
                self.worst_abs_mean = @abs(mean);
                self.worst_mean_len = @min(label.len, self.worst_mean_tone.len);
                @memcpy(self.worst_mean_tone[0..self.worst_mean_len], label[0..self.worst_mean_len]);
            }
            if (@abs(mean) <= 1 and jitter <= 0.5 and wrong == 0) {
                self.meets += 1;
                return;
            }
        }
        const entry = if (good * 10 >= rs.len * 9)
            std.fmt.bufPrint(self.misses[self.misses_len..], "{s} ({d:.2} c, jitter {d:.2}, {d} wrong); ", .{ label, mean, jitter, wrong })
        else
            std.fmt.bufPrint(self.misses[self.misses_len..], "{s} (off the note); ", .{label});
        if (entry) |e| self.misses_len += e.len else |_| self.misses_more += 1;
    }

    fn merge(self: *ToneStats, other: ToneStats) void {
        self.tones += other.tones;
        self.on_note += other.on_note;
        self.meets += other.meets;
        self.sum_abs_mean += other.sum_abs_mean;
        self.sum_jitter += other.sum_jitter;
        self.readings += other.readings;
        self.wrong += other.wrong;
        self.octave += other.octave;
        self.none += other.none;
        self.worst_jitter = @max(self.worst_jitter, other.worst_jitter);
        if (other.worst_abs_mean > self.worst_abs_mean) {
            self.worst_abs_mean = other.worst_abs_mean;
            self.worst_mean_len = other.worst_mean_len;
            self.worst_mean_tone = other.worst_mean_tone;
        }
    }
};

// ---------------------------------------------------------------------------
// Results per candidate

const max_candidates = candidate_notes.len;

const Results = struct {
    family: [families.len]ToneStats = [_]ToneStats{.{}} ** families.len,
    false_hits: [noise_kinds.len]usize = .{0} ** noise_kinds.len,
    false_n: [noise_kinds.len]usize = .{0} ** noise_kinds.len,
    onset: LockStats = .{},
    change: LockStats = .{},
    vibrato_sq: f64 = 0,
    vibrato_n: usize = 0,
    vibrato_wrong: usize = 0,
    two: [chords.len][4]usize = [_][4]usize{.{ 0, 0, 0, 0 }} ** chords.len,
    two_other_hz: [chords.len]f64 = .{0} ** chords.len,
    cpu: [rates.len]Cpu = [_]Cpu{.{}} ** rates.len,
};

const LockStats = struct {
    sum_ms: f64 = 0,
    worst_ms: f64 = 0,
    never: usize = 0,
    n: usize = 0,

    fn add(self: *LockStats, ms: ?f64) void {
        self.n += 1;
        if (ms) |v| {
            self.sum_ms += v;
            self.worst_ms = @max(self.worst_ms, v);
        } else self.never += 1;
    }

    fn avg(self: LockStats) f64 {
        return self.sum_ms / @as(f64, @floatFromInt(@max(self.n - self.never, 1)));
    }
};

const Cpu = struct { push_ns_per_s: f64 = 0, analyse_ns: f64 = 0 };

const noise_kinds = [_][]const u8{ "silence", "-80 dB white", "-55 dB white", "-40 dB white", "-20 dB white", "-30 dB low rumble" };

const chords = [_][2]f64{ .{ 82.4069, 123.471 }, .{ 110.0, 164.814 }, .{ 82.4069, 110.0 }, .{ 196.0, 246.942 } };

fn lockTime(rs: []const Reading, sr: f64, start_s: f64, want: f64) ?f64 {
    var lock: ?usize = null;
    var i: usize = rs.len;
    while (i > 0) {
        i -= 1;
        if (tickTime(i, sr) <= start_s) break;
        if (rs[i].freq > 0 and @abs(sig.cents(rs[i].freq, want)) <= 5) lock = i else break;
    }
    return if (lock) |l| (tickTime(l, sr) - start_s) * 1000 else null;
}

fn pct(a: usize, b: usize) f64 {
    return 100 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const filter: []const u8 = if (args.len > 1) args[1] else "";

    const all = [_]Candidate{
        try jsfxCandidate(allocator),
        try analyserCandidate(pitch.Analyser, "analyser", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .lowpass_hz = null, .max_analysis_rate = 96000 }), "no-lowpass", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .lowpass_hz = 1000 }), "lowpass-1k", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .max_analysis_rate = 24000 }), "rate-24k", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .voicing_threshold = null }), "no-voicing", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .refinement = null }), "yin-only", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .octave_hold = 0 }), "no-octave-hold", allocator),
        try analyserCandidateWith(pitch.AnalyserWith(.{ .floor_margin_db = null, .onset_gate = false, .release_drop_db = null }), .{ .silence_db = -60 }, "fixed-gate", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .mains_rule = true }), "mains-rule", allocator),
    };
    var cands: [max_candidates]Candidate = undefined;
    var nc: usize = 0;
    for (all) |c| {
        if (std.mem.indexOf(u8, c.name, filter) == null) continue;
        cands[nc] = c;
        nc += 1;
    }
    const results = try allocator.alloc(Results, nc);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};

    const buf = try allocator.alloc(f32, 96000 * 2);
    defer allocator.free(buf);
    const other = try allocator.alloc(f32, 96000 * 2);
    defer allocator.free(other);

    try w.print("tuner pitch-analyser bench ({s}, {s})\n", .{ @tagName(builtin.mode), @tagName(builtin.cpu.arch) });
    try w.flush();

    // Steady tones.
    for (families) |fam| {
        for (rates) |sr| {
            const s = buf[0..@intFromFloat(1.6 * sr)];
            for (pitchesOf(fam), 0..) |f0, pi| {
                makeSteady(s, fam, sr, f0, 1000 + pi);
                var label_buf: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "{d:.1} Hz @{d}k", .{ f0, sr / 1000 }) catch "?";
                const is_pluck = fam == .pluck or fam == .bass_pluck;
                const first: usize = if (is_pluck) 6 else 9;
                for (cands[0..nc], results) |c, *r| {
                    const rs = run(c, sr, s);
                    const last = if (is_pluck) @min(rs.len, 36) else rs.len;
                    r.family[@intFromEnum(fam)].add(rs[first..last], truth(fam, f0), label);
                }
            }
        }
    }

    // False notes.
    for (rates) |sr| {
        const s = buf[0..@intFromFloat(sr)];
        for (noise_kinds, 0..) |_, kind| {
            @memset(s, 0);
            switch (kind) {
                0 => {},
                1 => sig.addNoise(s, std.math.pow(f64, 10, -80.0 / 20.0), 5),
                2 => sig.addNoise(s, std.math.pow(f64, 10, -55.0 / 20.0), 6),
                3 => sig.addNoise(s, std.math.pow(f64, 10, -40.0 / 20.0), 7),
                4 => sig.addNoise(s, std.math.pow(f64, 10, -20.0 / 20.0), 8),
                5 => {
                    // White noise through a one-pole low-pass near 140 Hz: rumble.
                    sig.addNoise(s, 0.1, 9);
                    var lp: f32 = 0;
                    for (s) |*v| {
                        lp = 0.98 * lp + 0.02 * v.*;
                        v.* = lp;
                    }
                    sig.scale(s, std.math.pow(f64, 10, -30.0 / 20.0) / sig.rms(s));
                },
                else => unreachable,
            }
            for (cands[0..nc], results) |c, *r| {
                for (run(c, sr, s)[5..]) |rd| {
                    r.false_n[kind] += 1;
                    if (rd.freq > 0) r.false_hits[kind] += 1;
                }
            }
        }
    }

    // Onset after silence.
    for (rates) |sr| {
        for ([_]f64{ 82.4069, 110.0, 196.0, 329.628, 659.255, 1318.51, 41.2034, 30.8677 }, 0..) |f0, pi| {
            const onset: usize = @intFromFloat(0.3 * sr);
            const s = buf[0 .. onset + @as(usize, @intFromFloat(sr))];
            @memset(s[0..onset], 0);
            const opts: sig.PluckOptions = if (f0 < 60) .{ .t60_s = 5, .excitation_lowpass = 0.9, .seed = 300 + pi } else .{ .t60_s = 3, .seed = 300 + pi };
            sig.pluck(s[onset..], sr, f0, opts);
            for (cands[0..nc], results) |c, *r| r.onset.add(lockTime(run(c, sr, s), sr, 0.3, f0));
        }
    }

    // Note change: the old note drops to -12 dB as the new one is plucked.
    for (rates) |sr| {
        for ([_][2]f64{ .{ 110.0, 146.832 }, .{ 82.4069, 61.7354 }, .{ 329.628, 246.942 }, .{ 55.0, 41.2034 } }, 0..) |pair, pi| {
            const change: usize = @intFromFloat(0.5 * sr);
            const s = buf[0 .. change + @as(usize, @intFromFloat(sr))];
            sig.pluck(s, sr, pair[0], .{ .t60_s = 3, .seed = 500 + pi });
            for (s[change..]) |*v| v.* *= 0.25;
            const next = other[0 .. s.len - change];
            sig.pluck(next, sr, pair[1], .{ .t60_s = 3, .seed = 600 + pi, .excitation_lowpass = if (pair[1] < 60) 0.9 else 0 });
            sig.mix(s[change..], next);
            for (cands[0..nc], results) |c, *r| r.change.add(lockTime(run(c, sr, s), sr, 0.5, pair[1]));
        }
    }

    // Vibrato, +-20 cents at 5.5 Hz.
    for (rates) |sr| {
        for ([_]f64{ 220.0, 82.4069 }) |f0| {
            const s = buf[0..@intFromFloat(2 * sr)];
            sig.vibrato(s, sr, f0, 20, 5.5, 0.5);
            for (cands[0..nc], results) |c, *r| {
                const rs = run(c, sr, s);
                const half_window = c.window_seconds(sr) / 2;
                for (rs[10..], 10..) |rd, i| {
                    const centre: usize = @intFromFloat((tickTime(i, sr) - half_window) * sr);
                    const want = sig.vibratoFrequency(centre, sr, f0, 20, 5.5);
                    if (rd.freq <= 0 or @abs(sig.cents(rd.freq, want)) > 50) {
                        r.vibrato_wrong += 1;
                        continue;
                    }
                    const e = sig.cents(rd.freq, want);
                    r.vibrato_sq += e * e;
                    r.vibrato_n += 1;
                }
            }
        }
    }

    // Two notes at once.
    for (chords, 0..) |pair, ci| {
        for (rates) |sr| {
            const s = buf[0..@intFromFloat(1.5 * sr)];
            sig.pluck(s, sr, pair[0], .{ .t60_s = 3, .seed = 71 });
            const second = other[0..s.len];
            sig.pluck(second, sr, pair[1], .{ .t60_s = 3, .seed = 72 });
            sig.mix(s, second);
            for (cands[0..nc], results) |c, *r| {
                for (run(c, sr, s)[6..]) |rd| {
                    const t = &r.two[ci];
                    if (rd.freq <= 0) {
                        t[3] += 1;
                    } else if (@abs(sig.cents(rd.freq, pair[0])) < 50) {
                        t[0] += 1;
                    } else if (@abs(sig.cents(rd.freq, pair[1])) < 50) {
                        t[1] += 1;
                    } else {
                        t[2] += 1;
                        r.two_other_hz[ci] = rd.freq;
                    }
                }
            }
        }
    }

    // CPU: a sustained E2 pluck.
    for (rates, 0..) |sr, ri| {
        const s = buf[0..@intFromFloat(2 * sr)];
        sig.pluck(s, sr, 82.4069, .{ .t60_s = 20 });
        for (cands[0..nc], results) |c, *r| {
            c.reset(sr);
            var timer = try std.time.Timer.start();
            var pos: usize = 0;
            while (pos < s.len) : (pos += 256) c.push(s[pos..@min(s.len, pos + 256)]);
            const push_ns: f64 = @floatFromInt(timer.read());
            var times: [300]u64 = undefined;
            for (&times) |*t| {
                timer.reset();
                std.mem.doNotOptimizeAway(c.read());
                t.* = timer.read();
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            r.cpu[ri] = .{ .push_ns_per_s = push_ns / 2, .analyse_ns = @floatFromInt(times[times.len / 2]) };
        }
    }

    try printSummary(w, cands[0..nc], results);
    for (cands[0..nc], results) |c, *r| try printDetail(w, c, r);
    try w.flush();
}

fn note(name: []const u8) []const u8 {
    for (candidate_notes) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    return "";
}

fn coreShare(cpu: Cpu, reads_per_s: f64) f64 {
    return (cpu.push_ns_per_s + reads_per_s * cpu.analyse_ns) / 1e9 * 100;
}

fn printSummary(w: anytype, cands: []const Candidate, results: []const Results) !void {
    try w.print("\n## Summary\n\n", .{});
    for (cands) |c| try w.print("- {s}: {s}\n", .{ c.name, note(c.name) });
    try w.print(
        \\
        \\Clean = sine, sawtooth, square, weak and missing fundamental, plucks,
        \\detuned, DC offset. Target: mean within 1 cent, jitter under 0.5, no
        \\wrong readings. CPU: one core's share read at 30 Hz (the JSFX analyses
        \\every 512 samples whether read or not).
        \\
        \\| candidate | clean tones meeting target | worst clean mean (c) | worst clean jitter (c) | octave errors, all steady | 20 / 10 / 0 dB SNR meeting target | stiff string bias bright / mellow (c) | false notes on noise | lock after onset avg / worst (ms) | lock on note change avg / worst (ms) | vibrato RMS (c) | analyse() 48k / 96k (us) | core at 30 Hz 48k / 96k |
        \\|---|---|---|---|---|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for (cands, results) |c, r| {
        var clean: ToneStats = .{};
        for (clean_families) |f| clean.merge(r.family[@intFromEnum(f)]);
        var steady: ToneStats = .{};
        for (r.family) |f| steady.merge(f);
        const snr20 = r.family[@intFromEnum(Family.snr_20db)];
        const snr10 = r.family[@intFromEnum(Family.snr_10db)];
        const snr0 = r.family[@intFromEnum(Family.snr_0db)];
        const bright = r.family[@intFromEnum(Family.stiff_bright)];
        const mellow = r.family[@intFromEnum(Family.stiff_mellow)];
        var noise_hits: usize = 0;
        var noise_n: usize = 0;
        for (1..noise_kinds.len) |k| {
            noise_hits += r.false_hits[k];
            noise_n += r.false_n[k];
        }
        try w.print("| {s} | {d}/{d} | {d:.3} | {d:.3} | {d:.1}% | {d}/{d}/{d} of {d} | {d:.2} / {d:.2} | {d:.0}% | {d:.0} / {d:.0} | {d:.0} / {d:.0} | {d:.2} | {d:.0} / {d:.0} | {d:.2}% / {d:.2}% |\n", .{
            c.name,                     clean.meets,                                                            clean.tones,
            clean.worst_abs_mean,       clean.worst_jitter,                                                     pct(steady.octave, steady.readings),
            snr20.meets,                snr10.meets,                                                            snr0.meets,
            snr0.tones,                 bright.sum_abs_mean / @as(f64, @floatFromInt(@max(bright.on_note, 1))), mellow.sum_abs_mean / @as(f64, @floatFromInt(@max(mellow.on_note, 1))),
            pct(noise_hits, noise_n),   r.onset.avg(),                                                          r.onset.worst_ms,
            r.change.avg(),             r.change.worst_ms,                                                      @sqrt(r.vibrato_sq / @as(f64, @floatFromInt(@max(r.vibrato_n, 1)))),
            r.cpu[1].analyse_ns / 1000, r.cpu[3].analyse_ns / 1000,                                             coreShare(r.cpu[1], 30),
            coreShare(r.cpu[3], 30),
        });
    }
}

fn printDetail(w: anytype, c: Candidate, r: *const Results) !void {
    try w.print("\n## {s}: {s}\n\n", .{ c.name, note(c.name) });
    try w.print("| family | tones | meet target | on the note | mean |err| (c) | worst (c) | mean jitter (c) | worst jitter (c) | wrong | octave | none |\n|---|---|---|---|---|---|---|---|---|---|---|\n", .{});
    for (families) |fam| {
        const s = r.family[@intFromEnum(fam)];
        const on: f64 = @floatFromInt(@max(s.on_note, 1));
        try w.print("| {s} | {d} | {d} | {d} | {d:.3} | {d:.3} {s} | {d:.3} | {d:.3} | {d:.1}% | {d:.1}% | {d:.1}% |\n", .{
            @tagName(fam),       s.tones,                  s.meets,                                s.on_note,
            s.sum_abs_mean / on, s.worst_abs_mean,         s.worst_mean_tone[0..s.worst_mean_len], s.sum_jitter / on,
            s.worst_jitter,      pct(s.wrong, s.readings), pct(s.octave, s.readings),              pct(s.none, s.readings),
        });
    }
    try w.print("\nTones missing the target:\n\n", .{});
    for (families) |fam| {
        const s = r.family[@intFromEnum(fam)];
        if (s.misses_len == 0) continue;
        try w.print("- {s} ({s}): {s}", .{ @tagName(fam), familyNote(fam), s.misses[0..s.misses_len] });
        if (s.misses_more > 0) try w.print("and {d} more", .{s.misses_more});
        try w.print("\n", .{});
    }
    try w.print("\nFalse notes:", .{});
    for (noise_kinds, 0..) |name, k| try w.print(" {s} {d:.0}%;", .{ name, pct(r.false_hits[k], r.false_n[k]) });
    try w.print("\nLock after onset: avg {d:.0} ms, worst {d:.0} ms, never {d} of {d}. On a note change: avg {d:.0} ms, worst {d:.0} ms, never {d} of {d}.\n", .{
        r.onset.avg(), r.onset.worst_ms, r.onset.never, r.onset.n, r.change.avg(), r.change.worst_ms, r.change.never, r.change.n,
    });
    try w.print("Vibrato +-20 c at 5.5 Hz: RMS {d:.2} c, {d} wrong.\n", .{ @sqrt(r.vibrato_sq / @as(f64, @floatFromInt(@max(r.vibrato_n, 1)))), r.vibrato_wrong });
    try w.print("Two notes at once (readings on the lower / upper / something else / none):", .{});
    for (chords, 0..) |pair, ci| {
        const t = r.two[ci];
        try w.print(" {d:.1}+{d:.1} Hz: {d}/{d}/{d}/{d}", .{ pair[0], pair[1], t[0], t[1], t[2], t[3] });
        if (t[2] > 0) try w.print(" (e.g. {d:.1} Hz)", .{r.two_other_hz[ci]});
        try w.print(";", .{});
    }
    try w.print("\nCPU:", .{});
    for (rates, r.cpu) |sr, cpu| try w.print(" {d}k: push {d:.0} us per second of input, analyse() {d:.1} us, {d:.3}% of a core at 30 Hz;", .{ sr / 1000, cpu.push_ns_per_s / 1000, cpu.analyse_ns / 1000, coreShare(cpu, 30) });
    try w.print("\n", .{});
}
