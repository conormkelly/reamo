//! A recorded take, read as the tuner would read it and judged against
//! each note's ground truth (wav_tool.zig is its command line).
//!
//! `readTake` runs the analyser over the take: input pushed in 256-sample
//! blocks, a reading every sample_rate / 30 samples, each with the
//! analyser's last onset. `judgeNotes` splits the readings into notes at
//! onsets (so re-plucking a string makes a new note), and for each note
//! long enough measures its truth independently of the readings:
//!
//! - hum learned from up to 0.5 s before the onset (both halves of it must
//!   agree, as the analyser requires) is taken out of the note;
//! - the fundamental's rough frequency is the one whose harmonic series
//!   explains the spectrum of the sustain from 0.3 s to 1.3 s (several.zig);
//! - the first partial is then tracked over the whole sustain and settled
//!   (truth.zig): the glide's nu_inf, or for a drifting note its last half
//!   second's mean.
//!
//! Each note's readings are scored against it: the error against the
//! tracked first partial at each reading's time and against the settled
//! truth from 1 s on, time to within 1 cent, first stable flag, lock-on
//! and octave readings.
const std = @import("std");
const pitch = @import("pitch.zig");
const truth = @import("truth.zig");
const hum = @import("hum.zig");
const several = @import("several.zig");
const first_partial = @import("first_partial.zig");
const fft_mod = @import("fft.zig");

/// The longest period measured: 25 Hz at 384 kHz.
pub const max_period = 16384;
const max_fft = 1 << 17;
/// A note is judged when it lasts this long.
pub const min_note_s = 1.2;

pub const Read = struct {
    /// Seconds into the take.
    t: f64,
    r: pitch.Reading,
    /// Input sample of the analyser's last onset.
    onset: ?u64,
};

/// The take's readings into `out`.
pub fn readTake(a: *pitch.Analyser, mono: []const f32, rate: f64, settings: pitch.Settings, out: []Read) ![]Read {
    try a.init(rate);
    const tick: usize = @intFromFloat(@round(rate / 30));
    var n: usize = 0;
    var pos: usize = 0;
    var next_tick = tick;
    while (pos < mono.len and n < out.len) {
        const end = @min(mono.len, pos + 256, next_tick);
        a.push(mono[pos..end]);
        pos = end;
        if (pos == next_tick) {
            out[n] = .{ .t = @as(f64, @floatFromInt(pos)) / rate, .r = a.analyse(settings), .onset = a.lastOnset() };
            n += 1;
            next_tick += tick;
        }
    }
    return out[0..n];
}

pub const Note = struct {
    onset_s: f64,
    end_s: f64,
    truth: truth.Truth,
    truth_note: i32,
    /// Cents of the truth from its note.
    truth_cents: f64,
    hum_removed: bool,
    p95_err_cents: f64,
    mean_err_cents: f64,
    jitter_cents: f64,
    p95_err_vs_settled_cents: f64,
    to_within_1c_s: ?f64,
    first_stable_s: ?f64,
    lock_s: ?f64,
    octave_reads: usize,
    reads_after_1s: usize,
};

/// Scratch for `judgeNotes`; big, so the caller allocates it.
pub const Work = struct {
    first_partial: first_partial.Work(max_period),
    fft: fft_mod.Fft(max_fft),
    fft_work: [max_fft / 2]fft_mod.Complex,
    windowed: [max_fft]f64,
    power: [max_fft / 2 + 1]f64,
    hum_window: [max_fft]f64,
    several: several.Scratch,
    points: [8192]truth.Point,
    errors: [8192]f64,
    settled: [8192]f64,

    pub fn init(self: *Work) void {
        self.fft.init();
    }
};

/// The notes of at least `min_note_s` in `reads` of `mono` (the take at
/// `rate`), judged, owned by the caller; `alloc` also holds a copy of each
/// note while it is judged.
pub fn judgeNotes(alloc: std.mem.Allocator, work: *Work, reads: []const Read, mono: []const f64, rate: f64, settings: pitch.Settings) ![]Note {
    var notes: std.ArrayList(Note) = .empty;
    var k: usize = 0;
    while (k < reads.len) {
        const onset = reads[k].onset orelse {
            k += 1;
            continue;
        };
        // The readings since this onset, up to the next.
        var end = k;
        while (end + 1 < reads.len and reads[end + 1].onset == onset) end += 1;
        defer k = end + 1;
        var last_shown: ?usize = null;
        for (k..end + 1) |i| {
            if (reads[i].r.freq_hz > 0) last_shown = i;
        }
        const last = last_shown orelse continue;
        const onset_s = @as(f64, @floatFromInt(onset)) / rate;
        const end_s = reads[last].t;
        if (end_s - onset_s < min_note_s) continue;
        const note = try judge(alloc, work, reads[k .. last + 1], mono, rate, onset, end_s, settings) orelse continue;
        try notes.append(alloc, note);
    }
    return notes.toOwnedSlice(alloc);
}

fn judge(alloc: std.mem.Allocator, work: *Work, reads: []const Read, mono: []const f64, rate: f64, onset: u64, end_s: f64, settings: pitch.Settings) !?Note {
    const start: usize = @intCast(onset);
    const stop: usize = @min(mono.len, @as(usize, @intFromFloat(end_s * rate)));
    const x = try alloc.dupe(f64, mono[start..stop]);
    defer alloc.free(x);
    const onset_s = @as(f64, @floatFromInt(onset)) / rate;

    // Hum learned before the onset, its two halves agreeing.
    const pre_len: usize = @min(start, @as(usize, @intFromFloat(0.5 * rate)));
    var hum_removed = false;
    if (@as(f64, @floatFromInt(pre_len)) >= 0.3 * rate) {
        const pre = mono[start - pre_len .. start];
        const half = pre_len / 2;
        const a = learnHum(work, pre[0..half], start - pre_len, rate);
        const b = learnHum(work, pre[half..], start - pre_len + half, rate);
        if (a != null and b != null and a.?.agrees(b.?)) {
            if (learnHum(work, pre, start - pre_len, rate)) |m| {
                m.subtract(x, start, rate, 0, 2000);
                hum_removed = true;
            }
        }
    }

    // The fundamental's rough frequency from the sustain's spectrum.
    const from: usize = @min(x.len, @as(usize, @intFromFloat(0.3 * rate)));
    const to: usize = @min(x.len, from + @as(usize, @intFromFloat(rate)));
    const len = @min(to - from, max_fft);
    const n_fft = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
    @memset(work.windowed[0..n_fft], 0);
    for (work.windowed[0..len], x[from .. from + len], 0..) |*d, v, i| d.* = v * several.blackmanHarris(i, len);
    work.fft.powerSpectrum(work.windowed[0..n_fft], n_fft, &work.fft_work, work.power[0 .. n_fft / 2 + 1]);
    const sp: several.Spectrum = .{ .power = work.power[0 .. n_fft / 2 + 1], .bin_hz = rate / @as(f64, @floatFromInt(n_fft)), .length_s = @as(f64, @floatFromInt(len)) / rate };
    const coarse = several.judge(sp, 25, 2000, 2000, &work.several).fundamental_hz orelse return null;

    const points = truth.track(max_period, &work.first_partial, x, rate, coarse, 0.1, end_s - onset_s, 0.2, 0.05, &work.points);
    const t = truth.settle(points) orelse return null;
    const truth_midi = 69 + 12 * @log2(t.hz / settings.reference_hz);
    const truth_note: i32 = @intFromFloat(@floor(truth_midi + 0.5));

    var m: usize = 0;
    var ms: usize = 0;
    var sum: f64 = 0;
    var sum2: f64 = 0;
    var octave: usize = 0;
    var within: ?f64 = null;
    var stable: ?f64 = null;
    var lock: ?f64 = null;
    for (reads) |rd| {
        const since = rd.t - onset_s;
        const shown = rd.r.freq_hz > 0;
        if (shown) {
            const d = @abs(rd.r.note - truth_note);
            if ((d >= 11 and d <= 13) or (d >= 23 and d <= 25) or (d >= 35 and d <= 37)) octave += 1;
            if (stable == null and rd.r.stable) stable = since;
        }
        if (shown and rd.r.note == truth_note) {
            if (lock == null) lock = since;
        } else lock = null;
        if (shown and !rd.r.settling and @abs(cents(rd.r.freq_hz, t.hz)) <= 1) {
            if (within == null) within = since;
        } else within = null;
        if (since < 1 or !shown or rd.r.settling) continue;
        const f1 = trackedAt(points, since) orelse continue;
        const e = cents(rd.r.freq_hz, f1);
        if (m < work.errors.len) {
            work.errors[m] = @abs(e);
            m += 1;
        }
        if (ms < work.settled.len) {
            work.settled[ms] = @abs(cents(rd.r.freq_hz, t.hz));
            ms += 1;
        }
        sum += e;
        sum2 += e * e;
    }
    const mf: f64 = @floatFromInt(@max(m, 1));
    const mean = sum / mf;
    return .{
        .onset_s = onset_s,
        .end_s = end_s,
        .truth = t,
        .truth_note = truth_note,
        .truth_cents = 100 * (truth_midi - @as(f64, @floatFromInt(truth_note))),
        .hum_removed = hum_removed,
        .p95_err_cents = percentile(work.errors[0..m]),
        .mean_err_cents = mean,
        .jitter_cents = @sqrt(@max(0, sum2 / mf - mean * mean)),
        .p95_err_vs_settled_cents = percentile(work.settled[0..ms]),
        .to_within_1c_s = within,
        .first_stable_s = stable,
        .lock_s = lock,
        .octave_reads = octave,
        .reads_after_1s = m,
    };
}

/// hum.learn on `x` (input samples `start` on), its Hann power spectrum
/// computed here.
fn learnHum(work: *Work, x: []const f64, start: u64, rate: f64) ?hum.Model {
    const n = @min(x.len, max_fft);
    const seg = x[x.len - n ..];
    const n_fft = std.math.ceilPowerOfTwo(usize, n) catch unreachable;
    const denom: f64 = @floatFromInt(@max(n, 2) - 1);
    @memset(work.windowed[0..n_fft], 0);
    for (work.windowed[0..n], seg, 0..) |*d, v, i| d.* = v * (0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / denom));
    work.fft.powerSpectrum(work.windowed[0..n_fft], n_fft, &work.fft_work, work.power[0 .. n_fft / 2 + 1]);
    const sp: hum.Spectrum = .{ .power = work.power[0 .. n_fft / 2 + 1], .bin_hz = rate / @as(f64, @floatFromInt(n_fft)) };
    return hum.learn(max_period, &work.first_partial, seg, start + (x.len - n), rate, sp, work.hum_window[0..n]);
}

/// The tracked first partial at `t` seconds after the onset, interpolated
/// between measurements.
fn trackedAt(points: []const truth.Point, t: f64) ?f64 {
    if (points.len == 0 or t < points[0].t or t > points[points.len - 1].t + 0.05) return null;
    for (points[1..], 1..) |p, i| {
        if (p.t >= t) {
            const q = points[i - 1];
            return q.hz + (p.hz - q.hz) * (t - q.t) / (p.t - q.t);
        }
    }
    return points[points.len - 1].hz;
}

fn cents(hz: f64, ref: f64) f64 {
    return 1200 * @log2(hz / ref);
}

fn percentile(values: []f64) f64 {
    if (values.len == 0) return std.math.inf(f64);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const idx: usize = @intFromFloat(@ceil(0.95 * @as(f64, @floatFromInt(values.len))) - 1);
    return values[@min(idx, values.len - 1)];
}

// =============================================================================
// Tests

const testing = std.testing;
const sig = @import("signals.zig");

const Fixture = struct {
    analyser: pitch.Analyser,
    work: Work,
    reads: [1024]Read,
};

fn judgeTake(fx: *Fixture, mono: []const f32, rate: f64) ![]Note {
    const x = try testing.allocator.alloc(f64, mono.len);
    defer testing.allocator.free(x);
    for (x, mono) |*d, v| d.* = v;
    const reads = try readTake(&fx.analyser, mono, rate, .{}, &fx.reads);
    return judgeNotes(testing.allocator, &fx.work, reads, x, rate, .{});
}

fn fixture() !*Fixture {
    const fx = try testing.allocator.create(Fixture);
    fx.work.init();
    return fx;
}

test "the truth of a string with hum 1.8 Hz from its fundamental is its first partial, not the hum's" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    const rate = 48000.0;
    const buf = try testing.allocator.alloc(f32, 48000 * 4);
    defer testing.allocator.free(buf);
    const other = try testing.allocator.alloc(f32, 48000 * 4);
    defer testing.allocator.free(other);
    // 1 s of 60 Hz hum, then fretted bass B1 30 dB over it.
    const opts: sig.StringOptions = .{ .f0 = 61.7354, .inharmonicity = 1e-3, .t60_s = 8 };
    @memset(buf, 0);
    sig.pluckedString(buf[48000..], rate, opts);
    const note_db = 20 * std.math.log10(sig.rms(buf[48000..96000]));
    sig.mains(other, rate, 60, .hum, note_db - 30);
    sig.mix(buf, other);
    sig.addNoise(buf, 3e-5, 1);
    const notes = try judgeTake(fx, buf, rate);
    defer testing.allocator.free(notes);
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expect(notes[0].hum_removed);
    try testing.expectApproxEqAbs(@as(f64, 0), cents(notes[0].truth.hz, opts.settledFirstPartialHz()), 0.05);
}

test "re-plucking a string makes a second note with its own truth" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    const rate = 48000.0;
    const buf = try testing.allocator.alloc(f32, 48000 * 5);
    defer testing.allocator.free(buf);
    const first: sig.StringOptions = .{ .f0 = 82.4069 * std.math.pow(f64, 2, 0.1 / 1200.0), .inharmonicity = 1.1e-4 };
    const second: sig.StringOptions = .{ .f0 = 82.4069 * std.math.pow(f64, 2, -5.0 / 1200.0), .inharmonicity = 1.1e-4, .seed = 4 };
    @memset(buf, 0);
    sig.pluckedString(buf[24000..120000], rate, first);
    sig.pluckedString(buf[120000..], rate, second);
    sig.addNoise(buf, 3e-5, 2);
    const notes = try judgeTake(fx, buf, rate);
    defer testing.allocator.free(notes);
    try testing.expectEqual(@as(usize, 2), notes.len);
    try testing.expectApproxEqAbs(@as(f64, 0), cents(notes[0].truth.hz, first.settledFirstPartialHz()), 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0), cents(notes[1].truth.hz, second.settledFirstPartialHz()), 0.05);
}

test "an octave error by the analyser shows against the truth" {
    // The Karplus-Strong 880 Hz pluck whose fundamental starts 20 dB under
    // its octave: the analyser reads A6 for a while, the truth is A5.
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    const rate = 48000.0;
    const buf = try testing.allocator.alloc(f32, 48000 * 3);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    sig.pluck(buf[14400..], rate, 880, .{ .amp = 0.9, .t60_s = 3, .seed = 1014 });
    sig.addNoise(buf, 3e-5, 3);
    const notes = try judgeTake(fx, buf, rate);
    defer testing.allocator.free(notes);
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqual(@as(i32, 81), notes[0].truth_note);
    try testing.expect(notes[0].octave_reads > 0);
}
