//! Deterministic synthetic test signals for the tuner's pitch analyser.
//!
//! Every generator writes mono samples into a caller-owned slice (`[]f32`,
//! what the analyser takes, or `[]f64`, what REAPER and a JSFX compute in)
//! and is a pure function of its arguments (noise takes an explicit seed), so a
//! test or benchmark gets the same signal on every run and machine. The
//! signals stand in for what a tuner hears: pure and harmonic-rich tones,
//! a weak or missing fundamental, plucked strings that decay, detuned and
//! wavering notes, noise, DC offset and silence.
//!
//! The plucked string's random excitation uses the Park-Miller "minimal
//! standard" generator: its products stay below 2^53, so a JSFX (whose
//! numbers are doubles) can reproduce the exact same signal for parity
//! checks against REAPER.
const std = @import("std");

const tau = 2.0 * std.math.pi;

/// Park-Miller minimal standard generator: state = state * 16807 mod (2^31 - 1).
pub const MinStd = struct {
    state: u64,

    pub const modulus: u64 = 2147483647;

    /// `seed` must be in 1 .. modulus - 1.
    pub fn init(seed: u64) MinStd {
        std.debug.assert(seed > 0 and seed < modulus);
        return .{ .state = seed };
    }

    /// Next value, uniform in (-1, 1).
    pub fn next(self: *MinStd) f64 {
        self.state = self.state * 16807 % modulus;
        return @as(f64, @floatFromInt(self.state)) / @as(f64, @floatFromInt(modulus)) * 2.0 - 1.0;
    }
};

fn seconds(i: usize, sample_rate: f64) f64 {
    return @as(f64, @floatFromInt(i)) / sample_rate;
}

/// A sine at `freq` Hz, peak `amp`, starting at `phase` radians.
pub fn sine(out: anytype, sample_rate: f64, freq: f64, amp: f64, phase: f64) void {
    for (out, 0..) |*s, i| s.* = @floatCast(amp * @sin(tau * freq * seconds(i, sample_rate) + phase));
}

/// Additive harmonic tone: `amps[k]` is the peak amplitude of harmonic k+1
/// (amps[0] is the fundamental). Harmonics at or above Nyquist are left out,
/// so the tone is band-limited.
pub fn harmonics(out: anytype, sample_rate: f64, f0: f64, amps: []const f64) void {
    @memset(out, 0);
    for (amps, 1..) |a, k| {
        const fk = f0 * @as(f64, @floatFromInt(k));
        if (a == 0 or fk >= sample_rate / 2) continue;
        for (out, 0..) |*s, i| s.* += @floatCast(a * @sin(tau * fk * seconds(i, sample_rate)));
    }
}

/// Band-limited sawtooth: every harmonic k below Nyquist at amp / k.
pub fn sawtooth(out: anytype, sample_rate: f64, f0: f64, amp: f64) void {
    @memset(out, 0);
    var k: usize = 1;
    while (f0 * @as(f64, @floatFromInt(k)) < sample_rate / 2) : (k += 1) {
        const kf: f64 = @floatFromInt(k);
        for (out, 0..) |*s, i| s.* += @floatCast(amp / kf * @sin(tau * f0 * kf * seconds(i, sample_rate)));
    }
}

/// Band-limited square: odd harmonics k below Nyquist at amp / k.
pub fn square(out: anytype, sample_rate: f64, f0: f64, amp: f64) void {
    @memset(out, 0);
    var k: usize = 1;
    while (f0 * @as(f64, @floatFromInt(k)) < sample_rate / 2) : (k += 2) {
        const kf: f64 = @floatFromInt(k);
        for (out, 0..) |*s, i| s.* += @floatCast(amp / kf * @sin(tau * f0 * kf * seconds(i, sample_rate)));
    }
}

/// A stiff string's partials: partial n at n * f0 * sqrt(1 + B n^2), at
/// amp / n, for n = 1 .. `partials` below Nyquist. B is the string's
/// inharmonicity coefficient (around 1e-4 for a guitar's wound strings).
/// The first partial, the one a tuner should read, is f0 * sqrt(1 + B).
pub fn inharmonicString(out: anytype, sample_rate: f64, f0: f64, inharmonicity: f64, partials: usize, amp: f64) void {
    @memset(out, 0);
    for (1..partials + 1) |n| {
        const nf: f64 = @floatFromInt(n);
        const fn_hz = nf * f0 * @sqrt(1 + inharmonicity * nf * nf);
        if (fn_hz >= sample_rate / 2) break;
        for (out, 0..) |*s, i| s.* += @floatCast(amp / nf * @sin(tau * fn_hz * seconds(i, sample_rate)));
    }
}

/// A sine whose pitch swings `depth_cents` either side of `f0`, `rate_hz`
/// times a second (vibrato). The phase is the running integral of the
/// instantaneous frequency, so there are no discontinuities.
pub fn vibrato(out: anytype, sample_rate: f64, f0: f64, depth_cents: f64, rate_hz: f64, amp: f64) void {
    var phase: f64 = 0;
    for (out, 0..) |*s, i| {
        s.* = @floatCast(amp * @sin(phase));
        const f = f0 * std.math.pow(f64, 2.0, depth_cents / 1200.0 * @sin(tau * rate_hz * seconds(i, sample_rate)));
        phase += tau * f / sample_rate;
        if (phase > tau) phase -= tau;
    }
}

/// The instantaneous frequency of `vibrato` at sample `i`.
pub fn vibratoFrequency(i: usize, sample_rate: f64, f0: f64, depth_cents: f64, rate_hz: f64) f64 {
    return f0 * std.math.pow(f64, 2.0, depth_cents / 1200.0 * @sin(tau * rate_hz * seconds(i, sample_rate)));
}

pub const PluckOptions = struct {
    /// Peak of the excitation noise.
    amp: f64 = 0.5,
    /// Time for the fundamental to fall 60 dB.
    t60_s: f64 = 3.0,
    /// One-pole low-pass coefficient (0..1) on the excitation: 0 keeps the
    /// full-band noise of a bright pluck, values near 1 give the duller,
    /// fundamental-heavy attack of a bass or a thumb pluck.
    excitation_lowpass: f64 = 0,
    /// MinStd seed for the excitation.
    seed: u64 = 12345,
};

/// Karplus-Strong plucked string tuned exactly to `f0`.
///
/// The loop is a delay line of N samples, a two-tap low-pass
/// (1 - tap) x[n] + tap x[n-1] and a first-order all-pass whose coefficient is
/// solved so that its phase delay at f0 makes the loop's total delay at f0
/// exactly sample_rate / f0. The fundamental's resonance sits at f0, so f0
/// is the ground truth for the tuner; the higher partials fall off faster,
/// as on a real string.
///
/// The low-pass is the classic two-point average (tap = 0.5, phase delay
/// exactly half a sample) unless that alone would damp the fundamental
/// faster than t60, as it does for high notes, where tap is reduced until the
/// low-pass's loss at f0 is exactly the loss t60 allows.
pub fn pluck(out: anytype, sample_rate: f64, f0: f64, opts: PluckOptions) void {
    const period = sample_rate / f0;
    const w0 = tau * f0 / sample_rate;
    const passes = opts.t60_s * f0;
    // The fundamental's gain per trip round the loop that gives t60.
    const target = std.math.pow(f64, 10.0, -3.0 / passes);
    var tap: f64 = 0.5;
    var lowpass_gain = @cos(w0 / 2.0);
    var lowpass_delay: f64 = 0.5;
    if (lowpass_gain < target) {
        // |H(w0)|^2 = (1-tap)^2 + tap^2 + 2 tap (1-tap) cos(w0) = target^2, smaller root.
        const k = 2.0 * (1.0 - target * target) / (1.0 - @cos(w0));
        tap = 0.5 * (1.0 - @sqrt(1.0 - k));
        lowpass_gain = target;
        lowpass_delay = std.math.atan2(tap * @sin(w0), (1.0 - tap) + tap * @cos(w0)) / w0;
    }
    // Leave the all-pass between 0.5 and 1.5 samples of delay, where it is
    // well behaved.
    const n_delay: usize = @intFromFloat(@floor(period - lowpass_delay - 0.5));
    const allpass_delay = period - lowpass_delay - @as(f64, @floatFromInt(n_delay));
    const c = allpassCoefficient(allpass_delay, w0);
    const g = @min(1.0, target / lowpass_gain);

    var buf: [8192]f64 = undefined;
    std.debug.assert(n_delay <= buf.len);
    const line = buf[0..n_delay];
    var rng = MinStd.init(opts.seed);
    var lp: f64 = 0;
    var mean: f64 = 0;
    for (line) |*v| {
        lp = opts.excitation_lowpass * lp + (1 - opts.excitation_lowpass) * rng.next();
        v.* = lp;
        mean += lp;
    }
    mean /= @floatFromInt(n_delay);
    var peak: f64 = 0;
    for (line) |*v| {
        v.* -= mean;
        peak = @max(peak, @abs(v.*));
    }
    for (line) |*v| v.* *= opts.amp / peak;

    var idx: usize = 0;
    var prev: f64 = 0;
    var ap_x1: f64 = 0;
    var ap_y1: f64 = 0;
    for (out) |*s| {
        const y = line[idx];
        s.* = @floatCast(y);
        const lowpassed = if (tap == 0.5) 0.5 * (y + prev) else (1.0 - tap) * y + tap * prev;
        prev = y;
        const ap = c * lowpassed + ap_x1 - c * ap_y1;
        ap_x1 = lowpassed;
        ap_y1 = ap;
        line[idx] = g * ap;
        idx += 1;
        if (idx == n_delay) idx = 0;
    }
}

/// Coefficient c of H(z) = (c + z^-1) / (1 + c z^-1) whose phase delay at
/// `w` radians/sample is `delay` samples, by bisection (phase delay falls as
/// c rises).
pub fn allpassCoefficient(delay: f64, w: f64) f64 {
    var lo: f64 = -0.999999;
    var hi: f64 = 0.999999;
    for (0..200) |_| {
        const mid = 0.5 * (lo + hi);
        if (allpassPhaseDelay(mid, w) > delay) lo = mid else hi = mid;
    }
    return 0.5 * (lo + hi);
}

pub fn allpassPhaseDelay(c: f64, w: f64) f64 {
    // H(e^jw) = (c + e^-jw) / (1 + c e^-jw)
    const num_re = c + @cos(w);
    const num_im = -@sin(w);
    const den_re = 1 + c * @cos(w);
    const den_im = -c * @sin(w);
    const phase = std.math.atan2(num_im, num_re) - std.math.atan2(den_im, den_re);
    return -phase / w;
}

/// How a string's pitch moves after the pluck. Every partial follows the
/// same factor, so the first partial's frequency at time t is
/// `StringOptions.firstPartialHz(t)`.
pub const PitchPath = union(enum) {
    /// The pitch does not move.
    steady,
    /// Tension glide: nu(t) = nu_inf (1 + alpha e^(-t / tau)), starting
    /// `start_cents` sharp of nu_inf (alpha = 2^(start_cents / 1200) - 1).
    glide: struct { start_cents: f64, tau_s: f64 },
    /// A peg being turned: the pitch starts `start_cents` from nominal and
    /// moves `cents_per_s` cents a second, without end.
    ramp: struct { start_cents: f64, cents_per_s: f64 },

    /// The pitch factor g(t) at `t` seconds.
    pub fn factor(self: PitchPath, t: f64) f64 {
        return switch (self) {
            .steady => 1,
            .glide => |g| 1 + (std.math.pow(f64, 2, g.start_cents / 1200) - 1) * @exp(-t / g.tau_s),
            .ramp => |r| std.math.pow(f64, 2, (r.start_cents + r.cents_per_s * t) / 1200),
        };
    }

    /// The integral of g from 0 to `t`: a partial of nominal frequency f has
    /// phase 2 pi f integral(t).
    pub fn integral(self: PitchPath, t: f64) f64 {
        return switch (self) {
            .steady => t,
            .glide => |g| t + (std.math.pow(f64, 2, g.start_cents / 1200) - 1) * g.tau_s * (1 - @exp(-t / g.tau_s)),
            .ramp => |r| blk: {
                const start = std.math.pow(f64, 2, r.start_cents / 1200);
                if (r.cents_per_s == 0) break :blk start * t;
                const k = r.cents_per_s * std.math.ln2 / 1200;
                break :blk start * (@exp(k * t) - 1) / k;
            },
        };
    }
};

/// A second polarisation of the string's vibration: every partial again,
/// a little detuned, quieter and dying sooner, so partials beat.
pub const Polarisation = struct {
    /// Detuning of every partial from the first polarisation's.
    cents: f64,
    /// Amplitude relative to the first polarisation, under 1.
    gain: f64,
    /// Its t60s as a share of the first polarisation's.
    t60_ratio: f64,
};

pub const StringOptions = struct {
    /// Nominal f0: partial n is at n f0 sqrt(1 + B n^2) (times the pitch
    /// path's factor).
    f0: f64,
    /// The inharmonicity coefficient B.
    inharmonicity: f64,
    /// Partial n's starting amplitude is proportional to 1 / n^rolloff:
    /// 1 for a bright pluck near the bridge, 2 for a mellow one.
    rolloff: f64 = 1,
    /// Extra gain on partial 1 alone: 0.1 puts it 20 dB under where the
    /// rolloff would, as a bridge pickup with the tone rolled off can.
    fundamental_gain: f64 = 1,
    /// Time for partial 1 to fall 60 dB.
    t60_s: f64 = 6,
    /// Partial n's t60 is t60_s / (1 + t60_slope (n - 1)): upper partials
    /// die sooner, as on a real string.
    t60_slope: f64 = 0.3,
    /// Partials at or above this (or Nyquist) are left out.
    max_hz: f64 = 8000,
    /// The sum of every partial's starting amplitude, the signal's largest
    /// possible peak.
    peak: f64 = 0.5,
    pitch: PitchPath = .steady,
    polarisation: ?Polarisation = null,
    /// MinStd seed for the partials' starting phases.
    seed: u64 = 1,

    fn partialRatio(self: StringOptions, n: f64) f64 {
        return n * @sqrt(1 + self.inharmonicity * n * n);
    }

    /// The first partial's frequency `t` seconds after the pluck: what a
    /// tuner should read.
    pub fn firstPartialHz(self: StringOptions, t: f64) f64 {
        return self.f0 * self.partialRatio(1) * self.pitch.factor(t);
    }

    /// The first partial's frequency once the pitch path has settled (the
    /// glide's nu_inf); for a ramp, its frequency at the pluck.
    pub fn settledFirstPartialHz(self: StringOptions) f64 {
        return switch (self.pitch) {
            .steady, .glide => self.f0 * self.partialRatio(1),
            .ramp => self.firstPartialHz(0),
        };
    }
};

/// A plucked stiff string as a sum of decaying partials, starting at full
/// amplitude at sample 0. Unlike `pluck`, every partial's frequency is
/// known exactly (`StringOptions.firstPartialHz`), including its
/// inharmonicity, pitch glide or ramp, so a tuner's error can be measured
/// against the true first partial.
pub fn pluckedString(out: anytype, sample_rate: f64, opts: StringOptions) void {
    @memset(out, 0);
    var rng = MinStd.init(opts.seed);
    var count: usize = 0;
    var amp_sum: f64 = 0;
    var amps: [256]f64 = undefined;
    var phases: [256]f64 = undefined;
    var ratios: [256]f64 = undefined;
    var decays: [256]f64 = undefined;
    const top = @min(opts.max_hz, sample_rate / 2);
    const max_factor = @max(opts.pitch.factor(0), opts.pitch.factor(@as(f64, @floatFromInt(out.len)) / sample_rate));
    while (count < amps.len) : (count += 1) {
        const n: f64 = @floatFromInt(count + 1);
        const ratio = opts.partialRatio(n);
        if (opts.f0 * ratio * max_factor >= top) break;
        var a = 1 / std.math.pow(f64, n, opts.rolloff);
        if (count == 0) a *= opts.fundamental_gain;
        amps[count] = a;
        ratios[count] = ratio;
        phases[count] = tau * (rng.next() + 1) / 2;
        // e^(-t / T) with T = t60 / ln(1000).
        decays[count] = @log(1000.0) * (1 + opts.t60_slope * (n - 1)) / opts.t60_s;
        amp_sum += a;
        if (opts.polarisation) |p| amp_sum += a * p.gain;
    }
    const norm = opts.peak / amp_sum;
    // Envelopes advance by one sample's decay at a time; a partial is left
    // out from the sample its envelope falls under 1e-6 (-120 dB).
    var env: [256]f64 = undefined;
    var env2: [256]f64 = undefined;
    var step: [256]f64 = undefined;
    var step2: [256]f64 = undefined;
    const t60_ratio = if (opts.polarisation) |p| p.t60_ratio else 1;
    const detune = if (opts.polarisation) |p| std.math.pow(f64, 2, p.cents / 1200) else 1;
    const gain2 = if (opts.polarisation) |p| p.gain else 0;
    for (0..count) |k| {
        env[k] = amps[k] * norm;
        env2[k] = amps[k] * norm * gain2;
        step[k] = @exp(-decays[k] / sample_rate);
        step2[k] = @exp(-decays[k] / t60_ratio / sample_rate);
    }
    var live = count;
    for (out, 0..) |*s, i| {
        const cycles = opts.f0 * opts.pitch.integral(seconds(i, sample_rate));
        var v: f64 = 0;
        for (0..live) |k| {
            const angle = tau * ratios[k] * cycles + phases[k];
            v += env[k] * @sin(angle);
            env[k] *= step[k];
            if (gain2 > 0) {
                v += env2[k] * @sin(angle * detune + 1);
                env2[k] *= step2[k];
            }
        }
        while (live > 0 and env[live - 1] < 1e-6 * norm) live -= 1;
        s.* = @floatCast(v);
    }
}

pub const Mains = enum {
    /// A smooth hum: harmonic k of the mains at 1 / k^2.
    hum,
    /// Buzz from rectifiers and dimmers: harmonics up to 5 kHz at
    /// 1 / sqrt(k), odd ones twice as strong.
    buzz,
};

/// Stationary mains interference at `mains_hz` (50 or 60) and its
/// harmonics, scaled to `rms_db` dBFS RMS. Nothing about it starts, stops
/// or decays, as hum doesn't.
pub fn mains(out: anytype, sample_rate: f64, mains_hz: f64, kind: Mains, rms_db: f64) void {
    @memset(out, 0);
    var k: usize = 1;
    var power: f64 = 0;
    const top: f64 = switch (kind) {
        .hum => 1000,
        .buzz => 5000,
    };
    while (mains_hz * @as(f64, @floatFromInt(k)) < @min(top, sample_rate / 2)) : (k += 1) {
        const kf: f64 = @floatFromInt(k);
        const a = switch (kind) {
            .hum => 1 / (kf * kf),
            .buzz => (if (k % 2 == 1) @as(f64, 2) else 1) / @sqrt(kf),
        };
        power += a * a / 2;
        const phase = 0.7 * kf;
        for (out, 0..) |*s, i| s.* += @floatCast(a * @sin(tau * mains_hz * kf * seconds(i, sample_rate) + phase));
    }
    scale(out, std.math.pow(f64, 10, rms_db / 20) / @sqrt(power));
}

/// A fretting-hand-muted ("dead") string: its first 8 harmonics die in
/// `t60_s` (tens of milliseconds) under a burst of pick noise decaying ten
/// times as fast. Added into `out`; no sample of it exceeds `peak`, and it
/// is silent from 2 t60 on.
pub fn mutedString(out: anytype, sample_rate: f64, f0: f64, t60_s: f64, peak: f64, seed: u64) void {
    const n = @min(out.len, @as(usize, @intFromFloat(sample_rate * t60_s * 2)));
    const noise_amp = 0.6;
    var amp_sum: f64 = noise_amp;
    for (1..9) |k| {
        if (f0 * @as(f64, @floatFromInt(k)) < sample_rate / 2) amp_sum += 1 / @as(f64, @floatFromInt(k));
    }
    var rng = MinStd.init(seed);
    var lp: f64 = 0;
    for (out[0..n], 0..) |*s, i| {
        const t = seconds(i, sample_rate);
        var v: f64 = 0;
        for (1..9) |k| {
            const kf: f64 = @floatFromInt(k);
            if (f0 * kf >= sample_rate / 2) break;
            v += @exp(-@log(1000.0) * t / t60_s) / kf * @sin(tau * f0 * kf * t);
        }
        lp = 0.5 * lp + 0.5 * rng.next();
        v += noise_amp * @exp(-@log(1000.0) * t / (t60_s / 10)) * lp;
        s.* += @floatCast(peak / amp_sum * v);
    }
}

/// Adds white Gaussian noise with RMS `noise_rms`.
pub fn addNoise(out: anytype, noise_rms: f64, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (out) |*s| s.* += @floatCast(noise_rms * r.floatNorm(f64));
}

/// RMS of the samples.
pub fn rms(samples: anytype) f64 {
    if (samples.len == 0) return 0;
    var sum: f64 = 0;
    for (samples) |s| sum += @as(f64, s) * @as(f64, s);
    return @sqrt(sum / @as(f64, @floatFromInt(samples.len)));
}

/// Adds noise so the signal-to-noise ratio over the whole slice is `snr_db`.
pub fn addNoiseAtSnr(out: anytype, snr_db: f64, seed: u64) void {
    const signal_rms = rms(out);
    addNoise(out, signal_rms / std.math.pow(f64, 10.0, snr_db / 20.0), seed);
}

pub fn addDc(out: anytype, offset: f64) void {
    for (out) |*s| s.* = @floatCast(s.* + offset);
}

pub fn scale(out: anytype, gain: f64) void {
    for (out) |*s| s.* = @floatCast(s.* * gain);
}

/// Adds `other` into `out` sample by sample (`other` may be shorter).
pub fn mix(out: anytype, other: anytype) void {
    for (out[0..other.len], other) |*s, o| s.* += o;
}

/// Equal-tempered frequency of MIDI note `note` with A4 (note 69) at `a4_hz`.
pub fn midiToHz(note: f64, a4_hz: f64) f64 {
    return a4_hz * std.math.pow(f64, 2.0, (note - 69.0) / 12.0);
}

/// Cents from `reference_hz` to `hz`.
pub fn cents(hz: f64, reference_hz: f64) f64 {
    return 1200.0 * @log2(hz / reference_hz);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Frequency of the strongest spectral peak within +-`search_hz` of `guess`,
/// by a fine Goertzel scan over a Hann-windowed segment: an estimate
/// independent of the analysers under test.
fn spectralPeak(samples: []const f32, sample_rate: f64, guess: f64, search_hz: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    var best_f = guess;
    var best_mag: f64 = -1;
    var step = search_hz / 50.0;
    var lo = guess - search_hz;
    var hi = guess + search_hz;
    for (0..6) |_| {
        var f = lo;
        while (f <= hi) : (f += step) {
            var re: f64 = 0;
            var im: f64 = 0;
            for (samples, 0..) |s, i| {
                const fi: f64 = @floatFromInt(i);
                const w = 0.5 - 0.5 * @cos(tau * fi / (n - 1));
                const a = tau * f * fi / sample_rate;
                re += w * s * @cos(a);
                im -= w * s * @sin(a);
            }
            const mag = re * re + im * im;
            if (mag > best_mag) {
                best_mag = mag;
                best_f = f;
            }
        }
        lo = best_f - step;
        hi = best_f + step;
        step /= 20.0;
    }
    return best_f;
}

test "pluck's fundamental sits at f0 within a tenth of a cent" {
    const sr = 44100.0;
    var buf: [44100]f32 = undefined;
    for ([_]f64{ 41.2034, 82.4069, 146.832, 329.628, 1318.51 }) |f0| {
        pluck(&buf, sr, f0, .{ .t60_s = 4.0 });
        const peak = spectralPeak(buf[4410..], sr, f0, 2.0);
        try testing.expectApproxEqAbs(@as(f64, 0), cents(peak, f0), 0.1);
    }
}

test "a high pluck still sounds after a second instead of dying in the loop filter" {
    // A two-point average alone would take a 1760 Hz string down ~120 dB a
    // second, whatever t60 asked for; t60 = 3 s means 20 dB a second.
    const sr = 44100.0;
    var buf: [44100 + 2 * 4410]f32 = undefined;
    pluck(&buf, sr, 1760.0, .{ .t60_s = 3.0 });
    const at_100ms = rms(buf[4410 .. 2 * 4410]);
    const at_1100ms = rms(buf[44100 + 4410 ..]);
    const drop_db = 20 * std.math.log10(at_100ms / at_1100ms);
    try testing.expect(drop_db > 15 and drop_db < 30);
}

test "pluck decays by about its t60" {
    const sr = 44100.0;
    var buf: [44100 * 2]f32 = undefined;
    pluck(&buf, sr, 110.0, .{ .t60_s = 2.0, .excitation_lowpass = 0.9 });
    // From 0.2 s to 1.2 s the fundamental-dominated tail should drop about
    // 30 dB (half of 60 dB in half of t60); high partials make the early
    // window louder, so allow a wide margin.
    const early = rms(buf[8820 .. 8820 + 4410]);
    const late = rms(buf[52920 .. 52920 + 4410]);
    const drop_db = 20 * std.math.log10(early / late);
    try testing.expect(drop_db > 25 and drop_db < 40);
}

test "pluck is the same every time for the same seed" {
    var a: [4096]f32 = undefined;
    var b: [4096]f32 = undefined;
    pluck(&a, 48000, 196.0, .{ .seed = 99 });
    pluck(&b, 48000, 196.0, .{ .seed = 99 });
    try testing.expectEqualSlices(f32, &a, &b);
}

test "allpassCoefficient gives the requested phase delay" {
    for ([_]f64{ 0.5, 0.8, 1.0, 1.3, 1.49 }) |d| {
        const w = tau * 110.0 / 44100.0;
        try testing.expectApproxEqAbs(d, allpassPhaseDelay(allpassCoefficient(d, w), w), 1e-9);
    }
}

test "addNoiseAtSnr reaches the requested signal-to-noise ratio" {
    var buf: [48000]f32 = undefined;
    sine(&buf, 48000, 220, 0.5, 0);
    const clean = buf;
    addNoiseAtSnr(&buf, 10.0, 1);
    var noise: [48000]f32 = undefined;
    for (&noise, buf, clean) |*n, s, c| n.* = s - c;
    const snr = 20 * std.math.log10(rms(&clean) / rms(&noise));
    try testing.expectApproxEqAbs(@as(f64, 10.0), snr, 0.1);
}

test "harmonics leaves out partials at or above Nyquist" {
    var buf: [1000]f32 = undefined;
    // 1 kHz at 4 kHz sample rate: harmonic 2 is at Nyquist and must be silent.
    harmonics(&buf, 4000, 1000, &.{ 0, 1 });
    for (buf) |s| try testing.expectEqual(@as(f32, 0), s);
}

test "MinStd reproduces Park-Miller's published 10000th value" {
    var r = MinStd.init(1);
    for (0..9999) |_| _ = r.next();
    _ = r.next();
    try testing.expectEqual(@as(u64, 1043618065), r.state);
}

/// Peak amplitude of the component at `freq` Hz, by a Hann-windowed DFT.
fn toneAmplitude(samples: []const f32, sample_rate: f64, freq: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    var re: f64 = 0;
    var im: f64 = 0;
    var wsum: f64 = 0;
    for (samples, 0..) |s, i| {
        const fi: f64 = @floatFromInt(i);
        const w = 0.5 - 0.5 * @cos(tau * fi / (n - 1));
        const a = tau * freq * fi / sample_rate;
        re += w * s * @cos(a);
        im -= w * s * @sin(a);
        wsum += w;
    }
    return 2 * @sqrt(re * re + im * im) / wsum;
}

/// Mean frequency of a single sine between its first upward zero crossing
/// at or after `from` and the one `cycles` later, by linear interpolation.
fn crossingFrequency(samples: []const f32, sample_rate: f64, from: usize, cycles: usize) struct { hz: f64, start_s: f64, end_s: f64 } {
    var times: [2]f64 = undefined;
    var found: usize = 0;
    var count: usize = 0;
    var i = from + 1;
    while (i < samples.len and found < 2) : (i += 1) {
        const a: f64 = samples[i - 1];
        const b: f64 = samples[i];
        if (a < 0 and b >= 0) {
            if (count == 0 or count == cycles) {
                times[found] = (@as(f64, @floatFromInt(i - 1)) + a / (a - b)) / sample_rate;
                found += 1;
            }
            count += 1;
        }
    }
    std.debug.assert(found == 2);
    return .{ .hz = @as(f64, @floatFromInt(cycles)) / (times[1] - times[0]), .start_s = times[0], .end_s = times[1] };
}

test "pluckedString's first partial sits at firstPartialHz, f0 sqrt(1 + B)" {
    const sr = 48000.0;
    const buf = try testing.allocator.alloc(f32, 96000);
    defer testing.allocator.free(buf);
    for ([_][2]f64{ .{ 82.4069, 1.1e-4 }, .{ 41.2034, 1e-3 }, .{ 329.628, 1.1e-5 } }) |c| {
        const opts: StringOptions = .{ .f0 = c[0], .inharmonicity = c[1] };
        pluckedString(buf, sr, opts);
        const truth = opts.firstPartialHz(0);
        try testing.expectApproxEqAbs(c[0] * @sqrt(1 + c[1]), truth, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0), cents(spectralPeak(buf, sr, truth, 0.5), truth), 0.01);
    }
}

test "pluckedString's upper partials are stretched by the inharmonicity" {
    const sr = 48000.0;
    const buf = try testing.allocator.alloc(f32, 96000);
    defer testing.allocator.free(buf);
    const f0 = 41.2034;
    const b = 1e-3;
    pluckedString(buf, sr, .{ .f0 = f0, .inharmonicity = b, .t60_slope = 0 });
    // Partial 4 is 4 f0 sqrt(1 + 16 B), about 13 cents sharp of 4 f1.
    const p4 = 4 * f0 * @sqrt(1 + 16 * b);
    try testing.expect(cents(p4, 4 * f0 * @sqrt(1 + b)) > 12);
    try testing.expectApproxEqAbs(@as(f64, 0), cents(spectralPeak(buf, sr, p4, 2), p4), 0.01);
}

test "a pitch path's integral is the integral of its factor" {
    const paths = [_]PitchPath{
        .steady,
        .{ .glide = .{ .start_cents = 10, .tau_s = 0.3 } },
        .{ .ramp = .{ .start_cents = -40, .cents_per_s = 25 } },
        .{ .ramp = .{ .start_cents = 15, .cents_per_s = 0 } },
    };
    for (paths) |p| {
        // Simpson's rule over 0..2 s.
        const n = 2000;
        const h = 2.0 / @as(f64, n);
        var sum = p.factor(0) + p.factor(2);
        for (1..n) |i| sum += @as(f64, if (i % 2 == 1) 4 else 2) * p.factor(@as(f64, @floatFromInt(i)) * h);
        try testing.expectApproxEqAbs(sum * h / 3, p.integral(2), 1e-9);
    }
    const glide: PitchPath = .{ .glide = .{ .start_cents = 10, .tau_s = 0.3 } };
    try testing.expectApproxEqAbs(@as(f64, 10), cents(glide.factor(0), 1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), cents(glide.factor(10), 1), 1e-5);
}

test "pluckedString's pitch follows its glide and its ramp" {
    const sr = 48000.0;
    const buf = try testing.allocator.alloc(f32, 96000);
    defer testing.allocator.free(buf);
    const paths = [_]PitchPath{
        .{ .glide = .{ .start_cents = 10, .tau_s = 0.3 } },
        .{ .ramp = .{ .start_cents = -40, .cents_per_s = 25 } },
    };
    for (paths) |p| {
        // Partial 1 alone, so zero crossings time it.
        const opts: StringOptions = .{ .f0 = 110, .inharmonicity = 1e-4, .max_hz = 200, .pitch = p };
        pluckedString(buf, sr, opts);
        for ([_]usize{ 2400, 24000, 72000 }) |from| {
            const m = crossingFrequency(buf, sr, from, 10);
            const mean_hz = opts.f0 * opts.partialRatio(1) * (p.integral(m.end_s) - p.integral(m.start_s)) / (m.end_s - m.start_s);
            try testing.expectApproxEqAbs(@as(f64, 0), cents(m.hz, mean_hz), 0.002);
        }
    }
}

test "pluckedString's fundamental_gain sets the fundamental under the octave" {
    const sr = 48000.0;
    const buf = try testing.allocator.alloc(f32, 48000);
    defer testing.allocator.free(buf);
    const opts: StringOptions = .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .fundamental_gain = 0.05 };
    pluckedString(buf, sr, opts);
    const seg = buf[0..4800];
    const a1 = toneAmplitude(seg, sr, opts.firstPartialHz(0));
    const a2 = toneAmplitude(seg, sr, 2 * opts.f0 * @sqrt(1 + 4 * opts.inharmonicity));
    try testing.expectApproxEqAbs(@as(f64, -20), 20 * std.math.log10(a1 / a2), 0.5);
}

test "pluckedString's first partial falls 60 dB in t60" {
    const sr = 48000.0;
    const buf = try testing.allocator.alloc(f32, 3 * 48000);
    defer testing.allocator.free(buf);
    const opts: StringOptions = .{ .f0 = 110, .inharmonicity = 0, .t60_s = 2, .max_hz = 150 };
    pluckedString(buf, sr, opts);
    const early = rms(buf[0..4800]);
    const late = rms(buf[96000 .. 96000 + 4800]);
    try testing.expectApproxEqAbs(@as(f64, 60), 20 * std.math.log10(early / late), 0.5);
}

test "pluckedString's second polarisation is detuned by its cents" {
    const sr = 48000.0;
    const buf = try testing.allocator.alloc(f32, 2 * 48000);
    defer testing.allocator.free(buf);
    const opts: StringOptions = .{
        .f0 = 110,
        .inharmonicity = 0,
        .max_hz = 150,
        .t60_s = 20,
        .polarisation = .{ .cents = 40, .gain = 0.5, .t60_ratio = 1 },
    };
    pluckedString(buf, sr, opts);
    const second = 110 * std.math.pow(f64, 2, 40.0 / 1200.0);
    try testing.expectApproxEqAbs(@as(f64, 0), cents(spectralPeak(buf, sr, second, 0.8), second), 0.1);
    try testing.expectApproxEqAbs(@as(f64, 0.5), toneAmplitude(buf, sr, second) / toneAmplitude(buf, sr, 110), 0.03);
}

test "pluckedString stays under its peak" {
    const sr = 44100.0;
    const buf = try testing.allocator.alloc(f32, 44100);
    defer testing.allocator.free(buf);
    pluckedString(buf, sr, .{ .f0 = 30.8677, .inharmonicity = 3e-4, .peak = 0.5, .polarisation = .{ .cents = 0.5, .gain = 0.3, .t60_ratio = 0.5 } });
    for (buf) |v| try testing.expect(@abs(v) <= 0.5);
}

test "mains reaches its RMS level and holds only harmonics of the mains" {
    const sr = 48000.0;
    var buf: [48000]f32 = undefined;
    for ([_]f64{ 50, 60 }) |hz| {
        for ([_]Mains{ .hum, .buzz }) |kind| {
            mains(&buf, sr, hz, kind, -40);
            try testing.expectApproxEqAbs(@as(f64, -40), 20 * std.math.log10(rms(&buf)), 0.01);
            try testing.expect(toneAmplitude(&buf, sr, hz) > 1e-3);
            // Half-way between harmonics there is nothing.
            try testing.expect(toneAmplitude(&buf, sr, 2.5 * hz) < 1e-6);
        }
    }
}

test "a muted string stays under its peak and is silent from twice its t60" {
    const sr = 48000.0;
    var buf: [9600]f32 = undefined;
    @memset(&buf, 0);
    mutedString(&buf, sr, 82.4069, 0.03, 0.5, 3);
    for (buf) |v| try testing.expect(@abs(v) <= 0.5);
    try testing.expect(rms(buf[0..480]) > 0.01);
    for (buf[2880..]) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "midiToHz and cents agree with A4 = 440" {
    try testing.expectApproxEqAbs(@as(f64, 440), midiToHz(69, 440), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 82.4069), midiToHz(40, 440), 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 100), cents(midiToHz(70, 440), 440), 1e-9);
}
