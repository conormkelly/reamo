//! The tuner's pitch analyser: mono samples in, a frequency, note, cents,
//! clarity and settling and stable flags out, whenever the caller asks (the
//! tuner asks at 30 Hz).
//!
//! The pitch detector is YIN as PitchDetect.jsfx runs it (FFT
//! autocorrelation, the difference function with exact energy terms, the
//! first dip of the cumulative mean normalised difference under 0.15,
//! parabolic interpolation on the raw difference), with three changes, each
//! chosen by measuring it on synthetic signals (`zig build tuner-bench`):
//!
//! - The input passes a 2 kHz Butterworth low-pass first. Upper harmonics
//!   narrow the difference function's dip until a parabola no longer fits
//!   it: unfiltered, a sawtooth at E6 reads 1.3-1.9 cents off; filtered, under
//!   0.1. The filter also takes out most of a wide-band noise floor (tones
//!   at 10 dB SNR stay on the note) and tempers the pull of a stiff
//!   string's sharp upper partials. The tuner's range ends near 2 kHz, so
//!   no fundamental it reads is lost.
//! - The window is a fixed 92.9 ms (the JSFX's 4096 samples at 44.1 kHz)
//!   at every sample rate. Up to 48 kHz the input rate is analysed; above
//!   it only every D-th filtered sample is kept, D the smallest whole
//!   number that brings the rate to 48 kHz or under (2 at 88.2 and 96 kHz,
//!   4 at 176.4 and 192 kHz), the low-pass doubling as the anti-alias
//!   filter. Bass E1 and B0 read at any rate, and the cost and memory stay
//!   those of the 48 kHz case. Analysing at 22-24 kHz would halve the cost
//!   but misses the +-1 cent target at E6.
//! - A pitch is reported only when the signal is periodic enough: with no
//!   dip under 0.15, the deepest one must still be under 0.3, or there is
//!   no pitch. Noise, which the JSFX turns into notes, reads as no pitch.
//!
//! YIN's period answers to every partial at once, and a real string's
//! upper partials are sharp of whole multiples of the first (partial n by
//! about 866 B n^2 cents), so on a stiff string YIN reads up to several
//! cents sharp of the first partial f1, which is what a tuner should read.
//! The frequency reported is therefore f1, measured by first_partial.zig
//! from the phase slope of the partial nearest YIN's frequency over the
//! input since the last onset (at most 0.3 s; 0.2 s is too short for B0,
//! 0.4 s lags a turning peg and a glide), at a fine rate of 11-22 kHz.
//! Where the first partial is too weak to measure well (a missing or
//! buried fundamental) the two estimates are weighted by the inverse of
//! their variances, YIN's taken as 1 cent: on sustained stiff strings the
//! error falls from 4.4 cents (95th percentile) to 0.03 (`zig build
//! tuner-targets`). An onset is an energy jump of 9 dB over the last 10-40 ms.
//!
//! After an onset, a jump of the frequency by an octave, a twelfth or two
//! octaves (YIN's first dip moving between multiples of the period, as a
//! note decays under hum or another note) is held back until three
//! analyses in a row make it. A caller that knows the string can pass its
//! range (`Settings.range`), and no period outside it is considered: the
//! cure for a fundamental so weak that YIN reads the octave for the first
//! few hundred milliseconds, which the spectrum can't cure without
//! misreading notes under hum or over a ringing previous note.
//!
//! The note shows from the first reading after an onset; the reading is
//! `settling` for 120 ms (a string's attack, about half its glide's time
//! constant), and `stable` once the shown pitch's slope over 300 ms is
//! under 0.5 cent a second.
//!
//! The window is analysed only when `analyse` is called, not every hop.
//! Nothing is allocated after `init`: the caller owns the `Analyser`
//! (about 490 KB, so not on the stack) and calls `push` and `analyse` from
//! one thread, not the audio thread.
const std = @import("std");
const fft_mod = @import("fft.zig");
const first_partial = @import("first_partial.zig");

/// What the tuner's user sets.
pub const Settings = struct {
    /// A4's frequency. Readings are none unless it is positive and finite;
    /// tuner/setParam holds it to 400-480 Hz.
    reference_hz: f64 = 440,
    /// A window whose input RMS is under this many dBFS is silence.
    silence_db: f64 = -60,
    /// An instrument's range (a guitar or bass mode's strings, a few
    /// semitones either side): no period outside it is considered, so
    /// nothing can read an octave or more outside it. Null for a chromatic
    /// tuner's whole range.
    range: ?Range = null,
};

pub const Range = struct { low_hz: f64, high_hz: f64 };

pub const Reading = struct {
    /// The first partial's frequency as it should be shown, smoothed; 0
    /// when there is no pitch: silence, noise, or no periodicity.
    freq_hz: f64,
    /// MIDI note nearest the frequency (A4 = 69).
    note: i32,
    /// From the note, -50 to +50.
    cents: f64,
    /// How periodic the input is at the detected period, 0 to 1: 1 minus
    /// YIN's normalised difference there (1 for a pure tone; noise and a
    /// second note lower it).
    clarity: f64,
    /// Set for `Options.settle_s` after an onset or a jump of the pitch:
    /// the note is known, but the string is still in its attack and the
    /// cents mean little yet.
    settling: bool = false,
    /// Set once the shown pitch has moved under `Options.stable_cents_per_s`
    /// over the last `Options.stable_s`: the reading to tune by.
    stable: bool = false,

    pub const none: Reading = .{ .freq_hz = 0, .note = 0, .cents = 0, .clarity = 0 };
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
    /// How YIN's period is refined to the first partial's frequency (see
    /// first_partial.zig); null reports YIN's interpolated period.
    refinement: ?first_partial.Method = .phase_slope,
    /// The refinement measures at most this much of the input since the
    /// last onset.
    refine_window_s: f64 = 0.3,
    /// The uncertainty given YIN's frequency as an estimate of the first
    /// partial (mostly the pull of a stiff string's upper partials): the
    /// reading weights YIN's and the refinement's frequencies by the
    /// inverse of their variances.
    yin_sigma_cents: f64 = 1,
    /// After an onset, a jump of the frequency by 2, 3 or 4 times (either
    /// way) is held back until this many analyses in a row agree; 0 for
    /// none.
    octave_hold: u8 = 3,
    /// Whether the shown pitch is smoothed: readings far from the median
    /// of the last five replaced by it (a Hampel filter), then a one-euro
    /// filter, whose cutoff rises with the pitch's rate of change, so it
    /// follows a turning peg and steadies a held note. Off: on the
    /// synthetic strings the refined pitch is already steady (jitter
    /// 0.005-0.07 cent) and the filter's lag costs more on gliding and
    /// beating strings than it saves; real input may say otherwise.
    smoothing: bool = false,
    /// The one-euro filter's cutoff on a still pitch, Hz.
    euro_min_hz: f64 = 0.5,
    /// How much its cutoff rises per cent a second of change, Hz.
    euro_beta: f64 = 3,
    /// The cutoff of its estimate of the rate of change, Hz.
    euro_rate_hz: f64 = 1,
    /// How long after an onset (or a jump of more than a semitone) the
    /// reading is `settling`.
    settle_s: f64 = 0.12,
    /// `stable` needs the shown pitch's least-squares slope over this long
    /// under `stable_cents_per_s`.
    stable_s: f64 = 0.3,
    stable_cents_per_s: f64 = 0.5,
};

/// Analyses kept for the Hampel filter and for the stability slope.
const hampel_len = 5;
const history_len = 32;
/// The Hampel filter replaces a reading more than 3 scaled median absolute
/// deviations from the median, and at least this many cents.
const hampel_floor_cents = 1.0;


/// The refinement's input is the analysed signal low-passed again and
/// decimated to a rate from this up to twice it (the first partial is
/// under 2 kHz); rates under it are kept as they are.
const fine_rate_floor = 11025.0;
/// The longest period the refinement averages over: YIN's longest
/// (half the window) at the fastest fine rate.
const max_fine_period: usize = @as(usize, @intFromFloat(@ceil(2 * fine_rate_floor * window_seconds / 2))) + 1;

/// An onset is a 5 ms block of fine-rate input with `onset_ratio` times
/// the mean energy of the blocks 10 to 40 ms before it, at least 50 ms
/// after the last one.
const onset_block_s = 0.005;
const onset_history = 8;
const onset_ratio = 8.0;
const onset_refractory_s = 0.05;

/// The tuner's analyser.
pub const Analyser = AnalyserWith(.{});

pub fn AnalyserWith(comptime options: Options) type {
    const max_window: usize = @intFromFloat(@ceil(window_seconds * options.max_analysis_rate));
    const max_fft = std.math.ceilPowerOfTwo(usize, max_window + max_window / 2) catch unreachable;
    const fine_needed = options.refinement != null;
    const max_fine: usize = if (!fine_needed) 1 else @intFromFloat(@ceil(options.refine_window_s * 2 * fine_rate_floor));
    const max_block: usize = @intFromFloat(@ceil(onset_block_s * 2 * fine_rate_floor));
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

        /// Every `fine_decimation`-th analysed sample, low-passed again, at
        /// `fine_rate`: the refinement's input. A ring of the last
        /// `max_fine`, `fine_count` written in all.
        fine_decimation: usize,
        fine_rate: f64,
        fine_lowpass: Biquad,
        fine_phase: usize,
        fine: [max_fine]f64,
        fine_count: u64,
        /// `fine_count` at the last onset.
        onset_at: u64,
        block_len: usize,
        block_fill: usize,
        block_energy: f64,
        /// Energies of the last `onset_history` full blocks, newest at
        /// `blocks_pos - 1`.
        blocks: [onset_history]f64,
        blocks_pos: usize,
        /// The fine input since the last onset (at most refine_window_s),
        /// oldest first, loaded by each analysis.
        segment: [max_fine]f64,
        segment_len: usize,
        refine_work: first_partial.Work(max_fine_period),

        /// Analysed samples kept in all.
        kept_count: u64,
        /// The octave hold: log2 of the frequency it holds to (NaN for
        /// none), the onset it was set after, the jump waiting for
        /// agreement and how many analyses in a row have made it, and the
        /// last analysis's input and factor.
        hold_log2: f64,
        hold_onset: u64,
        hold_pending: f64,
        hold_count: u8,
        hold_at: u64,
        hold_factor: f64,

        /// The shown pitch's tracking, in cents above 1 Hz: the input it
        /// was last updated at, whether that analysis had a pitch, the
        /// onset it follows, the filter's value and rate (cents a second),
        /// the input time (seconds) of the last update and of the start of
        /// the note, the last raw readings and the shown history.
        track_at: u64,
        track_voiced: bool,
        track_onset: u64,
        track_value: f64,
        track_rate: f64,
        track_time: f64,
        track_start: f64,
        recent: [hampel_len]f64,
        recent_len: usize,
        recent_pos: usize,
        history_t: [history_len]f64,
        history_v: [history_len]f64,
        history_len_used: usize,
        history_pos: usize,
        last_clarity: f64,

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
            self.fine_decimation = @max(1, @as(usize, @intFromFloat(@floor(analysis_rate / fine_rate_floor))));
            self.fine_rate = analysis_rate / @as(f64, @floatFromInt(self.fine_decimation));
            self.fine_lowpass = if (self.fine_decimation > 1) Biquad.lowpass(analysis_rate, 2000) else Biquad.passthrough;
            self.block_len = @intFromFloat(@round(onset_block_s * self.fine_rate));
            std.debug.assert(self.block_len <= max_block);
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
            self.fine_lowpass.clear();
            self.fine_phase = 0;
            @memset(&self.fine, 0);
            self.fine_count = 0;
            self.onset_at = 0;
            self.segment_len = 0;
            self.kept_count = 0;
            self.hold_log2 = std.math.nan(f64);
            self.hold_onset = 0;
            self.hold_pending = 1;
            self.hold_count = 0;
            self.hold_at = std.math.maxInt(u64);
            self.hold_factor = 1;
            self.track_at = std.math.maxInt(u64);
            self.track_voiced = false;
            self.track_onset = 0;
            self.track_value = 0;
            self.track_rate = 0;
            self.track_time = 0;
            self.track_start = 0;
            self.recent_len = 0;
            self.recent_pos = 0;
            self.history_len_used = 0;
            self.history_pos = 0;
            self.last_clarity = 0;
            self.block_fill = 0;
            self.block_energy = 0;
            @memset(&self.blocks, 0);
            self.blocks_pos = 0;
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
                    self.kept_count += 1;
                    if (fine_needed) self.pushFine(y);
                }
            }
        }

        fn pushFine(self: *Self, y: f64) void {
            const v = self.fine_lowpass.step(y);
            self.fine_phase += 1;
            if (self.fine_phase < self.fine_decimation) return;
            self.fine_phase = 0;
            self.fine[@intCast(self.fine_count % max_fine)] = v;
            self.fine_count += 1;
            self.block_energy += v * v;
            self.block_fill += 1;
            if (self.block_fill < self.block_len) return;
            // Blocks 2 to onset_history back, 10 to 40 ms before this one.
            var before: f64 = 0;
            for (2..onset_history) |k| before += self.blocks[(self.blocks_pos + onset_history - k) % onset_history];
            before /= onset_history - 2;
            const since_last = self.fine_count - self.onset_at;
            const refractory: u64 = @intFromFloat(onset_refractory_s * self.fine_rate);
            if (self.block_energy > onset_ratio * before and self.block_energy > 0 and (self.onset_at == 0 or since_last >= refractory)) {
                self.onset_at = self.fine_count - self.block_len;
            }
            self.blocks[self.blocks_pos] = self.block_energy;
            self.blocks_pos = (self.blocks_pos + 1) % onset_history;
            self.block_energy = 0;
            self.block_fill = 0;
        }

        /// Loads the fine input since the last onset, at most
        /// `refine_window_s` of it, into `segment`.
        fn loadSegment(self: *Self) void {
            const want: u64 = @intFromFloat(options.refine_window_s * self.fine_rate);
            const since_onset = self.fine_count - self.onset_at;
            const n: usize = @intCast(@min(@min(want, since_onset), @min(self.fine_count, max_fine)));
            const start = self.fine_count - n;
            for (self.segment[0..n], 0..) |*d, i| d.* = self.fine[@intCast((start + i) % max_fine)];
            self.segment_len = n;
        }

        /// The first partial's frequency near `guess_hz`, measured over the
        /// loaded segment, and its standard error in cents; null with too
        /// little input since the onset to measure.
        fn refine(self: *Self, guess_hz: f64) ?struct { hz: f64, sigma_cents: f64 } {
            const method = options.refinement orelse return null;
            const e = first_partial.estimate(max_fine_period, &self.refine_work, self.segment[0..self.segment_len], self.fine_rate, guess_hz, method) orelse return null;
            // A partial a quarter-tone or more from the guess is not the
            // one YIN found.
            if (!(@abs(1200 * @log2(e.hz / guess_hz)) < 50)) return null;
            // 1200 / ln 2 cents per unit of relative frequency; the standard
            // error runs up to 15% under the observed scatter.
            return .{ .hz = e.hz, .sigma_cents = 1.15 * 1731.234 * e.std_error_hz / e.hz };
        }

        /// `f`, unless it is 2, 3 or 4 times (or a half, third or quarter
        /// of) the frequency held since the onset, in which case the held
        /// one, until `octave_hold` analyses in a row have made the jump.
        fn holdOctave(self: *Self, f: f64) f64 {
            if (options.octave_hold == 0) return f;
            // Without new input, the same decision as last time.
            if (self.kept_count == self.hold_at) return f / self.hold_factor;
            self.hold_at = self.kept_count;
            self.hold_factor = 1;
            const lf = @log2(f);
            if (self.onset_at != self.hold_onset or std.math.isNan(self.hold_log2)) {
                self.hold_onset = self.onset_at;
                self.hold_log2 = lf;
                self.hold_count = 0;
                return f;
            }
            const jumps = [_]f64{ 2, 3, 4, 0.5, 1.0 / 3.0, 0.25 };
            const quarter_tone = 1.0 / 24.0;
            for (jumps) |j| {
                if (@abs(lf - self.hold_log2 - @log2(j)) > quarter_tone) continue;
                if (j == self.hold_pending) self.hold_count += 1 else {
                    self.hold_pending = j;
                    self.hold_count = 1;
                }
                if (self.hold_count >= options.octave_hold) break;
                self.hold_factor = j;
                return f / j;
            }
            self.hold_log2 = lf;
            self.hold_count = 0;
            self.hold_pending = 1;
            return f;
        }

        /// YIN's `coarse` frequency and the refinement's, weighted by the
        /// inverse of their variances (in cents, around `coarse`).
        fn combine(self: *Self, coarse: f64) f64 {
            const fine = self.refine(coarse) orelse return coarse;
            if (!std.math.isFinite(fine.sigma_cents)) return coarse;
            const vy = options.yin_sigma_cents * options.yin_sigma_cents;
            const vf = fine.sigma_cents * fine.sigma_cents;
            const offset = 1200 * @log2(fine.hz / coarse);
            return coarse * std.math.pow(f64, 2, offset * vy / (vy + vf) / 1200);
        }

        /// The pitch of the last 92.9 ms of input.
        pub fn analyse(self: *Self, settings: Settings) Reading {
            if (!(settings.reference_hz > 0 and std.math.isFinite(settings.reference_hz))) return Reading.none;
            const shown = self.track(self.measure(settings)) orelse return Reading.none;
            const midi = 69 + 12 * @log2(shown.hz / settings.reference_hz);
            const note = @floor(midi + 0.5);
            return .{
                .freq_hz = shown.hz,
                .note = @intFromFloat(note),
                .cents = (midi - note) * 100,
                .clarity = shown.clarity,
                .settling = shown.settling,
                .stable = shown.stable,
            };
        }

        const Measured = struct { hz: f64, clarity: f64 };

        /// The first partial's frequency now, unsmoothed, or null for no pitch.
        fn measure(self: *Self, settings: Settings) ?Measured {
            const w = self.window;
            var energy: f64 = 0;
            for (self.energy[0..w]) |e| energy += e;
            const rms = @sqrt(energy / @as(f64, @floatFromInt(w * self.decimation)));
            if (20 * std.math.log10(@max(rms, 1e-7)) < settings.silence_db) return null;

            self.difference();
            const best = self.pickPeriod(settings.range) orelse return null;
            const detected = self.analysis_rate / self.interpolate(best);
            if (fine_needed) self.loadSegment();
            const coarse = self.holdOctave(detected);
            return .{ .hz = self.combine(coarse), .clarity = std.math.clamp(1 - self.cmnd[best], 0, 1) };
        }

        const Shown = struct { hz: f64, clarity: f64, settling: bool, stable: bool };

        /// What to show for `m`, through the tracking state. The state moves
        /// only with new input: analysing again without any shows the same.
        fn track(self: *Self, m: ?Measured) ?Shown {
            const now = @as(f64, @floatFromInt(self.kept_count)) / self.analysis_rate;
            const fresh = self.kept_count != self.track_at;
            self.track_at = self.kept_count;
            const got = m orelse {
                if (fresh) self.track_voiced = false;
                return null;
            };
            const x = 1200 * @log2(got.hz);
            if (fresh) {
                // An onset, a gap with no pitch, or a jump of over a
                // semitone starts the note afresh.
                const new_onset = self.onset_at != self.track_onset;
                if (!self.track_voiced or new_onset or @abs(x - self.track_value) > 100) {
                    self.track_onset = self.onset_at;
                    self.track_start = if (new_onset and fine_needed)
                        now - @as(f64, @floatFromInt(self.fine_count - self.onset_at)) / self.fine_rate
                    else
                        now;
                    self.track_value = x;
                    self.track_rate = 0;
                    self.recent_len = 0;
                    self.recent_pos = 0;
                    self.history_len_used = 0;
                } else if (options.smoothing) {
                    self.smooth(x, now - self.track_time);
                } else {
                    self.track_value = x;
                }
                self.track_voiced = true;
                self.track_time = now;
                self.last_clarity = got.clarity;
                self.history_t[self.history_pos] = now;
                self.history_v[self.history_pos] = self.track_value;
                self.history_pos = (self.history_pos + 1) % history_len;
                self.history_len_used = @min(self.history_len_used + 1, history_len);
            }
            const settling = now - self.track_start < options.settle_s;
            return .{
                .hz = std.math.pow(f64, 2, self.track_value / 1200),
                .clarity = self.last_clarity,
                .settling = settling,
                .stable = !settling and self.slopeSettled(now),
            };
        }

        /// One step of the Hampel and one-euro filters with the reading `x`
        /// (cents), `dt` seconds after the last.
        fn smooth(self: *Self, x: f64, dt: f64) void {
            self.recent[self.recent_pos] = x;
            self.recent_pos = (self.recent_pos + 1) % hampel_len;
            self.recent_len = @min(self.recent_len + 1, hampel_len);
            var v = x;
            if (self.recent_len >= 3) {
                var sorted: [hampel_len]f64 = undefined;
                const r = sorted[0..self.recent_len];
                @memcpy(r, self.recent[0..self.recent_len]);
                std.mem.sort(f64, r, {}, std.sort.asc(f64));
                const median = r[r.len / 2];
                for (r) |*d| d.* = @abs(d.* - median);
                std.mem.sort(f64, r, {}, std.sort.asc(f64));
                const mad = r[r.len / 2];
                if (@abs(x - median) > @max(3 * 1.4826 * mad, hampel_floor_cents)) v = median;
            }
            if (!(dt > 0)) return;
            const rate = (v - self.track_value) / dt;
            self.track_rate += smoothingFactor(dt, options.euro_rate_hz) * (rate - self.track_rate);
            const cutoff = options.euro_min_hz + options.euro_beta * @abs(self.track_rate);
            self.track_value += smoothingFactor(dt, cutoff) * (v - self.track_value);
        }

        /// Whether the shown pitch's least-squares slope over the last
        /// `stable_s` is under `stable_cents_per_s`, with that much shown.
        fn slopeSettled(self: *const Self, now: f64) bool {
            var n: f64 = 0;
            var st: f64 = 0;
            var sv: f64 = 0;
            var stt: f64 = 0;
            var stv: f64 = 0;
            var oldest = now;
            for (0..self.history_len_used) |k| {
                const i = (self.history_pos + history_len - 1 - k) % history_len;
                const t = self.history_t[i] - now;
                if (t < -options.stable_s - 1e-9) break;
                oldest = self.history_t[i];
                n += 1;
                st += t;
                sv += self.history_v[i];
                stt += t * t;
                stv += t * self.history_v[i];
            }
            if (now - oldest < options.stable_s - 0.05 or n < 3) return false;
            const den = n * stt - st * st;
            if (den <= 0) return false;
            return @abs((n * stv - st * sv) / den) < options.stable_cents_per_s;
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
        /// one if it is under `options.voicing_threshold`; only periods
        /// within `range` if there is one.
        fn pickPeriod(self: *const Self, range: ?Range) ?usize {
            const half = self.window / 2;
            var min_tau: usize = @max(2, @as(usize, @intFromFloat(self.analysis_rate / max_pitch_hz)));
            var end = half - 1;
            if (range) |r| {
                if (r.high_hz > 0) min_tau = @max(min_tau, @as(usize, @intFromFloat(@floor(self.analysis_rate / r.high_hz))));
                if (r.low_hz > 0) end = @min(end, @as(usize, @intFromFloat(@ceil(self.analysis_rate / r.low_hz))) + 2);
                if (min_tau + 3 >= end) return null;
            }
            const c = self.cmnd[0..half];
            var tau = min_tau;
            while (tau < end - 1) : (tau += 1) {
                if (c[tau] < dip_threshold and c[tau] < c[tau - 1] and c[tau] <= c[tau + 1]) return tau;
            }
            var best = min_tau;
            for (min_tau + 1..end) |t| {
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

/// The one-euro filter's smoothing factor for a step of `dt` seconds at
/// cutoff `cutoff_hz`: a one-pole low-pass's.
fn smoothingFactor(dt: f64, cutoff_hz: f64) f64 {
    const tau = 1 / (2 * std.math.pi * cutoff_hz);
    return 1 / (1 + tau / dt);
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
            try testing.expect(r.clarity > 0.95);
        }
    }
}

test "reads a sustained stiff string's first partial within 0.05 cent, not a period pulled sharp by its upper partials" {
    const buf = try generate(96000 * 2);
    defer testing.allocator.destroy(buf);
    for (required_rates) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        // Electric-guitar E2, fretted bass B1 and a weak-fundamental E1.
        const strings = [_]signals.StringOptions{
            .{ .f0 = 82.4069, .inharmonicity = 1.1e-4 },
            .{ .f0 = 61.7354, .inharmonicity = 1e-3 },
            .{ .f0 = 41.2034, .inharmonicity = 2e-4, .fundamental_gain = 0.05 },
        };
        for (strings) |opts| {
            const s = buf[0..@intFromFloat(sr * 1.5)];
            signals.pluckedString(s, sr, opts);
            a.reset();
            const r = readAfter(a, s, .{});
            errdefer std.debug.print("{d} Hz B {d} at {d}: {d} c\n", .{ opts.f0, opts.inharmonicity, sr, centsOff(r, opts.firstPartialHz(0)) });
            try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, opts.firstPartialHz(0)), 0.05);
        }
    }
}

test "with a range set, a pluck whose fundamental starts 20 dB under its octave reads its own note from 100 ms" {
    // The Karplus-Strong excitation with this seed leaves 880 Hz's
    // fundamental 20 dB under its octave and its third harmonic weak, so
    // YIN's first dip is at half the period for 0.4 s; without a range the
    // analyser reads the octave until then.
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    signals.pluck(buf, 48000, 880, .{ .amp = 0.9, .t60_s = 3, .seed = 1014 });
    // The high E string, 7 semitones either side of what it is tuned to.
    const settings: Settings = .{ .range = .{ .low_hz = 587.33, .high_hz = 1318.51 } };
    var pos: usize = 0;
    while (pos + 1600 <= buf.len) : (pos += 1600) {
        a.push(buf[pos .. pos + 1600]);
        const r = a.analyse(settings);
        if (pos < 4800) continue;
        errdefer std.debug.print("at {d} s: {d} Hz\n", .{ @as(f64, @floatFromInt(pos + 1600)) / 48000, r.freq_hz });
        try testing.expectEqual(@as(i32, 81), r.note);
    }
}

test "after an onset, a jump of the pitch by an octave is held until three analyses in a row agree" {
    const held = try newAnalyser(48000);
    defer testing.allocator.destroy(held);
    const free = try testing.allocator.create(AnalyserWith(.{ .octave_hold = 0 }));
    defer testing.allocator.destroy(free);
    try free.init(48000);
    // E2, then E3 at the same level: no onset between them.
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    signals.sine(buf[0..24000], 48000, 82.4069, 0.3, 0);
    signals.sine(buf[24000..], 48000, 164.814, 0.3, 0);
    var free_notes: [30]i32 = undefined;
    var held_notes: [30]i32 = undefined;
    for (0..30) |k| {
        const block = buf[k * 1600 .. (k + 1) * 1600];
        free.push(block);
        held.push(block);
        free_notes[k] = free.analyse(.{}).note;
        held_notes[k] = held.analyse(.{}).note;
    }
    const jump = std.mem.indexOfScalar(i32, &free_notes, 52).?;
    try testing.expectEqual(@as(i32, 40), free_notes[jump - 1]);
    try testing.expectEqual(@as(i32, 40), held_notes[jump]);
    try testing.expectEqual(@as(i32, 40), held_notes[jump + 1]);
    for (held_notes[jump + 2 ..]) |n| try testing.expectEqual(@as(i32, 52), n);
}

test "a pitch jump that isn't an octave, a twelfth or two octaves is not held" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    // E2, then A2 at the same level.
    signals.sine(buf[0..24000], 48000, 82.4069, 0.3, 0);
    signals.sine(buf[24000..], 48000, 110, 0.3, 0);
    var first_a2: ?usize = null;
    for (0..30) |k| {
        a.push(buf[k * 1600 .. (k + 1) * 1600]);
        if (a.analyse(.{}).note == 45 and first_a2 == null) first_a2 = k;
    }
    // The window reaches past the change 3 analyses in (92.9 ms); no hold after that.
    try testing.expect(first_a2.? <= 15 + 3);
}

test "after an onset the note shows at once and the cents settle for 120 ms" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    @memset(buf[0..9600], 0);
    signals.pluckedString(buf[9600..], 48000, .{ .f0 = 110, .inharmonicity = 6.5e-5 });
    var first: ?usize = null;
    for (0..30) |k| {
        a.push(buf[k * 1600 .. (k + 1) * 1600]);
        const r = a.analyse(.{});
        if (r.freq_hz == 0) continue;
        if (first == null) first = k;
        try testing.expectEqual(@as(i32, 45), r.note);
        // Ticks are 1/30 s; the pluck is at tick 6.
        const since_ms = (@as(f64, @floatFromInt(k + 1)) - 6) * 1000 / 30;
        errdefer std.debug.print("{d} ms after the onset: {any}\n", .{ since_ms, r });
        if (since_ms < 115) try testing.expect(r.settling);
        if (since_ms > 155) try testing.expect(!r.settling);
    }
    try testing.expect(first.? <= 8);
}

test "a sustained string reads stable within a second and a turning peg never does" {
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    const paths = [_]signals.PitchPath{ .steady, .{ .ramp = .{ .start_cents = -30, .cents_per_s = 5 } } };
    for (paths) |path| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        signals.pluckedString(buf, 48000, .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .t60_s = 10, .pitch = path });
        var stable_at: ?usize = null;
        for (0..60) |k| {
            a.push(buf[k * 1600 .. (k + 1) * 1600]);
            const r = a.analyse(.{});
            if (r.stable and stable_at == null) stable_at = k;
        }
        switch (path) {
            .steady => try testing.expect(stable_at.? < 30),
            else => try testing.expect(stable_at == null),
        }
    }
}

test "the clarity of a clean tone is near 1 and of a noisy one lower" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(24000);
    defer testing.allocator.destroy(buf);
    signals.sine(buf, 48000, 220, 0.3, 0);
    const clean = readAfter(a, buf, .{}).clarity;
    // About 11 dB under the tone inside the 2 kHz low-pass.
    signals.addNoise(buf, 0.2, 9);
    a.reset();
    const noisy = readAfter(a, buf, .{}).clarity;
    try testing.expect(clean > 0.99);
    try testing.expect(noisy < clean - 0.05);
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

test "reads a tone whose fundamental is missing within half a cent at every reading, at every required rate" {
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    for (required_rates) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        for ([_]f64{ 55, 98, 110 }) |f0| {
            const s = buf[0..@intFromFloat(sr)];
            signals.harmonics(s, sr, f0, &.{ 0, 0.3, 0.25, 0.2, 0.15, 0.1 });
            a.reset();
            const tick: usize = @intFromFloat(@round(sr / 30));
            var pos: usize = 0;
            while (pos + tick <= s.len) : (pos += tick) {
                a.push(s[pos .. pos + tick]);
                if (pos < s.len / 3) continue;
                const r = a.analyse(.{});
                errdefer std.debug.print("{d} Hz at {d}, {d} s: {any}\n", .{ f0, sr, @as(f64, @floatFromInt(pos)) / sr, r });
                try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, f0), 0.5);
            }
        }
    }
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
