//! The tuner's pitch analyser: mono samples in, a frequency, note, cents,
//! clarity and settling, stable and multiple flags out, whenever the
//! caller asks (the tuner asks at 30 Hz).
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
//! A note shows only from an onset (an energy jump of 9 dB over the last
//! 10-40 ms; the start of the input is not one, as whatever is sounding
//! then was already sounding), only while the window's level stands 12 dB
//! over a noise floor learned while nothing shows, and only while the
//! latest 40 ms still hold energy within 20 dB of the window's mean.
//! Hum, buzz and noise have no onset and never show; a note decaying into
//! them stops at 12 dB over them instead of reading them or a
//! subharmonic; a muted stroke's tail in the window doesn't show once the
//! string has stopped. Settings.silence_db stays an absolute floor the
//! user can raise, and defaults to -90 dBFS, the lowest the tuner offers.
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
//! tuner-targets`).
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
//! Mains hum a few hertz from a first partial passes the refinement's band
//! and ripples its phase (60 Hz hum 40 dB under fretted B1 moved it by
//! cents). The hum is learned while no note shows (hum.zig: the mains
//! frequency, and each harmonic's amplitude and phase, from up to 0.5 s of
//! idle input; two learns in a row must agree, so a decaying tail is not
//! taken for hum) and taken out of a note's input before its first
//! partial is measured, extrapolated through the note.
//!
//! Two notes together repeat at their common subharmonic, and YIN reads
//! it: E2 and B2 as E1. The spectrum of the input since the onset tells
//! one string from several (several.zig); with several, a reading at no
//! partial of the input (a subharmonic) shows nothing, any other is one of
//! the notes, and either way the reading is flagged `multiple`. The
//! spectrum resolves a subharmonic f's harmonics only 8 / f seconds after
//! the onset (0.19 s for E1), and until then the subharmonic can show.
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
const several = @import("several.zig");
const hum = @import("hum.zig");

/// What the tuner's user sets.
pub const Settings = struct {
    /// A4's frequency. Readings are none unless it is positive and finite;
    /// tuner/setParam holds it to 400-480 Hz.
    reference_hz: f64 = 440,
    /// A window whose input RMS is under this many dBFS is silence, whatever
    /// the noise floor. The gate that matters is the learned noise floor
    /// (`Options.floor_margin_db`); this is an absolute one the user can
    /// raise on a noisy rig, and at its lowest (the default) it lets a note
    /// read for as long as it stands over the floor.
    silence_db: f64 = -90,
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
    /// Several notes are sounding: the reading, if there is one, is one
    /// of them, never a subharmonic common to them (which shows none).
    multiple: bool = false,

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
    /// A note shows only while the window's level stands this many dB over
    /// a noise floor learned while no note shows (it follows the level down
    /// at once and up at `floor_rise_db_per_s`); null for no learned floor.
    floor_margin_db: ?f64 = 12,
    /// Whether a note needs an onset to start showing: hum and noise have
    /// none. A note that stops showing starts again only at a new onset,
    /// unless it dropped out for under `resume_s` with the level still up.
    onset_gate: bool = true,
    /// A note shows only while the latest `release_s` of input holds energy
    /// within this many dB of the window's mean: once a string has stopped
    /// (a muted stroke, a damped note) the window still holds its tail for
    /// 93 ms, but nothing is sounding now. Null for no such check.
    release_drop_db: ?f64 = 20,
    /// Whether a note within `mains_cents` of a harmonic of 50 or 60 Hz
    /// whose level has fallen less than `mains_decay_db` over the last
    /// `mains_hold_s` stops showing, as mains hum or buzz. Off: hum and
    /// buzz have no onset, so the onset gate already keeps them from
    /// showing, and a note held at a steady level near a mains harmonic
    /// (E5 is 2 cents under 11 x 60 Hz, C6 6 cents under 21 x 50 Hz; a
    /// compressor or sustainer holds a string's level) would vanish after
    /// a second. It catches only buzz that switches on.
    mains_rule: bool = false,
    /// Whether the spectrum of the input since the onset is checked for
    /// several notes (see several.zig).
    several_guard: bool = true,
    /// Whether stationary mains hum is learned while no note shows and
    /// taken out of a note's input before its first partial is measured
    /// (see hum.zig).
    hum_model: bool = true,
};

/// The hum is learned every `hum_hop_s` from the idle input since the
/// last onset, at least `hum_learn_min_s` and at most `hum_learn_max_s` of
/// it (the longer, the more exactly the mains frequency is known, and the
/// further its phase can be carried through a note).
const hum_learn_min_s = 0.15;
const hum_learn_max_s = 0.5;
const hum_hop_s = 0.05;
/// Once two learns agree, the hum is learned again only this often.
const hum_relearn_s = 0.25;

const floor_rise_db_per_s = 20.0;
const resume_s = 0.25;
/// Longer than B0's period, so a low note's waveform doesn't swing it.
const release_s = 0.04;
const onset_floor_hold_s = 0.25;
/// An onset starts a note only within this long of the first analysis
/// that saw it.
const onset_life_s = 0.25;
const mains_cents = 15.0;
const mains_decay_db = 1.0;
const mains_hold_s = 1.0;
/// Window levels kept for the mains rule (a little over 2 s at 30 Hz).
const level_history_len = 72;

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
    const fine_needed = options.refinement != null or options.onset_gate or options.several_guard;
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
        /// Full blocks since the reset (onsets are looked for only once the
        /// blocks before one are input, not the reset's silence), and onsets
        /// in all.
        blocks_seen: usize,
        onset_count: u64,
        segment: [max_fine]f64,
        segment_len: usize,
        windowed: [if (options.several_guard or options.hum_model) max_fft else 1]f64,
        spectrum: [if (options.several_guard or options.hum_model) max_fft / 2 + 1 else 1]f64,
        hum_window: [if (options.hum_model) max_fft else 1]f64,
        several_scratch: several.Scratch,
        /// Whether the last analysis heard several notes.
        heard_several: bool,
        /// The learned hum: the model in use (if `hum_valid`), the last
        /// learned (two in a row must agree), and the fine input it was
        /// learned at.
        hum_now: hum.Model,
        hum_valid: bool,
        hum_last: ?hum.Model,
        hum_learned_at: u64,
        refine_work: first_partial.Work(max_fine_period),

        /// Analysed samples kept in all.
        kept_count: u64,
        /// The octave hold: whether it holds a frequency (or only has one
        /// waiting for a second analysis to agree), log2 of it, the onset
        /// it was set after, the jump waiting for agreement and how many
        /// analyses in a row have made it, and the last analysis's input
        /// and factor.
        hold_set: bool,
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

        /// The gate: the input it last decided at and its decision, the
        /// learned floor (dBFS, NaN before any input), whether a note is
        /// showing, the onset that started it and when, when it stopped and
        /// whether it may resume, and the window levels of recent analyses.
        gate_at: u64,
        gate_open: bool,
        floor_db: f64,
        /// Floor learning stops at an onset until the gate has decided on it.
        floor_paused: bool,
        /// The window's input energy, kept as a running sum, and the kept
        /// samples to the next floor update.
        window_energy: f64,
        floor_countdown: usize,
        note_active: bool,
        note_onset_count: u64,
        note_start: f64,
        note_end: f64,
        note_may_resume: bool,
        level_t: [level_history_len]f64,
        level_v: [level_history_len]f64,
        level_pos: usize,
        level_used: usize,
        /// The last onset the gate has seen, and when it first saw it.
        onset_seen: u64,
        onset_seen_at: f64,

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
            self.heard_several = false;
            self.hum_now = .{};
            self.hum_valid = false;
            self.hum_last = null;
            self.hum_learned_at = 0;
            self.kept_count = 0;
            self.hold_set = false;
            self.hold_log2 = 0;
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
            self.blocks_seen = 0;
            self.onset_count = 0;
            self.gate_at = std.math.maxInt(u64);
            self.gate_open = false;
            self.floor_db = std.math.nan(f64);
            self.floor_paused = false;
            self.window_energy = 0;
            self.floor_countdown = 0;
            self.note_active = false;
            self.note_onset_count = 0;
            self.note_start = 0;
            self.note_end = -std.math.inf(f64);
            self.note_may_resume = false;
            self.level_pos = 0;
            self.level_used = 0;
            self.onset_seen = 0;
            self.onset_seen_at = 0;
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
                    self.window_energy += self.energy_acc - self.energy[self.write_pos];
                    self.energy[self.write_pos] = self.energy_acc;
                    self.energy_acc = 0;
                    self.write_pos += 1;
                    if (self.write_pos == self.window) self.write_pos = 0;
                    self.kept_count += 1;
                    if (fine_needed) self.pushFine(y);
                    if (options.floor_margin_db != null) self.learnFloor();
                }
            }
        }

        /// Every 5 ms of kept input while no note shows, moves the floor to
        /// the window's level if lower, or up towards it at
        /// `floor_rise_db_per_s`; the first full window sets it.
        fn learnFloor(self: *Self) void {
            if (self.floor_countdown > 0) {
                self.floor_countdown -= 1;
                return;
            }
            const step_s = 0.005;
            self.floor_countdown = @intFromFloat(@round(step_s * self.analysis_rate));
            if (self.kept_count % 8192 == 0) {
                // Re-sum, so the running sum's rounding can't drift.
                var e: f64 = 0;
                for (self.energy[0..self.window]) |v| e += v;
                self.window_energy = e;
            }
            if (self.note_active or self.floor_paused) return;
            // While a note that dropped out may still resume, the input is
            // that note, not the floor.
            const now = @as(f64, @floatFromInt(self.kept_count)) / self.analysis_rate;
            if (self.note_may_resume and now - self.note_end < resume_s) return;
            // A window not yet full of input reads low.
            if (self.kept_count < self.window) return;
            const level = self.windowLevelDb();
            self.floor_db = if (std.math.isNan(self.floor_db)) level else @min(level, self.floor_db + floor_rise_db_per_s * step_s);
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
            const heard = self.blocks_seen >= onset_history;
            if (heard and self.block_energy > onset_ratio * before and self.block_energy > 0 and (self.onset_count == 0 or since_last >= refractory)) {
                self.onset_at = self.fine_count - self.block_len;
                self.onset_count += 1;
                self.floor_paused = true;
            }
            self.blocks_seen += 1;
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

        /// The several-notes verdict on the loaded segment's spectrum
        /// (Blackman-Harris, its latest power of two at most) for partials
        /// `spacing_hz` apart, or null with the guard off.
        fn judgeSeveral(self: *Self, spacing_hz: f64) ?several.Judgement {
            if (!options.several_guard or self.segment_len < 16) return null;
            var n_fft = std.math.ceilPowerOfTwo(usize, self.segment_len) catch unreachable;
            n_fft = @min(n_fft, max_fft);
            const len = @min(self.segment_len, n_fft);
            const seg = self.segment[self.segment_len - len .. self.segment_len];
            for (self.windowed[0..len], seg, 0..) |*d, v, i| d.* = v * several.blackmanHarris(i, len);
            self.fft.powerSpectrum(self.windowed[0..len], n_fft, &self.fft_work, self.spectrum[0 .. n_fft / 2 + 1]);
            const sp: several.Spectrum = .{
                .power = self.spectrum[0 .. n_fft / 2 + 1],
                .bin_hz = self.fine_rate / @as(f64, @floatFromInt(n_fft)),
                .length_s = @as(f64, @floatFromInt(len)) / self.fine_rate,
            };
            return several.judge(sp, 25, max_pitch_hz, spacing_hz, &self.several_scratch);
        }

        /// `f`, unless it is 2, 3 or 4 times (or a half, third or quarter
        /// of) the frequency held since the onset, in which case the held
        /// one, until `octave_hold` analyses in a row have made the jump.
        /// The hold takes hold once two analyses after the onset agree.
        fn holdOctave(self: *Self, f: f64) f64 {
            if (options.octave_hold == 0) return f;
            // Without new input, the same decision as last time.
            if (self.kept_count == self.hold_at) return f / self.hold_factor;
            self.hold_at = self.kept_count;
            self.hold_factor = 1;
            const lf = @log2(f);
            const quarter_tone = 1.0 / 24.0;
            if (self.onset_at != self.hold_onset) {
                self.hold_onset = self.onset_at;
                self.hold_set = false;
                self.hold_log2 = lf;
                self.hold_count = 0;
                return f;
            }
            // The hold anchors once two analyses in a row agree: the first
            // after an onset is the least sure (over a ringing note it can be
            // the two notes' common subharmonic).
            if (!self.hold_set) {
                self.hold_set = @abs(lf - self.hold_log2) <= quarter_tone;
                self.hold_log2 = lf;
                return f;
            }
            const jumps = [_]f64{ 2, 3, 4, 0.5, 1.0 / 3.0, 0.25 };
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

        /// The input sample (counted from `init` or `reset`) where the last
        /// onset began, to within a 5 ms block; null before the first.
        pub fn lastOnset(self: *const Self) ?u64 {
            if (self.onset_count == 0) return null;
            return self.onset_at * self.fine_decimation * self.decimation;
        }

        /// The pitch of the last 92.9 ms of input.
        pub fn analyse(self: *Self, settings: Settings) Reading {
            if (!(settings.reference_hz > 0 and std.math.isFinite(settings.reference_hz))) return Reading.none;
            const level = self.windowLevelDb();
            self.heard_several = false;
            const measured = if (level < settings.silence_db) null else self.measure(settings);
            const shown = self.track(self.gate(measured, level, settings)) orelse {
                var r = Reading.none;
                r.multiple = self.heard_several;
                return r;
            };
            const midi = 69 + 12 * @log2(shown.hz / settings.reference_hz);
            const note = @floor(midi + 0.5);
            return .{
                .freq_hz = shown.hz,
                .note = @intFromFloat(note),
                .cents = (midi - note) * 100,
                .clarity = shown.clarity,
                .settling = shown.settling,
                .stable = shown.stable,
                .multiple = self.heard_several,
            };
        }

        const Measured = struct { hz: f64, clarity: f64 };

        /// The first partial's frequency now, unsmoothed, or null for no pitch.
        fn measure(self: *Self, settings: Settings) ?Measured {
            self.difference();
            const best = self.pickPeriod(settings.range) orelse return null;
            const detected = self.analysis_rate / self.interpolate(best);
            if (fine_needed) self.loadSegment();
            const coarse = self.holdOctave(detected);
            if (options.hum_model and self.hum_valid and fine_needed) {
                // Out of the band the refinement passes, about the note.
                self.hum_now.subtract(self.segment[0..self.segment_len], self.fine_count - self.segment_len, self.fine_rate, 0, 2 * coarse);
            }
            // Of several notes, only one of them shows, never what repeats
            // under them all.
            if (self.judgeSeveral(coarse)) |j| {
                if (j.verdict == .several) {
                    self.heard_several = true;
                    if (!j.heard(coarse)) return null;
                }
            }
            return .{ .hz = self.combine(coarse), .clarity = std.math.clamp(1 - self.cmnd[best], 0, 1) };
        }

        /// The RMS of the window's input (before the low-pass), dBFS.
        fn windowLevelDb(self: *const Self) f64 {
            const rms = @sqrt(@max(0, self.window_energy) / @as(f64, @floatFromInt(self.window * self.decimation)));
            return 20 * std.math.log10(@max(rms, 1e-7));
        }

        /// `m` if a note may show: over the learned floor, started at an
        /// onset, still sounding, and not mains hum. Decides only with
        /// new input.
        fn gate(self: *Self, m: ?Measured, level: f64, settings: Settings) ?Measured {
            if (self.kept_count == self.gate_at) return if (self.gate_open) m else null;
            self.gate_at = self.kept_count;
            const now = @as(f64, @floatFromInt(self.kept_count)) / self.analysis_rate;
            self.level_t[self.level_pos] = now;
            self.level_v[self.level_pos] = level;
            self.level_pos = (self.level_pos + 1) % level_history_len;
            self.level_used = @min(self.level_used + 1, level_history_len);
            // Every analysis sees a new onset, pitched or not.
            const fresh_onset = self.onsetFresh(now);

            const loud = if (options.floor_margin_db) |margin| std.math.isNan(self.floor_db) or level >= self.floor_db + margin else true;
            const pitched = m != null and level >= settings.silence_db;
            if (self.note_active) {
                const keep = pitched and loud and self.sounding() and !self.mainsHeld(m.?.hz, now);
                if (!keep) {
                    self.note_active = false;
                    self.note_end = now;
                    // Only a moment without a pitch, the level still up, may
                    // resume without a new onset.
                    self.note_may_resume = !pitched and loud;
                }
            } else if (pitched and loud and self.sounding()) {
                const resuming = self.note_may_resume and now - self.note_end < resume_s and self.onset_count == self.note_onset_count;
                if (!options.onset_gate or fresh_onset or resuming) {
                    if (!resuming) self.note_start = now;
                    self.note_active = true;
                    self.note_onset_count = self.onset_count;
                }
            }
            self.gate_open = self.note_active;
            if (!self.note_active) self.learnHum();
            // An onset holds the floor until a note it started has ended, or
            // for `onset_floor_hold_s` if none shows (the window takes a while
            // to fill with a new note).
            if (!self.note_active and self.floor_paused) {
                const since_onset = @as(f64, @floatFromInt(self.fine_count - self.onset_at)) / self.fine_rate;
                if (self.note_onset_count == self.onset_count or since_onset >= onset_floor_hold_s) self.floor_paused = false;
            }
            return if (self.note_active) m else null;
        }

        /// Every `hum_hop_s` of idle input (`hum_relearn_s` once two have
        /// agreed), learns the hum from the input since the last onset
        /// (between `hum_learn_min_s` and `hum_learn_max_s` of it); two
        /// learns in a row that agree make the model used.
        fn learnHum(self: *Self) void {
            if (!options.hum_model or !fine_needed) return;
            const hop: f64 = if (self.hum_valid) hum_relearn_s else hum_hop_s;
            if (@as(f64, @floatFromInt(self.fine_count - self.hum_learned_at)) < hop * self.fine_rate) return;
            const idle: u64 = if (self.onset_count > 0) self.fine_count - self.onset_at else self.fine_count;
            const most: u64 = @min(@as(u64, @intFromFloat(hum_learn_max_s * self.fine_rate)), @min(max_fine, max_fft));
            const n: usize = @intCast(@min(idle, most));
            if (@as(f64, @floatFromInt(n)) < hum_learn_min_s * self.fine_rate) return;
            self.hum_learned_at = self.fine_count;
            const start = self.fine_count - n;
            for (self.segment[0..n], 0..) |*d, i| d.* = self.fine[@intCast((start + i) % max_fine)];
            // Its Hann power spectrum, for the learner to choose by.
            const n_fft = std.math.ceilPowerOfTwo(usize, n) catch unreachable;
            const denom: f64 = @floatFromInt(n - 1);
            @memset(self.windowed[0..n_fft], 0);
            for (self.windowed[0..n], self.segment[0..n], 0..) |*d, v, i| d.* = v * (0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / denom));
            self.fft.powerSpectrum(self.windowed[0..n_fft], n_fft, &self.fft_work, self.spectrum[0 .. n_fft / 2 + 1]);
            const sp: hum.Spectrum = .{ .power = self.spectrum[0 .. n_fft / 2 + 1], .bin_hz = self.fine_rate / @as(f64, @floatFromInt(n_fft)) };
            const learned = hum.learn(max_fine_period, &self.refine_work, self.segment[0..n], start, self.fine_rate, sp, self.hum_window[0..n]);
            if (learned) |m| {
                self.hum_valid = if (self.hum_last) |last| last.agrees(m) else false;
                if (self.hum_valid) self.hum_now = m;
            } else self.hum_valid = false;
            self.hum_last = learned;
        }

        /// Whether the last onset may still start a note: it is newer than
        /// the note last shown, and the first analysis to see it was under
        /// `onset_life_s` ago. One that opened nothing (a click, a pick
        /// scrape) must not let a later sound show without an onset of its
        /// own; counting from the first analysis to see it gives a caller
        /// that analyses seldom its chance.
        fn onsetFresh(self: *Self, now: f64) bool {
            if (self.onset_count <= self.note_onset_count) return false;
            if (self.onset_seen != self.onset_count) {
                self.onset_seen = self.onset_count;
                self.onset_seen_at = now;
            }
            return now - self.onset_seen_at <= onset_life_s;
        }

        /// Whether the latest `release_s` of input holds energy within
        /// `release_drop_db` of the window's mean.
        fn sounding(self: *const Self) bool {
            const drop = options.release_drop_db orelse return true;
            const n: usize = @intFromFloat(@round(release_s * self.analysis_rate));
            var recent: f64 = 0;
            for (0..n) |k| recent += self.energy[(self.write_pos + self.window - 1 - k) % self.window];
            const recent_mean = recent / @as(f64, @floatFromInt(n));
            const window_mean = @max(0, self.window_energy) / @as(f64, @floatFromInt(self.window));
            return recent_mean >= window_mean * std.math.pow(f64, 10, -drop / 10);
        }

        /// Whether `hz` is within `mains_cents` of a harmonic of 50 or 60
        /// Hz and the level has fallen less than `mains_decay_db` over the
        /// last `mains_hold_s`, measured from a window wholly inside the
        /// note.
        fn mainsHeld(self: *const Self, hz: f64, now: f64) bool {
            if (!options.mains_rule or now - self.note_start < mains_hold_s) return false;
            var near = false;
            for ([_]f64{ 50, 60 }) |base| {
                const k = @round(hz / base);
                if (k >= 1 and @abs(1200 * @log2(hz / (k * base))) <= mains_cents) near = true;
            }
            if (!near) return false;
            const latest = self.level_v[(self.level_pos + level_history_len - 1) % level_history_len];
            for (0..self.level_used) |back| {
                const i = (self.level_pos + level_history_len - 1 - back) % level_history_len;
                if (self.level_t[i] > now - mains_hold_s) continue;
                // Only a window wholly inside the note gives its level.
                if (self.level_t[i] < self.note_start + window_seconds) return false;
                return self.level_v[i] - latest < mains_decay_db;
            }
            return false;
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

/// A new analyser that has heard 50 ms of silence, so a tone pushed next
/// starts at an onset: the start of the input is not one.
fn newAnalyser(sample_rate: f64) !*Analyser {
    const a = try testing.allocator.create(Analyser);
    errdefer testing.allocator.destroy(a);
    try a.init(sample_rate);
    prime(a);
    return a;
}

fn prime(a: anytype) void {
    const zeros = [_]f32{0} ** 256;
    var left: usize = @intFromFloat(0.05 * a.sample_rate);
    while (left > 0) {
        const n = @min(left, zeros.len);
        a.push(zeros[0..n]);
        left -= n;
    }
}

/// A new analyser that has heard nothing: whatever is pushed first was
/// already sounding, with no onset.
fn bareAnalyser(sample_rate: f64) !*Analyser {
    const a = try testing.allocator.create(Analyser);
    errdefer testing.allocator.destroy(a);
    try a.init(sample_rate);
    return a;
}

/// `reset`, then 50 ms of silence.
fn restart(a: anytype) void {
    a.reset();
    prime(a);
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
            restart(a);
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
            restart(a);
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
    prime(free);
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

test "a new note over a ringing one is not held back when the first reading after its onset is their common subharmonic" {
    // E4 drops to -12 dB as B3 is plucked; 33 ms on, YIN reads their common
    // subharmonic (82.3 Hz, a 4:3 pair's), then B3. B3 is 3 times the
    // first reading, but nothing should hold it back for that.
    const a = try testing.allocator.create(Analyser);
    defer testing.allocator.destroy(a);
    try a.init(44100);
    const buf = try generate(44100 * 2);
    defer testing.allocator.destroy(buf);
    const other = try generate(44100 * 2);
    defer testing.allocator.destroy(other);
    const lead = 4410;
    const change = lead + 22050;
    @memset(buf[0..lead], 0);
    signals.pluck(buf[lead..], 44100, 329.628, .{ .t60_s = 3, .seed = 502 });
    for (buf[change..]) |*v| v.* *= 0.25;
    signals.pluck(other[0 .. buf.len - change], 44100, 246.942, .{ .t60_s = 3, .seed = 602 });
    signals.mix(buf[change..], other[0 .. buf.len - change]);
    // Readings every 1470 samples from the end of the lead; reading 14
    // ends at the change.
    var locked_at: ?usize = null;
    var k: usize = 0;
    a.push(buf[0..lead]);
    while (lead + (k + 1) * 1470 <= buf.len) : (k += 1) {
        a.push(buf[lead + k * 1470 .. lead + (k + 1) * 1470]);
        const r = a.analyse(.{});
        if (lead + (k + 1) * 1470 <= change) continue;
        const ok = r.freq_hz > 0 and @abs(centsOff(r, 246.942)) <= 5;
        if (ok) {
            if (locked_at == null) locked_at = k;
        } else locked_at = null;
    }
    // Locked from the second reading after the change, 67 ms on.
    try testing.expect(locked_at.? <= 16);
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
    restart(a);
    const noisy = readAfter(a, buf, .{}).clarity;
    try testing.expect(clean > 0.99);
    try testing.expect(noisy < clean - 0.05);
}

/// Pushes `signal` in 1/30 s blocks and returns how many analyses showed a
/// note from `from_s` on, and how many of those were not `note`.
fn countNotes(a: anytype, signal: []const f32, sample_rate: f64, from_s: f64, note: ?i32) struct { shown: usize, other: usize } {
    const tick: usize = @intFromFloat(@round(sample_rate / 30));
    var shown: usize = 0;
    var other: usize = 0;
    var pos: usize = 0;
    while (pos + tick <= signal.len) : (pos += tick) {
        a.push(signal[pos .. pos + tick]);
        const r = a.analyse(.{});
        if (@as(f64, @floatFromInt(pos + tick)) / sample_rate < from_s or r.freq_hz == 0) continue;
        shown += 1;
        if (note == null or r.note != note.?) other += 1;
    }
    return .{ .shown = shown, .other = other };
}

test "a note keeps reading while it is 12 dB over the noise floor, under the old -60 dBFS gate" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 3);
    defer testing.allocator.destroy(buf);
    @memset(buf[0..12000], 0);
    // About -50 dBFS RMS at the pluck, -64 two seconds on, over a -90 dBFS floor.
    signals.pluckedString(buf[12000..], 48000, .{ .f0 = 110, .inharmonicity = 6.5e-5, .peak = 0.03 });
    signals.addNoise(buf, std.math.pow(f64, 10, -90.0 / 20.0), 5);
    const late = countNotes(a, buf, 48000, 2.25, 45);
    try testing.expect(late.shown >= 20);
    try testing.expectEqual(@as(usize, 0), late.other);
}

test "hum and buzz with no onset never read as a note" {
    const buf = try generate(48000 * 2);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 50, 60 }) |hz| {
        for ([_]signals.Mains{ .hum, .buzz }) |kind| {
            const a = try bareAnalyser(48000);
            defer testing.allocator.destroy(a);
            signals.mains(buf, 48000, hz, kind, -30);
            signals.addNoise(buf, 3e-5, 6);
            try testing.expectEqual(@as(usize, 0), countNotes(a, buf, 48000, 0, null).shown);
        }
    }
}

test "a note decaying into hum stops reading instead of reading the hum or a subharmonic" {
    const a = try bareAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 4);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 4);
    defer testing.allocator.destroy(other);
    @memset(buf, 0);
    signals.pluckedString(buf[48000..], 48000, .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .t60_s = 3 });
    signals.mains(other, 48000, 50, .buzz, -50);
    signals.mix(buf, other);
    // E2 shows until it is within 12 dB of the buzz, about a second.
    const r = countNotes(a, buf, 48000, 1.1, 40);
    try testing.expect(r.shown > 20);
    try testing.expectEqual(@as(usize, 0), r.other);
}

test "fretting-hand-muted strokes read no note" {
    const buf = try generate(48000 * 3);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 41.2034, 82.4069, 110, 196 }) |hz| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        @memset(buf, 0);
        for (0..4) |k| signals.mutedString(buf[12000 + k * 30011 ..], 48000, hz, 0.03, 0.5, 3 + k);
        signals.addNoise(buf, 3e-5, 7);
        errdefer std.debug.print("{d} Hz\n", .{hz});
        try testing.expectEqual(@as(usize, 0), countNotes(a, buf, 48000, 0, null).shown);
    }
}

test "with the mains rule, buzz that switches on stops reading once it has held its level for a second" {
    const a = try testing.allocator.create(AnalyserWith(.{ .mains_rule = true }));
    defer testing.allocator.destroy(a);
    try a.init(48000);
    prime(a);
    const buf = try generate(48000 * 3);
    defer testing.allocator.destroy(buf);
    @memset(buf[0..24000], 0);
    signals.mains(buf[24000..], 48000, 60, .buzz, -30);
    signals.addNoise(buf, 3e-5, 8);
    // On at 0.5 s; the level is judged from the first window wholly inside
    // it (93 ms on) over the next second, so nothing from 1.75 s.
    try testing.expectEqual(@as(usize, 0), countNotes(a, buf, 48000, 1.75, null).shown);
}

test "two strings at once read as no confident subharmonic once the spectrum resolves their common one" {
    // The guard needs 8 / f seconds of input to resolve the harmonics of a
    // subharmonic f (a Blackman-Harris main lobe two half-widths clear);
    // before that a period detector's subharmonic can still show.
    const buf = try generate(48000 * 2);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 2);
    defer testing.allocator.destroy(other);
    // Each pair and the common subharmonic YIN reads for it.
    const pairs = [_][3]f64{ .{ 82.4069, 123.471, 41.2 }, .{ 110, 146.832, 36.7 }, .{ 195.998, 246.942, 49 }, .{ 82.4069, 116.541, 38.9 }, .{ 55, 82.4069, 27.5 } };
    for (pairs) |p| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        signals.pluckedString(buf, 48000, .{ .f0 = p[0], .inharmonicity = 1e-4, .peak = 0.35 });
        signals.pluckedString(other, 48000, .{ .f0 = p[1], .inharmonicity = 1e-4, .peak = 0.35, .seed = 2 });
        signals.mix(buf, other);
        const lower: i32 = @intFromFloat(@round(69 + 12 * @log2(p[0] / 440)));
        var multiple: usize = 0;
        var k: usize = 0;
        while ((k + 1) * 1600 <= buf.len) : (k += 1) {
            a.push(buf[k * 1600 .. (k + 1) * 1600]);
            const r = a.analyse(.{});
            if (r.multiple) multiple += 1;
            if (@as(f64, @floatFromInt(k + 1)) / 30 < 8 / p[2]) continue;
            errdefer std.debug.print("{d} + {d} Hz, reading {d}: {any}\n", .{ p[0], p[1], k, r });
            if (r.freq_hz > 0 and !r.multiple) try testing.expect(r.note >= lower - 1);
        }
        try testing.expect(multiple > 0);
    }
}

test "a bass string over mains hum a few hertz from its fundamental reads within half a cent from 1 s" {
    // Fretted bass B1 is 1.8 Hz over 60 Hz, A1 5 Hz over 50 Hz; the hum is
    // there from the start, 40 dB under the note.
    const buf = try generate(48000 * 3);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 3);
    defer testing.allocator.destroy(other);
    for ([_][3]f64{ .{ 61.7354, 1e-3, 60 }, .{ 55, 2e-4, 50 } }) |c| {
        for ([_]signals.Mains{ .hum, .buzz }) |kind| {
            const a = try bareAnalyser(48000);
            defer testing.allocator.destroy(a);
            const opts: signals.StringOptions = .{ .f0 = c[0], .inharmonicity = c[1], .t60_s = 8 };
            @memset(buf[0..24000], 0);
            signals.pluckedString(buf[24000..], 48000, opts);
            const note_db = 20 * std.math.log10(signals.rms(buf[24000..72000]));
            signals.mains(other, 48000, c[2], kind, note_db - 40);
            signals.mix(buf, other);
            signals.addNoise(buf, 3e-5, 11);
            var k: usize = 0;
            var shown: usize = 0;
            while ((k + 1) * 1600 <= buf.len) : (k += 1) {
                a.push(buf[k * 1600 .. (k + 1) * 1600]);
                const r = a.analyse(.{});
                const t = @as(f64, @floatFromInt((k + 1) * 1600)) / 48000 - 0.5;
                if (t < 1 or r.freq_hz == 0) continue;
                shown += 1;
                errdefer std.debug.print("{d} Hz over {d} Hz {s}, {d:.2} s: {d:.3} c\n", .{ c[0], c[2], @tagName(kind), t, centsOff(r, opts.firstPartialHz(t)) });
                try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, opts.firstPartialHz(t)), 0.5);
            }
            try testing.expect(shown > 20);
        }
    }
}

test "a note on a mains harmonic reads true, over buzz and after its own tail" {
    // E5 is 2 cents under 11 x 60 Hz. Over buzz, the hum taken out is the
    // buzz's 660 Hz alone; with no hum, a first E5's decaying tail must not
    // be learned as hum and taken out of the second.
    const buf = try generate(48000 * 4);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 4);
    defer testing.allocator.destroy(other);
    const opts: signals.StringOptions = .{ .f0 = 659.255, .inharmonicity = 4.4e-5 };
    for ([_]bool{ true, false }) |with_buzz| {
        const a = try bareAnalyser(48000);
        defer testing.allocator.destroy(a);
        @memset(buf, 0);
        signals.pluckedString(buf[24000..96000], 48000, opts);
        signals.pluckedString(buf[120000..], 48000, opts);
        if (with_buzz) {
            signals.mains(other, 48000, 60, .buzz, -60);
            signals.mix(buf, other);
        }
        signals.addNoise(buf, 3e-5, 12);
        var k: usize = 0;
        var shown: usize = 0;
        while ((k + 1) * 1600 <= buf.len) : (k += 1) {
            a.push(buf[k * 1600 .. (k + 1) * 1600]);
            const r = a.analyse(.{});
            const t = @as(f64, @floatFromInt((k + 1) * 1600)) / 48000;
            const since = if (t >= 2.5) t - 2.5 else t - 0.5;
            // The first E5 is cut off at 2 s; its readings count until then.
            if (since < 0.5 or (t < 2.5 and t > 1.9) or r.freq_hz == 0 or r.settling) continue;
            shown += 1;
            errdefer std.debug.print("buzz {}, {d:.2} s: {d:.3} c\n", .{ with_buzz, t, centsOff(r, opts.firstPartialHz(since)) });
            try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, opts.firstPartialHz(since)), 0.1);
        }
        try testing.expect(shown > 40);
    }
}

test "reports where the last onset was, in input samples, within a 5 ms block" {
    for ([_]f64{ 44100, 96000 }) |sr| {
        const a = try bareAnalyser(sr);
        defer testing.allocator.destroy(a);
        const buf = try generate(96000);
        defer testing.allocator.destroy(buf);
        const at: usize = @intFromFloat(0.3 * sr);
        @memset(buf[0..at], 0);
        signals.pluckedString(buf[at..@intFromFloat(sr)], sr, .{ .f0 = 110, .inharmonicity = 6.5e-5 });
        a.push(buf[0..at]);
        try testing.expect(a.lastOnset() == null);
        a.push(buf[at..@intFromFloat(sr)]);
        const got = a.lastOnset().?;
        errdefer std.debug.print("{d}: onset at {d}, plucked at {d}\n", .{ sr, got, at });
        try testing.expect(@abs(@as(f64, @floatFromInt(got)) - @as(f64, @floatFromInt(at))) <= 0.005 * sr + 4);
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
            restart(a);
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
            restart(a);
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
    restart(a);
    const with = readAfter(a, buf, .{});
    try testing.expect(without.freq_hz > 0);
    try testing.expectApproxEqAbs(@as(f64, 0), signals.cents(with.freq_hz, without.freq_hz), 0.001);
}

test "a low tone with a DC offset reads at every analysis" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(72000);
    defer testing.allocator.destroy(buf);
    signals.sawtooth(buf, 48000, 41.2034, 0.3);
    signals.addDc(buf, 0.3);
    var pos: usize = 0;
    while (pos + 1600 <= buf.len) : (pos += 1600) {
        a.push(buf[pos .. pos + 1600]);
        const r = a.analyse(.{});
        if (pos < 9600) continue;
        errdefer std.debug.print("at {d} s: {any}\n", .{ @as(f64, @floatFromInt(pos + 1600)) / 48000, r });
        try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, 41.2034), 1);
    }
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
    restart(a);
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
    // 196 Hz at -66 dBFS RMS, each time from an onset: under -60, over -70.
    signals.sine(buf, 44100, 196, 0.0007, 0);
    restart(a);
    try testing.expectEqual(Reading.none, readAfter(a, buf, .{ .silence_db = -60 }));
    restart(a);
    try testing.expect(readAfter(a, buf, .{ .silence_db = -70 }).freq_hz > 0);
}

test "an onset that shows no note expires, so a swell over hum long after a click never shows" {
    const a = try bareAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 4);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 4);
    defer testing.allocator.destroy(other);
    // Hum throughout; a 5 ms click at 0.5 s; A2 swelling in at 60 dB a
    // second from 2.5 s, which has no onset of its own.
    signals.mains(buf, 48000, 50, .hum, -50);
    var rng = signals.MinStd.init(9);
    for (buf[24000..24240]) |*v| v.* += @floatCast(0.3 * rng.next());
    @memset(other, 0);
    signals.pluckedString(other[120000..], 48000, .{ .f0 = 110, .inharmonicity = 6.5e-5, .t60_s = 20 });
    for (other[120000..], 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / 48000;
        v.* *= @floatCast(@min(1, std.math.pow(f64, 10, 3 * (t - 1))));
    }
    signals.mix(buf, other);
    try testing.expectEqual(@as(usize, 0), countNotes(a, buf, 48000, 2.5, null).shown);
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
            restart(a);
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
