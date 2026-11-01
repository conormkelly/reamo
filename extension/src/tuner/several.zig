//! Tells one string from several sounding at once, from the spectrum.
//!
//! Two notes together repeat at their common subharmonic (E2 and B2 at
//! 41.2 Hz, an octave under E2), and a period detector reads that: a
//! confident wrong note under both. Their spectrum gives them away. One
//! string's partials are multiples of one fundamental, and every harmonic
//! from the 2nd to the 6th is there (its fundamental may be weak, or for a
//! synthetic tone missing). Two notes' partials are multiples only of the
//! subharmonic, with holes in its series: E2 and B2 fill 41.2 Hz's 2nd,
//! 3rd, 4th and 6th harmonics, but nothing fills its 5th or 7th.
//!
//! So the strong peaks (within `strong_db` of the strongest) are tested
//! against three candidate fundamentals: the lowest strong peak, and a
//! half and a third of it. A candidate explains the input if every strong
//! peak up to 6.5 times the lowest is near one of its multiples, allowing
//! for a stiff string's stretch, and its harmonics from the 2nd to the
//! 6th are all present (a local maximum within `present_db` of the
//! strongest) up to the highest of those peaks. None explaining it means
//! several notes.
//!
//! The spectrum should be Blackman-Harris windowed: Hann's leakage from
//! two strong neighbours puts power in the holes. Pure and allocation-free.
const std = @import("std");

pub const Spectrum = struct {
    /// Power per bin, bin 0 at 0 Hz.
    power: []const f64,
    bin_hz: f64,
    /// Length of the windowed input, seconds.
    length_s: f64,
};

/// A strong peak is within this many dB of the strongest.
const strong_db = 20.0;
/// A harmonic is present if a local maximum near it is within this many
/// dB of the strongest peak and 10 dB over the noise floor.
const present_db = 50.0;
const over_floor = 10.0;
/// Peaks are matched to harmonics within 30 cents plus a stiff string's
/// stretch at this inharmonicity (fretted bass is about 1e-3), and never
/// more than a quarter of the spacing.
const max_inharmonicity = 1.5e-3;
/// The 4-term Blackman-Harris main lobe is 4 bins of 1 / length_s either
/// side; two partials are told apart only this many half-widths apart.
const resolution = 2.0;

pub const max_peaks = 16;
pub const floor_samples = 512;

pub const Scratch = struct {
    floor: [floor_samples]f64,
    peaks: [max_peaks]f64,
};

pub const Verdict = enum {
    /// The strong peaks are one string's.
    one,
    /// No candidate fundamental explains them: several notes.
    several,
    /// Too short a window to resolve the harmonics, or nothing strong.
    unknown,
};

/// The 4-term Blackman-Harris window's value at sample i of n.
pub fn blackmanHarris(i: usize, n: usize) f64 {
    const x = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
    return 0.35875 - 0.48829 * @cos(x) + 0.14128 * @cos(2 * x) - 0.01168 * @cos(3 * x);
}

pub const Judgement = struct {
    verdict: Verdict,
    /// With `one`, the candidate that explains the peaks: the string's
    /// fundamental, to a fraction of a bin.
    fundamental_hz: ?f64 = null,
    spectrum: Spectrum,
    /// The least power counted as a partial.
    present_min: f64,

    /// Whether a partial (a local maximum within `present_db` of the
    /// strongest peak) lies within a quarter-tone of `hz`: a weak
    /// fundamental does, a subharmonic common to two notes doesn't.
    pub fn heard(self: Judgement, hz: f64) bool {
        return present(self.spectrum, hz, 50, self.present_min);
    }
};

/// Whether the spectrum between `min_hz` and `max_hz` is one string's.
/// `spacing_hz` is the spacing of the partials heard (a period detector's
/// frequency): closer than the main lobe, they merge into peaks whose
/// frequencies mean nothing, and the verdict is unknown.
pub fn judge(sp: Spectrum, min_hz: f64, max_hz: f64, spacing_hz: f64, scratch: *Scratch) Judgement {
    const v = verdictOf(sp, min_hz, max_hz, spacing_hz, scratch);
    return .{ .verdict = v.verdict, .fundamental_hz = v.fundamental_hz, .spectrum = sp, .present_min = v.present_min };
}

const Inner = struct { verdict: Verdict, present_min: f64 = std.math.inf(f64), fundamental_hz: ?f64 = null };

fn verdictOf(sp: Spectrum, min_hz: f64, max_hz: f64, spacing_hz: f64, scratch: *Scratch) Inner {
    if (spacing_hz < resolution * 4 / sp.length_s) return .{ .verdict = .unknown };
    const lo = binAt(sp, min_hz * 0.9);
    const hi = binAt(sp, max_hz);
    if (hi <= lo + 8) return .{ .verdict = .unknown };
    const band = sp.power[lo .. hi + 1];

    var strongest: f64 = 0;
    for (band) |p| strongest = @max(strongest, p);
    const floor = noiseFloor(band, &scratch.floor);
    if (!(strongest > over_floor * floor)) return .{ .verdict = .unknown };
    const strong_min = @max(strongest * dbRatio(-strong_db), over_floor * floor);
    const present_min = @max(strongest * dbRatio(-present_db), over_floor * floor);

    // The strong peaks, lowest first.
    var n: usize = 0;
    var b = lo + 1;
    while (b < hi and n < max_peaks) : (b += 1) {
        const p = sp.power[b];
        if (p >= strong_min and p > sp.power[b - 1] and p >= sp.power[b + 1]) {
            scratch.peaks[n] = peakHz(sp, b);
            n += 1;
        }
    }
    if (n == 0) return .{ .verdict = .unknown };
    const peaks = scratch.peaks[0..n];
    const lowest = peaks[0];
    // Peaks closer than the main lobe merge, and their frequencies mean
    // nothing; a candidate's harmonics must be resolved to check them.
    const half_width = 4 / sp.length_s;
    if (lowest < resolution * half_width) return .{ .verdict = .unknown, .present_min = present_min };
    var unresolved = false;
    for ([_]f64{ 1, 2, 3 }) |d| {
        const c = lowest / d;
        if (c < min_hz * 0.9) break;
        if (!multiples(peaks, c)) continue;
        if (c < resolution * half_width) {
            unresolved = true;
            continue;
        }
        if (complete(sp, peaks, c, present_min)) return .{ .verdict = .one, .present_min = present_min, .fundamental_hz = c };
    }
    return .{ .verdict = if (unresolved) .unknown else .several, .present_min = present_min };
}

fn dbRatio(db: f64) f64 {
    return std.math.pow(f64, 10, db / 10);
}

fn binAt(sp: Spectrum, hz: f64) usize {
    const b: usize = @intFromFloat(@max(0, @round(hz / sp.bin_hz)));
    return @min(b, sp.power.len - 2);
}

/// A peak's frequency from a parabola through the log power of its bin
/// and its neighbours.
fn peakHz(sp: Spectrum, b: usize) f64 {
    const a = @log(@max(sp.power[b - 1], 1e-300));
    const m = @log(@max(sp.power[b], 1e-300));
    const c = @log(@max(sp.power[b + 1], 1e-300));
    const den = a - 2 * m + c;
    const offset = if (den < 0) std.math.clamp(0.5 * (a - c) / den, -0.5, 0.5) else 0;
    return (@as(f64, @floatFromInt(b)) + offset) * sp.bin_hz;
}

/// How far from k c, cents, a partial may be and still be harmonic k.
fn tolerance(k: f64) f64 {
    const stretch = 30 + 866 * max_inharmonicity * (k * k - 1);
    return @min(stretch, 1200 * @log2(1 + 0.25 / k));
}

/// Whether every strong peak up to 6.5 times the lowest is near a multiple
/// of `c`.
fn multiples(peaks: []const f64, c: f64) bool {
    for (peaks) |p| {
        if (p > 6.5 * peaks[0]) break;
        const k = @max(1, @round(p / c));
        if (@abs(1200 * @log2(p / (k * c))) > tolerance(k)) return false;
    }
    return true;
}

/// Whether c's harmonics from the 2nd to the 6th are present, up to the
/// highest strong peak counted: a gap under a strong partial is a hole
/// two notes leave, while a decaying string's series just runs out.
fn complete(sp: Spectrum, peaks: []const f64, c: f64, present_min: f64) bool {
    var top = peaks[0];
    for (peaks) |p| {
        if (p > 6.5 * peaks[0]) break;
        top = p;
    }
    var k: f64 = 2;
    while (k <= 6 and k * c <= top * 1.01) : (k += 1) {
        if (!present(sp, k * c, tolerance(k), present_min)) return false;
    }
    return true;
}

/// Whether a local maximum of at least `min_power` lies within `cents` of
/// `hz`.
fn present(sp: Spectrum, hz: f64, cents: f64, min_power: f64) bool {
    const ratio = std.math.pow(f64, 2, cents / 1200);
    const from = @max(1, binAt(sp, hz / ratio));
    const to = @max(from, binAt(sp, hz * ratio));
    var b = from;
    while (b <= to) : (b += 1) {
        const p = sp.power[b];
        if (p >= min_power and p > sp.power[b - 1] and p >= sp.power[b + 1]) return true;
    }
    return false;
}

fn noiseFloor(power: []const f64, scratch: *[floor_samples]f64) f64 {
    const step = (power.len + floor_samples - 1) / floor_samples;
    var n: usize = 0;
    var i: usize = 0;
    while (i < power.len and n < floor_samples) : (i += step) {
        scratch[n] = power[i];
        n += 1;
    }
    std.mem.sort(f64, scratch[0..n], {}, std.sort.asc(f64));
    return scratch[n / 2];
}

// =============================================================================
// Tests

const testing = std.testing;
const sig = @import("signals.zig");
const fft_mod = @import("fft.zig");

const rate: f64 = 11025;
const seg_len = 3307; // 0.3 s
const fft_n = 4096;

const Fixture = struct {
    fft: fft_mod.Fft(fft_n),
    work: [fft_n / 2]fft_mod.Complex,
    power: [fft_n / 2 + 1]f64,
    x: [seg_len]f64,
    s32: [seg_len]f32,
    other: [seg_len]f32,
    scratch: Scratch,

    fn judgeNow(self: *Fixture, len: usize, spacing_hz: f64) Verdict {
        @memset(&self.x, 0);
        for (self.x[0..len], self.s32[0..len], 0..) |*d, v, i| d.* = v * blackmanHarris(i, len);
        self.fft.powerSpectrum(&self.x, fft_n, &self.work, &self.power);
        const sp: Spectrum = .{ .power = &self.power, .bin_hz = rate / fft_n, .length_s = @as(f64, @floatFromInt(len)) / rate };
        return judge(sp, 25, 2000, spacing_hz, &self.scratch).verdict;
    }

    fn string(self: *Fixture, opts: sig.StringOptions) void {
        sig.pluckedString(&self.s32, rate, opts);
        sig.addNoise(&self.s32, 3e-5, 1);
    }

    fn pair(self: *Fixture, a: f64, b: f64) void {
        sig.pluckedString(&self.s32, rate, .{ .f0 = a, .inharmonicity = 1e-4, .peak = 0.35, .max_hz = 5000 });
        sig.pluckedString(&self.other, rate, .{ .f0 = b, .inharmonicity = 1e-4, .peak = 0.35, .max_hz = 5000, .seed = 2 });
        sig.mix(&self.s32, &self.other);
        sig.addNoise(&self.s32, 3e-5, 1);
    }
};

fn fixture() !*Fixture {
    const fx = try testing.allocator.create(Fixture);
    fx.fft.init();
    return fx;
}

test "one string is never several, bright, mellow or with its fundamental 20 dB down, guitar or fretted bass, from 60 ms of input" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    for ([_][2]f64{ .{ 41.2034, 2e-4 }, .{ 61.7354, 1e-3 }, .{ 82.4069, 1.1e-4 }, .{ 110, 6.5e-5 }, .{ 196, 8.4e-5 }, .{ 329.628, 1.1e-5 }, .{ 659.255, 4.4e-5 } }) |c| {
        for ([_]f64{ 1, 2 }) |rolloff| {
            for ([_]f64{ 1, 0.05 }) |gain| {
                fx.string(.{ .f0 = c[0], .inharmonicity = c[1], .rolloff = rolloff, .fundamental_gain = gain, .max_hz = 5000 });
                // From the 60 ms after an onset to the full 0.3 s.
                for ([_]usize{ 661, 1102, 1654, seg_len }) |len| {
                    const v = fx.judgeNow(len, c[0]);
                    errdefer std.debug.print("{d} Hz rolloff {d} gain {d}, {d} samples: {s}\n", .{ c[0], rolloff, gain, len, @tagName(v) });
                    try testing.expect(v != .several);
                }
            }
        }
    }
}

test "names the fundamental of one string, its fundamental 20 dB down or missing" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    for ([_]f64{ 1, 0.05 }) |gain| {
        fx.string(.{ .f0 = 110, .inharmonicity = 6.5e-5, .fundamental_gain = gain, .max_hz = 5000 });
        for (fx.x[0..seg_len], fx.s32[0..seg_len], 0..) |*d, v, i| d.* = v * blackmanHarris(i, seg_len);
        @memset(fx.x[seg_len..], 0);
        fx.fft.powerSpectrum(&fx.x, fft_n, &fx.work, &fx.power);
        const sp: Spectrum = .{ .power = &fx.power, .bin_hz = rate / fft_n, .length_s = seg_len / rate };
        const j = judge(sp, 25, 2000, 2000, &fx.scratch);
        try testing.expectApproxEqRel(@as(f64, 110), j.fundamental_hz.?, 0.01);
    }
}

test "a tone with its fundamental missing is one" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    sig.harmonics(&fx.s32, rate, 98, &.{ 0, 0.3, 0.25, 0.2, 0.15, 0.1, 0.08, 0.06 });
    try testing.expectEqual(Verdict.one, fx.judgeNow(seg_len, 98));
}

test "a string late in its decay, its partials over the 3rd gone, is one" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    sig.harmonics(&fx.s32, rate, 329.628, &.{ 0.3, 0.15, 0.08 });
    sig.addNoise(&fx.s32, 3e-6, 4);
    try testing.expectEqual(Verdict.one, fx.judgeNow(seg_len, 329.628));
}

test "two strings a fifth, a fourth, a third or a tritone apart are several" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    // Each pair, and the common subharmonic a period detector reads for it.
    for ([_][3]f64{ .{ 82.4069, 123.471, 41.2 }, .{ 110, 146.832, 36.7 }, .{ 195.998, 246.942, 49 }, .{ 82.4069, 116.541, 38.9 }, .{ 55, 82.4069, 27.5 } }) |p| {
        fx.pair(p[0], p[1]);
        errdefer std.debug.print("{d} + {d} Hz\n", .{ p[0], p[1] });
        try testing.expectEqual(Verdict.several, fx.judgeNow(seg_len, p[2]));
    }
}

test "two strings an octave apart are one, the lower" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    fx.pair(82.4069, 164.814);
    try testing.expectEqual(Verdict.one, fx.judgeNow(seg_len, 82.4069));
}

test "noise alone is unknown" {
    const fx = try fixture();
    defer testing.allocator.destroy(fx);
    @memset(&fx.s32, 0);
    sig.addNoise(&fx.s32, 0.01, 3);
    try testing.expect(fx.judgeNow(seg_len, 150) != .several);
}
