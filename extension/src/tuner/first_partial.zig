//! Measures one partial's frequency to a small fraction of a cent, given a
//! coarse estimate of it: the tuner's refinement of YIN's period to the
//! first partial f1, which is what a tuner should read.
//!
//! YIN's period answers to every partial at once, so a stiff string's
//! stretched upper partials pull it sharp of f1. Here the input is
//! demodulated at the coarse estimate f, so the partial near f sits near
//! 0 Hz, and then low-passed by three cascaded moving averages one period
//! of f long. Their nulls sit at every multiple of f, so the other
//! partials (at about +f, +2f, ...) and the negative-frequency image (at
//! about -2f) are taken out however strong they are, and only the partial
//! near f is left. Its frequency is then the coarse estimate plus the rate
//! of its phase, estimated by one of `Method`.
//!
//! Pure and allocation-free: the caller owns the `Work` buffers.
const std = @import("std");

const two_pi = 2 * std.math.pi;

pub const Method = enum {
    /// Least-squares line through the unwrapped phase.
    phase_slope,
    /// A second-order (type 2) phase-locked loop run along the segment;
    /// its frequency at the segment's end.
    pll,
    /// Newton's method on the segment's DTFT power near the estimate, as
    /// LINGOT refines its FFT peak.
    dtft_newton,
};

const Complex = struct {
    re: f64,
    im: f64,

    fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    fn norm2(a: Complex) f64 {
        return a.re * a.re + a.im * a.im;
    }
    fn arg(a: Complex) f64 {
        return std.math.atan2(a.im, a.re);
    }
};

/// Phase points the estimators work on, at most.
pub const max_points = 512;

/// Scratch for `estimate`, for moving averages up to `max_period`
/// samples long.
pub fn Work(comptime max_period: usize) type {
    return struct {
        delay: [3][max_period]Complex,
        points: [max_points]Complex,
        times: [max_points]f64,
    };
}

/// Past this phase scatter (radians RMS about the line) the phase can't be
/// unwrapped reliably and `std_error_hz` no longer bounds the error.
pub const max_residual_rad = 0.25;

pub const Estimate = struct {
    hz: f64,
    /// The estimate's standard error, from the scatter of the partial's
    /// phase about its fitted line; infinite when the phase scatters more
    /// than `max_residual_rad`, where the partial is too weak to measure.
    /// On a sine in white noise it is within 15% of the observed scatter.
    std_error_hz: f64,
    /// The partial's peak amplitude in the input's units, averaged over
    /// the segment.
    amplitude: f64,
};

/// Samples a segment must have beyond the moving averages' settling for
/// an estimate: four periods of the coarse estimate.
pub fn minSamples(rate: f64, guess_hz: f64) usize {
    const period = periodSamples(rate, guess_hz);
    return 3 * (period - 1) + 4 * period;
}

fn periodSamples(rate: f64, guess_hz: f64) usize {
    return @max(2, @as(usize, @intFromFloat(@round(rate / guess_hz))));
}

/// The frequency of the partial within about a quarter of `guess_hz` of
/// `guess_hz` in `x` (oldest sample first, `rate` samples a second), or
/// null if `x` is shorter than `minSamples` or the moving average would be
/// longer than the work buffers allow.
pub fn estimate(comptime max_period: usize, work: *Work(max_period), x: []const f64, rate: f64, guess_hz: f64, method: Method) ?Estimate {
    if (!(guess_hz > 0 and guess_hz < rate / 2)) return null;
    const period = periodSamples(rate, guess_hz);
    if (period > max_period) return null;
    if (x.len < minSamples(rate, guess_hz)) return null;

    const w0 = two_pi * guess_hz / rate;
    const rot: Complex = .{ .re = @cos(w0), .im = -@sin(w0) };
    var phasor: Complex = .{ .re = 1, .im = 0 };
    for (&work.delay) |*line| @memset(line[0..period], .{ .re = 0, .im = 0 });
    var s1: Complex = .{ .re = 0, .im = 0 };
    var s2 = s1;
    var s3 = s1;
    var idx: usize = 0;

    // Outputs from `settle` on are free of the zero start; keep every
    // `step`-th, at least four a period, at most max_points.
    const settle = 3 * (period - 1);
    const usable = x.len - settle;
    const step = @max(@max(1, period / 4), (usable + max_points - 1) / max_points);
    // Each moving average delays by (period - 1) / 2 samples.
    const delay = 1.5 * @as(f64, @floatFromInt(period - 1));
    const gain = 1 / std.math.pow(f64, @floatFromInt(period), 3);
    var n: usize = 0;
    var amp_sum: f64 = 0;
    for (x, 0..) |v, i| {
        const z: Complex = .{ .re = v * phasor.re, .im = v * phasor.im };
        phasor = phasor.mul(rot);
        if (i % 1024 == 1023) {
            // Keep the phasor on the unit circle.
            const r = @sqrt(phasor.norm2());
            phasor = .{ .re = phasor.re / r, .im = phasor.im / r };
        }
        s1 = s1.add(z).sub(work.delay[0][idx]);
        work.delay[0][idx] = z;
        s2 = s2.add(s1).sub(work.delay[1][idx]);
        work.delay[1][idx] = s1;
        s3 = s3.add(s2).sub(work.delay[2][idx]);
        work.delay[2][idx] = s2;
        idx += 1;
        if (idx == period) idx = 0;
        if (i >= settle and (i - settle) % step == 0 and n < max_points) {
            work.points[n] = .{ .re = s3.re * gain, .im = s3.im * gain };
            work.times[n] = @as(f64, @floatFromInt(i)) - delay;
            amp_sum += 2 * @sqrt(work.points[n].norm2());
            n += 1;
        }
    }
    if (n < 4) return null;
    const pts = work.points[0..n];
    const ts = work.times[0..n];
    // Times relative to the middle keep the fits well conditioned.
    const mid = 0.5 * (ts[0] + ts[n - 1]);
    for (ts) |*t| t.* -= mid;

    const fit = phaseSlope(pts, ts);
    const dw: f64 = switch (method) {
        .phase_slope => fit.slope,
        .pll => pll(pts, ts, phaseSlope(pts[0..@min(n, 8)], ts[0..@min(n, 8)]).slope),
        .dtft_newton => dtftNewton(pts, ts, fit.slope),
    };
    // The moving averages correlate neighbouring points: over the span
    // there are about span * sum(h^2) / sum(h)^2 independent ones, 0.55 /
    // period per sample for three cascaded averages.
    const span = ts[n - 1] - ts[0];
    const independent = @max(2, span * 0.55 / @as(f64, @floatFromInt(period)));
    const se = if (fit.residual_rms <= max_residual_rad) fit.residual_rms * @sqrt(12 / independent) / span else std.math.inf(f64);
    return .{
        .hz = (w0 + dw) * rate / two_pi,
        .std_error_hz = se * rate / two_pi,
        .amplitude = amp_sum / @as(f64, @floatFromInt(n)),
    };
}

const Fit = struct {
    /// Radians per sample.
    slope: f64,
    /// RMS of the phase about the line, radians.
    residual_rms: f64,
};

/// The least-squares line through the unwrapped phase.
fn phaseSlope(pts: []const Complex, ts: []const f64) Fit {
    var prev = pts[0].arg();
    var unwrapped = prev;
    var st: f64 = 0;
    var sp: f64 = 0;
    var stt: f64 = 0;
    var stp: f64 = 0;
    var spp: f64 = 0;
    for (pts, ts) |p, t| {
        const a = p.arg();
        var d = a - prev;
        d -= two_pi * @round(d / two_pi);
        unwrapped += d;
        prev = a;
        st += t;
        sp += unwrapped;
        stt += t * t;
        stp += t * unwrapped;
        spp += unwrapped * unwrapped;
    }
    const nf: f64 = @floatFromInt(pts.len);
    const den = nf * stt - st * st;
    if (den == 0) return .{ .slope = 0, .residual_rms = std.math.inf(f64) };
    const slope = (nf * stp - st * sp) / den;
    const intercept = (sp - slope * st) / nf;
    // Sum of squared residuals from the sums, without a second pass.
    const ss = spp - 2 * slope * stp - 2 * intercept * sp + slope * slope * stt + 2 * slope * intercept * st + nf * intercept * intercept;
    return .{ .slope = slope, .residual_rms = @sqrt(@max(0, ss) / nf) };
}

/// Radians per sample at the end of the segment, from a type 2 loop whose
/// natural frequency settles it within about a third of the segment.
fn pll(pts: []const Complex, ts: []const f64, start_dw: f64) f64 {
    const span = ts[ts.len - 1] - ts[0];
    const zeta = std.math.sqrt1_2;
    const wn = 3 * 4 / (zeta * span);
    var theta = pts[0].arg();
    var w = start_dw;
    var e: f64 = 0;
    var prev_t = ts[0];
    for (pts[1..], ts[1..]) |p, t| {
        const dt = t - prev_t;
        prev_t = t;
        theta += w * dt;
        e = p.mul(.{ .re = @cos(theta), .im = -@sin(theta) }).arg();
        theta += 2 * zeta * wn * dt * e;
        w += wn * wn * dt * e;
    }
    // The oscillator runs at the integrator's frequency plus the
    // proportional path's: on a ramp the phase error holds steady and the
    // integrator alone lags by 2 zeta / wn.
    return w + 2 * zeta * wn * e;
}

/// Radians per sample maximising |sum p_k e^(-i dw t_k)|^2, from `start`.
fn dtftNewton(pts: []const Complex, ts: []const f64, start: f64) f64 {
    var dw = start;
    for (0..8) |_| {
        var s0: Complex = .{ .re = 0, .im = 0 };
        var s1 = s0;
        var s2 = s0;
        for (pts, ts) |p, t| {
            const e = p.mul(.{ .re = @cos(dw * t), .im = -@sin(dw * t) });
            s0 = s0.add(e);
            // d/d(dw) of e is -i t e, and the second derivative -t^2 e.
            s1 = s1.add(.{ .re = t * e.im, .im = -t * e.re });
            s2 = s2.add(.{ .re = -t * t * e.re, .im = -t * t * e.im });
        }
        const d1 = 2 * (s1.re * s0.re + s1.im * s0.im);
        const d2 = 2 * (s1.norm2() + s2.re * s0.re + s2.im * s0.im);
        if (!(d2 < 0)) break;
        const next = dw - d1 / d2;
        if (@abs(next - dw) < 1e-13) {
            dw = next;
            break;
        }
        dw = next;
    }
    return dw;
}

// =============================================================================
// Tests

const testing = std.testing;
const sig = @import("signals.zig");

const TestWork = Work(1024);
const methods = std.enums.values(Method);

fn toF64(dst: []f64, src: []const f32) []f64 {
    for (dst[0..src.len], src) |*d, s| d.* = s;
    return dst[0..src.len];
}

test "measures a sine to a ten-thousandth of a cent from a guess 30 cents off (the PLL to a thousandth)" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    var x: [3600]f64 = undefined;
    const rate = 12000.0;
    for ([_]f64{ 41.2034, 82.4069, 329.628, 1318.51 }) |f| {
        sig.sine(&x, rate, f, 0.3, 0.4);
        for ([_]f64{ -30, 0, 30 }) |off| {
            const guess = f * std.math.pow(f64, 2, off / 1200);
            for (methods) |m| {
                const e = estimate(1024, work, &x, rate, guess, m).?;
                errdefer std.debug.print("{d} Hz, guess {d} c, {s}: {d}\n", .{ f, off, @tagName(m), e.hz });
                try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(e.hz, f), @as(f64, if (m == .pll) 1e-3 else 1e-4));
                try testing.expectApproxEqAbs(@as(f64, 0.3), e.amplitude, 0.003);
            }
        }
    }
}

test "reads a stiff string's first partial within a hundredth of a cent (the PLL five), not its stretched upper partials" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    const rate = 12000.0;
    var buf32: [4800]f32 = undefined;
    var x: [4800]f64 = undefined;
    // Bright and weak-fundamental strings at B up to 1e-3: partial 2 is
    // up to 20 dB over partial 1 and partial 8 is 55 cents sharp of 8 f1.
    for ([_][2]f64{ .{ 41.2034, 1e-3 }, .{ 82.4069, 1.1e-4 }, .{ 61.7354, 1e-3 }, .{ 329.628, 1.1e-5 } }) |c| {
        for ([_]f64{ 1, 0.05 }) |fundamental_gain| {
            const opts: sig.StringOptions = .{ .f0 = c[0], .inharmonicity = c[1], .fundamental_gain = fundamental_gain, .max_hz = 5000 };
            sig.pluckedString(&buf32, rate, opts);
            const f1 = opts.firstPartialHz(0);
            for (methods) |m| {
                const e = estimate(1024, work, toF64(&x, &buf32), rate, f1 * 1.004, m).?;
                errdefer std.debug.print("{d} Hz B {d} gain {d}, {s}: {d} c\n", .{ c[0], c[1], fundamental_gain, @tagName(m), sig.cents(e.hz, f1) });
                try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(e.hz, f1), @as(f64, if (m == .pll) 0.05 else 0.01));
            }
        }
    }
}

test "the PLL ends on a ramping pitch where the phase slope reads its middle" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    const rate = 12000.0;
    var buf32: [3600]f32 = undefined;
    var x: [3600]f64 = undefined;
    // 20 cents a second over 0.3 s: the segment's middle is 3 cents under its end.
    const opts: sig.StringOptions = .{ .f0 = 110, .inharmonicity = 0, .max_hz = 150, .t60_s = 100, .pitch = .{ .ramp = .{ .start_cents = 0, .cents_per_s = 20 } } };
    sig.pluckedString(&buf32, rate, opts);
    _ = toF64(&x, &buf32);
    const period = periodSamples(rate, 110);
    // The moving averages see the input 1.5 periods late.
    const end_s = (@as(f64, @floatFromInt(x.len - 1)) - 1.5 * @as(f64, @floatFromInt(period - 1))) / rate;
    const start_s = (@as(f64, @floatFromInt(3 * (period - 1))) - 1.5 * @as(f64, @floatFromInt(period - 1))) / rate;
    const middle = opts.firstPartialHz(0.5 * (start_s + end_s));
    const slope = estimate(1024, work, &x, rate, 110, .phase_slope).?;
    try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(slope.hz, middle), 0.01);
    const loop = estimate(1024, work, &x, rate, 110, .pll).?;
    try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(loop.hz, opts.firstPartialHz(end_s)), 0.3);
}

test "the standard error predicts the scatter of estimates on a noisy sine within 25%" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    const rate = 11025.0;
    var s32: [3307]f32 = undefined;
    var x: [3307]f64 = undefined;
    for ([_][2]f64{ .{ 41.2, 10 }, .{ 110, 0 }, .{ 330, 10 } }) |c| {
        var sum: f64 = 0;
        var sum2: f64 = 0;
        var se_sum: f64 = 0;
        const trials = 100;
        for (0..trials) |k| {
            sig.sine(&s32, rate, c[0], 0.01, 0.3 * @as(f64, @floatFromInt(k)));
            // Per-sample SNR c[1] dB.
            sig.addNoise(&s32, 0.01 / @sqrt(2.0) / std.math.pow(f64, 10, c[1] / 20), 100 + k);
            const e = estimate(1024, work, toF64(&x, &s32), rate, c[0] * 1.002, .phase_slope).?;
            sum += e.hz;
            sum2 += e.hz * e.hz;
            se_sum += e.std_error_hz;
        }
        const mean = sum / trials;
        const sd = @sqrt(sum2 / trials - mean * mean);
        errdefer std.debug.print("{d} Hz at {d} dB: sd {d}, se {d}\n", .{ c[0], c[1], sd, se_sum / trials });
        try testing.expectApproxEqRel(sd, se_sum / trials, 0.25);
    }
}

test "has no standard error to offer where the partial is missing" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    const rate = 11025.0;
    var s32: [3307]f32 = undefined;
    var x: [3307]f64 = undefined;
    // Harmonics 2-6 of 55 Hz: nothing at 55 Hz.
    sig.harmonics(&s32, rate, 55, &.{ 0, 0.3, 0.25, 0.2, 0.15, 0.1 });
    sig.addNoise(&s32, 1e-5, 3);
    const e = estimate(1024, work, toF64(&x, &s32), rate, 55.2, .phase_slope).?;
    try testing.expect(std.math.isInf(e.std_error_hz));
}

test "refuses segments too short for the moving averages to settle, and guesses it can't hold" {
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    var x: [3600]f64 = undefined;
    sig.sine(&x, 12000, 82.4, 0.3, 0);
    const need = minSamples(12000, 82.4);
    try testing.expect(estimate(1024, work, x[0 .. need - 1], 12000, 82.4, .phase_slope) == null);
    try testing.expect(estimate(1024, work, x[0..need], 12000, 82.4, .phase_slope) != null);
    // A period of 1200 samples is longer than the work buffers hold.
    try testing.expect(estimate(1024, work, &x, 12000, 10, .phase_slope) == null);
    for ([_]f64{ 0, -5, 6000, std.math.nan(f64) }) |g| try testing.expect(estimate(1024, work, &x, 12000, g, .phase_slope) == null);
}
