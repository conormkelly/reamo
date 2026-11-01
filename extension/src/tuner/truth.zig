//! The offline ground truth for a recorded note: what a tuner should read
//! for it, from its whole sustain, to judge the analyser's readings
//! against on real strings (wav_tool.zig).
//!
//! The first partial's frequency is measured every `hop_s` over windows
//! of `window_s` (first_partial.zig's phase slope, following the pitch as
//! it moves), and the string's pitch glide, nu(t) = nu_inf (1 + alpha
//! e^(-t / tau)), is fitted to those measurements, each weighted by the
//! inverse of its variance. nu_inf, the pitch the glide settles to, is the
//! truth; alpha (as cents at the onset) and tau describe the glide.
//!
//! The fit is linear in nu_inf and nu_inf alpha for a given tau, so tau is
//! searched over a log-spaced grid from 30 ms to 10 s and the least-squares
//! pair kept; a string that doesn't glide fits a tiny alpha. Pure: the
//! caller owns the work and the output.
const std = @import("std");
const first_partial = @import("first_partial.zig");

pub const Point = struct {
    /// Seconds from the onset to the middle of the window.
    t: f64,
    hz: f64,
    std_error_hz: f64,
};

pub const Glide = struct {
    /// The settled first partial.
    nu_inf_hz: f64,
    /// How far sharp of nu_inf the fit starts at the onset, cents.
    start_cents: f64,
    tau_s: f64,
    /// RMS of the measurements about the fit, cents.
    rms_cents: f64,
    points: usize,

    /// The fitted first partial `t` seconds after the onset.
    pub fn at(self: Glide, t: f64) f64 {
        const alpha = std.math.pow(f64, 2, self.start_cents / 1200) - 1;
        return self.nu_inf_hz * (1 + alpha * @exp(-t / self.tau_s));
    }
};

/// The first partial near `guess_hz` every `hop_s` from `from_s` to `to_s`
/// seconds after the onset, `x[0]` being the onset, into `out`.
pub fn track(
    comptime max_period: usize,
    work: *first_partial.Work(max_period),
    x: []const f64,
    rate: f64,
    guess_hz: f64,
    from_s: f64,
    to_s: f64,
    window_s: f64,
    hop_s: f64,
    out: []Point,
) []Point {
    const window: usize = @intFromFloat(@round(window_s * rate));
    var guess = guess_hz;
    var n: usize = 0;
    var t = from_s;
    while (t + window_s <= to_s and n < out.len) : (t += hop_s) {
        const start: usize = @intFromFloat(@round(t * rate));
        if (start + window > x.len) break;
        const e = first_partial.estimate(max_period, work, x[start .. start + window], rate, guess, .phase_slope) orelse continue;
        if (!std.math.isFinite(e.std_error_hz) or !(@abs(1200 * @log2(e.hz / guess)) < 50)) continue;
        out[n] = .{ .t = t + window_s / 2, .hz = e.hz, .std_error_hz = e.std_error_hz };
        n += 1;
        guess = e.hz;
    }
    return out[0..n];
}

/// The glide model's weighted least-squares fit to `points`, or null with
/// fewer than 4.
pub fn fitGlide(points: []const Point) ?Glide {
    if (points.len < 4) return null;
    var best: ?Glide = null;
    var best_cost = std.math.inf(f64);
    const steps = 80;
    for (0..steps) |i| {
        const tau = 0.03 * std.math.pow(f64, 10.0 / 0.03, @as(f64, @floatFromInt(i)) / (steps - 1));
        // Weighted least squares for hz = a + b e^(-t / tau).
        var sw: f64 = 0;
        var se: f64 = 0;
        var see: f64 = 0;
        var sy: f64 = 0;
        var sey: f64 = 0;
        for (points) |p| {
            const w = weight(p);
            const e = @exp(-p.t / tau);
            sw += w;
            se += w * e;
            see += w * e * e;
            sy += w * p.hz;
            sey += w * e * p.hz;
        }
        const den = sw * see - se * se;
        if (!(den > 0)) continue;
        const b = (sw * sey - se * sy) / den;
        const a = (sy - b * se) / sw;
        if (!(a > 0)) continue;
        var cost: f64 = 0;
        var sq: f64 = 0;
        for (points) |p| {
            const r = p.hz - (a + b * @exp(-p.t / tau));
            cost += weight(p) * r * r;
            const c = 1200 * @log2(p.hz / (a + b * @exp(-p.t / tau)));
            sq += c * c;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = .{
                .nu_inf_hz = a,
                .start_cents = 1200 * @log2((a + b) / a),
                .tau_s = tau,
                .rms_cents = @sqrt(sq / @as(f64, @floatFromInt(points.len))),
                .points = points.len,
            };
        }
    }
    return best;
}

/// 1 / variance, the standard error floored at a millionth of the frequency
/// so no one point outweighs the rest.
fn weight(p: Point) f64 {
    const se = @max(p.std_error_hz, 1e-6 * p.hz);
    return 1 / (se * se);
}

// =============================================================================
// Tests

const testing = std.testing;
const sig = @import("signals.zig");

const TestWork = first_partial.Work(2048);

fn measureString(opts: sig.StringOptions, seconds: f64) !?Glide {
    const rate = 48000.0;
    const n: usize = @intFromFloat(seconds * rate);
    const s32 = try testing.allocator.alloc(f32, n);
    defer testing.allocator.free(s32);
    const x = try testing.allocator.alloc(f64, n);
    defer testing.allocator.free(x);
    sig.pluckedString(s32, rate, opts);
    sig.addNoise(s32, 3e-5, 1);
    for (x, s32) |*d, v| d.* = v;
    const work = try testing.allocator.create(TestWork);
    defer testing.allocator.destroy(work);
    var pts: [256]Point = undefined;
    const got = track(2048, work, x, rate, opts.firstPartialHz(0.1), 0.1, seconds, 0.2, 0.05, &pts);
    return fitGlide(got);
}

test "recovers a guitar string's settled first partial, the glide's start and its time constant" {
    const opts: sig.StringOptions = .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .pitch = .{ .glide = .{ .start_cents = 10, .tau_s = 0.3 } } };
    const g = (try measureString(opts, 4)).?;
    try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(g.nu_inf_hz, opts.settledFirstPartialHz()), 0.02);
    try testing.expectApproxEqAbs(@as(f64, 10), g.start_cents, 1);
    try testing.expectApproxEqRel(@as(f64, 0.3), g.tau_s, 0.1);
}

test "recovers a fretted bass string's settled first partial under a slow glide" {
    const opts: sig.StringOptions = .{ .f0 = 61.7354, .inharmonicity = 1e-3, .t60_s = 8, .pitch = .{ .glide = .{ .start_cents = 9.6, .tau_s = 0.6 } } };
    const g = (try measureString(opts, 5)).?;
    try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(g.nu_inf_hz, opts.settledFirstPartialHz()), 0.05);
    try testing.expectApproxEqRel(@as(f64, 0.6), g.tau_s, 0.15);
}

test "a string that doesn't glide fits its first partial and no glide" {
    const opts: sig.StringOptions = .{ .f0 = 329.628, .inharmonicity = 1.1e-5 };
    const g = (try measureString(opts, 3)).?;
    try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(g.nu_inf_hz, opts.settledFirstPartialHz()), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0), sig.cents(g.at(0.1), g.nu_inf_hz), 0.05);
}

test "needs at least four measurements" {
    const pts = [_]Point{ .{ .t = 0.1, .hz = 110, .std_error_hz = 0.01 }, .{ .t = 0.2, .hz = 110, .std_error_hz = 0.01 }, .{ .t = 0.3, .hz = 110, .std_error_hz = 0.01 } };
    try testing.expect(fitGlide(&pts) == null);
}
