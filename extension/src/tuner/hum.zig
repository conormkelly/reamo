//! Learns stationary mains hum while no note sounds, so it can be taken
//! out of a note's input.
//!
//! Hum a few hertz from a note's first partial passes the first-partial
//! refinement's band (first_partial.zig) and ripples the partial's phase:
//! 60 Hz hum 40 dB under fretted bass B1 (1.8 Hz away) moves its reading by
//! several cents. No fixed notch can take it out without taking out real
//! notes on the same frequencies. But hum is a fixed fact of the rig: the
//! mains frequency, and each harmonic's amplitude and phase, hold while a
//! note is played, so a model learned before the onset can be extrapolated
//! through the note and subtracted.
//!
//! `learn` fits the model to idle input: the base (50 or 60 Hz) whose
//! harmonics hold more power; the harmonics standing 12 dB over the noise
//! (the median amplitude half-way between harmonics); the exact mains
//! frequency from their phase slopes; then each one's amplitude and phase
//! by a Hann-weighted projection. `subtract` takes the components near a frequency
//! out of a stretch of input, extrapolating their phase. Pure and
//! allocation-free.
const std = @import("std");
const first_partial = @import("first_partial.zig");

pub const max_components = 40;
/// Harmonics are fitted up to this frequency.
const top_hz = 2000.0;
/// A component is kept when its amplitude is this many times the median
/// amplitude half-way between harmonics (12 dB).
const over_noise = 4.0;

pub const Model = struct {
    base_hz: f64 = 0,
    count: usize = 0,
    /// Harmonic number, amplitude and phase of each component kept; the
    /// phase is at input sample `ref`.
    harmonic: [max_components]u16 = undefined,
    amp: [max_components]f64 = undefined,
    phase: [max_components]f64 = undefined,
    ref: u64 = 0,

    /// The strongest component's amplitude.
    pub fn strongest(self: Model) f64 {
        var a: f64 = 0;
        for (self.amp[0..self.count]) |v| a = @max(a, v);
        return a;
    }

    /// Whether `other` is the same hum: the same base within 0.05 Hz and
    /// the same strongest amplitude within 1.5 dB.
    pub fn agrees(self: Model, other: Model) bool {
        if (self.count == 0 or other.count == 0) return false;
        if (@abs(self.base_hz - other.base_hz) > 0.05) return false;
        return @abs(20 * std.math.log10(self.strongest() / other.strongest())) <= 1.5;
    }

    /// Takes out of `x` (input samples `start` on, at `rate`) the components
    /// between `low_hz` and `high_hz`.
    pub fn subtract(self: Model, x: []f64, start: u64, rate: f64, low_hz: f64, high_hz: f64) void {
        const offset: f64 = @as(f64, @floatFromInt(start)) - @as(f64, @floatFromInt(self.ref));
        for (0..self.count) |c| {
            const hz = self.base_hz * @as(f64, @floatFromInt(self.harmonic[c]));
            if (hz < low_hz or hz > high_hz) continue;
            const w = 2 * std.math.pi * hz / rate;
            const p0 = self.phase[c] + w * offset;
            // cos(w n + p0) by rotation, renormalised now and then.
            var re = @cos(p0);
            var im = @sin(p0);
            const cr = @cos(w);
            const ci = @sin(w);
            const a = self.amp[c];
            for (x, 0..) |*v, i| {
                v.* -= a * re;
                const nre = re * cr - im * ci;
                im = re * ci + im * cr;
                re = nre;
                if (i % 1024 == 1023) {
                    const r = @sqrt(re * re + im * im);
                    re /= r;
                    im /= r;
                }
            }
        }
    }
};

/// The hum in `x` (input samples `start` on, at `rate`), or null if no
/// harmonic of 50 or 60 Hz stands 12 dB over the noise.
pub fn learn(comptime max_period: usize, work: *first_partial.Work(max_period), x: []const f64, start: u64, rate: f64) ?Model {
    if (x.len < 64) return null;
    const top = @min(top_hz, 0.45 * rate);
    // Which base, by the power at its nominal harmonics.
    var best_base: f64 = 0;
    var best_power: f64 = 0;
    for ([_]f64{ 50, 60 }) |base| {
        var power: f64 = 0;
        var k: f64 = 1;
        while (k * base <= top) : (k += 1) power += amplitude(x, rate, k * base).amp;
        if (power > best_power) {
            best_power = power;
            best_base = base;
        }
    }
    if (best_base == 0) return null;
    // The noise: the median amplitude half-way between harmonics.
    var gaps: [max_components]f64 = undefined;
    var ng: usize = 0;
    var k: f64 = 1;
    while ((k + 0.5) * best_base <= top and ng < gaps.len) : (k += 1) {
        gaps[ng] = amplitude(x, rate, (k + 0.5) * best_base).amp;
        ng += 1;
    }
    if (ng < 3) return null;
    std.mem.sort(f64, gaps[0..ng], {}, std.sort.asc(f64));
    const noise = gaps[ng / 2];

    // The harmonics standing over the noise, each measured by its phase
    // slope; the mains frequency is their inverse-variance mean of f_k / k
    // (precision grows with k, and phase is extrapolated by k f t).
    var model: Model = .{ .base_hz = best_base, .ref = start };
    var sum_w: f64 = 0;
    var sum_wf: f64 = 0;
    k = 1;
    while (k * best_base <= top and model.count < max_components) : (k += 1) {
        const c = amplitude(x, rate, k * best_base);
        if (!(c.amp > over_noise * noise)) continue;
        model.harmonic[model.count] = @intFromFloat(k);
        model.count += 1;
        const e = first_partial.estimate(max_period, work, x, rate, k * best_base, .phase_slope) orelse continue;
        if (!std.math.isFinite(e.std_error_hz) or !(@abs(e.hz / k - best_base) < 1)) continue;
        const se = @max(e.std_error_hz / k, 1e-9);
        sum_w += 1 / (se * se);
        sum_wf += (e.hz / k) / (se * se);
    }
    if (model.count == 0 or !(sum_w > 0)) return null;
    model.base_hz = sum_wf / sum_w;
    // Refined by each harmonic's phase advance from the first half of the
    // input to the second (Hann-weighted halves leak far less from their
    // neighbours than the phase slope's moving averages do).
    const half = x.len / 2;
    for (0..2) |_| {
        var sw: f64 = 0;
        var swd: f64 = 0;
        for (model.harmonic[0..model.count]) |h| {
            const kf: f64 = @floatFromInt(h);
            const hz = model.base_hz * kf;
            const a = project(x[0..half], rate, hz, 0);
            const b = project(x[half .. 2 * half], rate, hz, half);
            // b conj(a): the phase gained over `half` samples beyond hz's.
            const re = b.re * a.re + b.im * a.im;
            const im = b.im * a.re - b.re * a.im;
            const dw = std.math.atan2(im, re) / @as(f64, @floatFromInt(half));
            const w = @sqrt(re * re + im * im) * kf * kf;
            sw += w;
            swd += w * dw / kf;
        }
        if (!(sw > 0)) break;
        model.base_hz += swd / sw * rate / (2 * std.math.pi);
    }
    // Amplitude and phase at the exact frequencies.
    for (0..model.count) |c| {
        const comp = amplitude(x, rate, model.base_hz * @as(f64, @floatFromInt(model.harmonic[c])));
        model.amp[c] = comp.amp;
        model.phase[c] = comp.phase;
    }
    return if (model.count > 0) model else null;
}

const Complex = struct { re: f64, im: f64 };

/// sum h[n] x[n] e^(-i w (n + offset)) / sum h, h a Hann window over x:
/// the component at `hz` with its phase referred to `offset` samples
/// before x[0].
fn project(x: []const f64, rate: f64, hz: f64, offset: usize) Complex {
    const w = 2 * std.math.pi * hz / rate;
    const p0 = -w * @as(f64, @floatFromInt(offset));
    var cr = @cos(p0);
    var ci = @sin(p0);
    const sr = @cos(w);
    const si = @sin(w);
    var re: f64 = 0;
    var im: f64 = 0;
    var wsum: f64 = 0;
    const denom: f64 = @floatFromInt(x.len - 1);
    for (x, 0..) |v, i| {
        const h = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / denom);
        // x e^(-i (w n + w offset)), the rotation being e^(i (p0 - w n)).
        re += h * v * cr;
        im += h * v * ci;
        wsum += h;
        const ncr = cr * sr + ci * si;
        ci = ci * sr - cr * si;
        cr = ncr;
    }
    return .{ .re = re / wsum, .im = im / wsum };
}

const Component = struct { amp: f64, phase: f64 };

/// The amplitude and phase (at x[0]) of the cosine at `hz` in `x`, by a
/// Hann-weighted projection.
fn amplitude(x: []const f64, rate: f64, hz: f64) Component {
    const n = x.len;
    const w = 2 * std.math.pi * hz / rate;
    var re: f64 = 0;
    var im: f64 = 0;
    var wsum: f64 = 0;
    var cr: f64 = 1;
    var ci: f64 = 0;
    const sr = @cos(w);
    const si = @sin(w);
    const denom: f64 = @floatFromInt(n - 1);
    for (x, 0..) |v, i| {
        const h = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / denom);
        // x e^(-i w n)
        re += h * v * cr;
        im -= h * v * ci;
        wsum += h;
        const ncr = cr * sr - ci * si;
        ci = cr * si + ci * sr;
        cr = ncr;
    }
    return .{ .amp = 2 * @sqrt(re * re + im * im) / wsum, .phase = std.math.atan2(im, re) };
}

// =============================================================================
// Tests

const testing = std.testing;
const sig = @import("signals.zig");

const test_rate: f64 = 11025;
const TestWork = first_partial.Work(1024);

fn hum(out: []f64, base: f64, kind: sig.Mains, db: f64) void {
    const tmp = testing.allocator.alloc(f32, out.len) catch unreachable;
    defer testing.allocator.free(tmp);
    sig.mains(tmp, test_rate, base, kind, db);
    sig.addNoise(tmp, 3e-5, 1);
    for (out, tmp) |*o, v| o.* = v;
}

/// How much of the power at the mains harmonics up to 2 kHz is left,
/// dB: the band the model covers.
fn residualDb(after: []const f64, before: []const f64, base: f64) f64 {
    var a: f64 = 0;
    var b: f64 = 0;
    var k: f64 = 1;
    while (k * base <= top_hz) : (k += 1) {
        a += sq(project(after, test_rate, k * base, 0));
        b += sq(project(before, test_rate, k * base, 0));
    }
    return 10 * std.math.log10(a / b);
}

fn sq(c: Complex) f64 {
    return c.re * c.re + c.im * c.im;
}

test "learns hum and buzz on 50 and 60 Hz mains, off nominal, and takes them out of their harmonics up to 2 kHz 3 s later" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    const n: usize = @intFromFloat(3.5 * test_rate);
    const x = try testing.allocator.alloc(f64, n);
    defer testing.allocator.free(x);
    // From 0.5 s of hum (the most the analyser learns from) 25 dB out; from
    // 0.15 s (the least) 15 dB.
    for ([_][2]f64{ .{ 0.5, -25 }, .{ 0.15, -15 } }) |c| {
        for ([_]f64{ 49.97, 50, 60, 60.04 }) |base| {
            for ([_]sig.Mains{ .hum, .buzz }) |kind| {
                hum(x, base, kind, -50);
                const learnt: usize = @intFromFloat(c[0] * test_rate);
                const m = learn(1024, work, x[0..learnt], 0, test_rate).?;
                // 3 s on, 0.3 s of it.
                const at: usize = @intFromFloat(3 * test_rate);
                var seg: [3307]f64 = undefined;
                @memcpy(&seg, x[at .. at + seg.len]);
                m.subtract(&seg, at, test_rate, 0, 2000);
                const left = residualDb(&seg, x[at .. at + seg.len], base);
                errdefer std.debug.print("{d} s of {d} Hz {s}: base {d}, residual {d:.1} dB\n", .{ c[0], base, @tagName(kind), m.base_hz, left });
                try testing.expect(left < c[1]);
            }
        }
    }
}

test "learns nothing from noise or silence" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    var x: [2756]f64 = undefined;
    @memset(&x, 0);
    try testing.expect(learn(1024, work, &x, 0, test_rate) == null);
    var s32: [2756]f32 = undefined;
    @memset(&s32, 0);
    sig.addNoise(&s32, 1e-3, 5);
    for (&x, s32) |*d, v| d.* = v;
    try testing.expect(learn(1024, work, &x, 0, test_rate) == null);
}

test "a decaying note's tail does not agree with itself a moment later" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    // E5 (659.3 Hz) sits 2 cents under 11 x 60 Hz; dying at 20 dB a second.
    const n: usize = @intFromFloat(0.6 * test_rate);
    var s32: [6615]f32 = undefined;
    sig.pluckedString(s32[0..n], test_rate, .{ .f0 = 659.255, .inharmonicity = 4.4e-5, .t60_s = 3, .max_hz = 2000 });
    sig.addNoise(s32[0..n], 3e-5, 6);
    var x: [6615]f64 = undefined;
    for (x[0..n], s32[0..n]) |*d, v| d.* = v;
    const half: usize = @intFromFloat(0.25 * test_rate);
    const first = learn(1024, work, x[0..half], 0, test_rate);
    const second = learn(1024, work, x[n - half .. n], n - half, test_rate);
    if (first) |f| if (second) |s| try testing.expect(!f.agrees(s));
}
