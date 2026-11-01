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
//! 10-40 ms; or with nothing showing the window's level rising 12 dB over
//! its lowest of the last 2 s, as a swell, volume pedal, e-bow or bow
//! does; or while a note shows, the same jump in what isn't that note,
//! the input less itself a period earlier, as when another string is
//! plucked over it, whose note is then measured with the ringing one
//! taken out the same way; the start of the input is not one, as whatever is sounding then
//! was already sounding), only while the window's level stands 12 dB
//! over a noise floor learned while nothing shows, and only while the
//! latest 40 ms still hold energy within 20 dB of the window's mean.
//! Steady hum, buzz and noise have no onset and never show. Hum and buzz
//! that switch on do have one, so a note reading near 50 or 60 Hz times 1
//! to 4 whose input since its onset repeats at the mains period waits to
//! start until its level is seen to fall, as a string's does and theirs
//! doesn't. A note decaying into
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
//! The note shows from the first reading whose window lies wholly after
//! the onset (93 ms); the reading is
//! `settling` for 120 ms (a string's attack, about half its glide's time
//! constant), and `stable` once the shown pitch's slope over 300 ms is
//! under 0.5 cent a second.
//!
//! Targets on `zig build tuner-targets` not met:
//! - strings whose two polarisations beat read 0.51 cent off the stronger
//!   one's f1 at P95 (target 0.5): they follow the sum of both, whose
//!   frequency moves as the weaker decays, within 0.05 cent;
//! - jitter 0.18 cent (target 0.1), from those strings' slow drift;
//! - 72 confident subharmonics of two notes, all within 8 / f of the
//!   onset, before the spectrum can resolve the subharmonic f;
//! - hum that changes during a note: P95 1.43 cent (target 0.5) when its
//!   level steps, its phase jumps, a pickup is switched or the mains
//!   drifts 20 mHz a second (the learned hum is carried through the note
//!   unchanged; drift of 2-5 mHz a second is mostly within 0.5 cent),
//!   with 16 octave readings and 492 readings flagged several;
//! - 6 single-string readings flagged several, weak-fundamental strings
//!   early on;
//! - lock-on 116.7 ms on average and at worst (targets 42.7 and 83.4): a
//!   note shows no name until the window is past its onset, by the
//!   owner's choice, because through a piezo the body modes otherwise
//!   flash the octave under in 16 of 48 notes;
//! - under a string ringing in sympathy 15-30 dB down, 12% of readings
//!   from 1 s are not shown and one signal averages -4.9 cent (targets:
//!   P95 0.5 counting unshown readings, bias 0.2): the first partial
//!   wanders up to 2 cents with another note a quarter of its frequency
//!   away, and the sympathetic string outlasts the note in those cases.
//!
//! Every tuned threshold and constant, with its unit and how the bench
//! answers when it moves, is in thresholds.zig.
//!
//! The window is analysed only when `analyse` is called, not every hop.
//! Nothing is allocated after `init`: the caller owns the `Analyser`
//! (about 670 KB, so not on the stack) and calls `push` and `analyse` from
//! one thread, not the audio thread.
const std = @import("std");
const fft_mod = @import("fft.zig");
const first_partial = @import("first_partial.zig");
const several = @import("several.zig");
const hum = @import("hum.zig");
const th = @import("thresholds.zig");

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
    /// tuner's whole range. A limit beyond the analyser's own range is
    /// clamped to it, one that isn't a positive number is ignored, and a
    /// range with nothing in it reads no pitch.
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
    /// A note has started (an onset was taken, the input is pitched and
    /// over the floor) but its name is held back until the window lies
    /// wholly after the onset, about 93 ms (`Options.names_after_window`).
    /// `freq_hz` is 0 then, as with no pitch: a screen can show that a
    /// note is coming rather than silence.
    starting: bool = false,

    pub const none: Reading = .{ .freq_hz = 0, .note = 0, .cents = 0, .clarity = 0 };
};

pub const min_sample_rate = 8000;
pub const max_sample_rate = 384000;

const window_seconds = th.yin.window_s;
/// The shortest period searched, as a frequency (as in the JSFX).
const max_pitch_hz = th.yin.max_pitch_hz;

/// How the analyser is built. The defaults are the tuner's; the other
/// values exist so the bench can measure what each choice buys.
pub const Options = struct {
    /// Cut-off of the input low-pass; null for none.
    lowpass_hz: ?f64 = th.yin.lowpass_hz,
    /// Above this rate only every D-th filtered sample is analysed, with D
    /// the smallest whole number that brings the rate down to it.
    max_analysis_rate: f64 = 48000,
    /// With no dip under the dip threshold, the deepest dip must be under
    /// this for a pitch; null reports the deepest dip whatever its depth,
    /// as the JSFX does.
    voicing_threshold: ?f64 = th.yin.voicing,
    /// YIN's absolute threshold: the first dip under it is the period.
    dip_threshold: f64 = th.yin.dip,
    /// An onset is a 5 ms block with this many dB more energy than the
    /// mean of the blocks 10 to 40 ms before it (8 times).
    onset_db: f64 = th.onset.jump_db,
    /// How YIN's period is refined to the first partial's frequency (see
    /// first_partial.zig); null reports YIN's interpolated period.
    refinement: ?first_partial.Method = .phase_slope,
    /// The refinement measures at most this much of the input since the
    /// last onset.
    refine_window_s: f64 = th.refine.window_s,
    /// The uncertainty given YIN's frequency as an estimate of the first
    /// partial (mostly the pull of a stiff string's upper partials): the
    /// reading weights YIN's and the refinement's frequencies by the
    /// inverse of their variances.
    yin_sigma_cents: f64 = th.refine.yin_sigma_cents,
    /// After an onset, a jump of the frequency by 2, 3 or 4 times (either
    /// way) is held back until this many analyses in a row agree; 0 for
    /// none.
    octave_hold: u8 = th.hold.octave_analyses,
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
    settle_s: f64 = th.hold.settle_s,
    /// `stable` needs the shown pitch's least-squares slope over this long
    /// under `stable_cents_per_s`.
    stable_s: f64 = th.hold.stable_s,
    stable_cents_per_s: f64 = th.hold.stable_cents_per_s,
    /// `stable` also needs the shown pitch within this RMS of that line,
    /// cents; null for no such check.
    stable_spread_cents: ?f64 = th.hold.stable_spread_cents,
    /// A note shows only while the window's level stands this many dB over
    /// a noise floor learned while no note shows (it follows the level down
    /// at once and up at `floor_rise_db_per_s`); null for no learned floor.
    floor_margin_db: ?f64 = th.gate.floor_margin_db,
    /// Whether a note needs an onset to start showing: hum and noise have
    /// none. A note that stops showing starts again only at a new onset,
    /// unless it dropped out for under `resume_s` with the level still up.
    onset_gate: bool = true,
    /// A note shows only while the latest `release_s` of input holds energy
    /// within this many dB of the window's mean: once a string has stopped
    /// (a muted stroke, a damped note) the window still holds its tail for
    /// 93 ms, but nothing is sounding now. Null for no such check.
    release_drop_db: ?f64 = th.gate.release_drop_db,
    /// Whether a note within `mains_cents` of a harmonic of 50 or 60 Hz
    /// whose level has fallen less than `mains_decay_db` over the last
    /// `mains_hold_s` stops showing, as mains hum or buzz. Off: hum and
    /// buzz have no onset, so the onset gate already keeps them from
    /// showing, and a note held at a steady level near a mains harmonic
    /// (E5 is 2 cents under 11 x 60 Hz, C6 6 cents under 21 x 50 Hz; a
    /// compressor or sustainer holds a string's level) would vanish after
    /// a second. It catches only buzz that switches on.
    mains_rule: bool = false,
    /// With no note showing, the window level rising to this many dB over
    /// the lowest of the last `slow_onset_s` is an onset (a swell, a
    /// volume pedal, an e-bow, a bow have no energy jump), placed where the
    /// level last stood within `rise_quiet_db` of that lowest, with the
    /// floor put back to the lowest;
    /// null for none. Hum, buzz and noise switching on rise too: noise has
    /// no pitch, and hum and buzz wait as after any onset
    /// (`mains_start_hold`).
    slow_onset_db: ?f64 = th.onset.rise_db,
    /// Whether a note whose input since its onset repeats at the period of
    /// 50 or 60 Hz mains (see `mainsPeriodic`) waits to start until its
    /// level is seen to fall: by `mains_fall_db` over each of the last two
    /// `mains_fall_s`, and `mains_decay_db` under the loudest of the last
    /// `mains_hold_s`. Hum and buzz that switch on have an onset, and hold
    /// their level; the first readings of a sound that has just started
    /// can be 30 cents out, so its frequency can't tell it from a note.
    /// Only readings up to about 245 Hz are held (hum and buzz read 50 or
    /// 60 Hz, or a low multiple), and a note repeats at the mains period
    /// only within about 17 cents of 50 or 60 Hz times a whole number: no
    /// note in tune at A = 440 Hz up to 245 Hz is within 33 cents of one.
    /// One held level there (an e-bow, a pad) never shows, and a note
    /// already showing is not affected.
    mains_start_hold: bool = true,
    /// Whether a reading at 2 to 4 times a mains frequency is taken for
    /// mains only if the input doesn't also repeat at the reading's own
    /// period (hum and buzz have their fundamental too; a note there
    /// doesn't). Rectifier ripple with no fundamental at all is then not
    /// held.
    mains_own_period: bool = true,
    /// Whether a note shows no name until the window lies wholly after
    /// its onset (93 ms). An acoustic's body modes ring loudest at the
    /// pluck and can read as the octave under for the first 100 ms, and
    /// the first two readings can agree on it, so no check of the early
    /// readings tells; a wrong name, even briefly, is worse than that
    /// much delay.
    names_after_window: bool = true,
    /// Whether the octave hold anchors only on analyses whose window lies
    /// wholly after the onset: an acoustic's body modes ring loudest at
    /// the pluck and can make the first readings the note's octave under,
    /// which a hold anchored there then keeps.
    hold_after_window: bool = true,
    /// The first partial alone is reported when it and YIN disagree by more
    /// than this many of their combined standard errors: YIN's 1 cent
    /// holds for one string, but another note under it (a string ringing
    /// in sympathy) pulls YIN's period by tens of cents while the first
    /// partial's phase slope stays within a cent. Null to always combine.
    yin_consistency: ?f64 = th.refine.yin_consistency,
    /// Whether, while a note shows, the fine input less itself a period of
    /// that note earlier (whatever isn't that note) is watched for a jump
    /// as an onset is, and the note such an onset starts measured with the
    /// ringing one taken out: a string plucked over another still ringing
    /// as loud adds no energy if the hand damps the first, and the two
    /// together read as their common subharmonic.
    comb_onset: bool = true,
    /// Whether a reading of the input with the ringing note combed out is
    /// refused when it is 2, 3 or 4 times that note or a half, third or
    /// quarter of it: the comb takes out every partial the two share, so
    /// what is left of harmonically related notes reads as either.
    comb_unrelated: bool = true,
    /// Whether such an onset is taken back when what is left has no pitch
    /// or reads as the ringing note: the ringing note's own pitch moving
    /// under the comb is not a new note, and the onset would reset the
    /// octave hold and allow a jump.
    comb_confirm: bool = true,
    /// Whether the spectrum of the input since the onset is checked for
    /// several notes (see several.zig).
    several_guard: bool = true,
    /// Whether stationary mains hum is learned while no note shows and
    /// taken out of a note's input before its first partial is measured
    /// (see hum.zig).
    hum_model: bool = true,
    /// Whether YIN's first dip gives way to one at twice its lag that is
    /// far deeper (see `subharmonic`).
    subharmonic_check: bool = true,
    /// Whether a showing note whose reading jumps more than
    /// `thresholds.hold.jump_cents` from the last analysis without a new
    /// onset stops showing (and resumes only at an onset), rather than
    /// showing the jump: a peg turn moves through adjacent semitones,
    /// while a note fading under hum or another sound falls to a twelfth
    /// or octaves down.
    jump_stops: bool = true,
    /// Whether, after such a jump, a new pitch that isn't harmonically
    /// related to the stopped one (2, 3 or 4 times it, or a half, third
    /// or quarter) and holds within a quarter tone for a window starts
    /// showing without an onset: a legato bass line's next note.
    legato_restart: bool = true,
    /// Whether that restart also takes a pitch 2, 3 or 4 times the stopped
    /// one: a note first read an octave or twelfth under it corrects
    /// upwards, while a fading note's ghosts fall.
    restart_upward: bool = true,
    /// Without hum, the subharmonic check's longer period stands only if
    /// a partial near its frequency lies within this many dB of the
    /// strongest, once the spectrum since the onset can judge; null to
    /// trust the raw difference alone.
    subharmonic_confirm_db: ?f64 = th.yin.subharmonic_confirm_db,
};

const subharmonic_min_dip = th.yin.subharmonic_min_dip;
const subharmonic_ratio = th.yin.subharmonic_ratio;

/// The hum is learned every `hum_hop_s` from the idle input since the
/// last onset, at least `hum_learn_min_s` and at most `hum_learn_max_s` of
/// it (the longer, the more exactly the mains frequency is known, and the
/// further its phase can be carried through a note).
const hum_learn_min_s = th.hum.learn_min_s;
const hum_learn_max_s = th.hum.learn_max_s;
const hum_hop_s = th.hum.hop_s;
/// Once two learns agree, the hum is learned again only this often.
const hum_relearn_s = th.hum.relearn_s;

const floor_rise_db_per_s = th.gate.floor_rise_db_per_s;
const resume_s = th.gate.resume_s;
/// Longer than B0's period, so a low note's waveform doesn't swing it.
const release_s = th.gate.release_s;
/// Input samples beyond this magnitude are taken for silence.
const max_sample = th.gate.max_sample;
const onset_floor_hold_s = th.gate.onset_floor_hold_s;
/// An onset starts a note only within this long of the first analysis
/// that saw it.
const onset_life_s = th.onset.life_s;
const mains_cents = th.mains.rule_cents;
const mains_decay_db = th.mains.decay_db;
const mains_hold_s = th.mains.hold_s;
/// Longer than the window, so a step in the level can't fall over two
/// spans in a row.
const mains_fall_s = th.mains.fall_s;
/// The slow onset looks back this far, over the lowest window level in
/// each of `rise_buckets` spans.
const slow_onset_s = th.onset.rise_span_s;
const rise_buckets = th.onset.rise_buckets;
/// A rise starts where the level last stood within this of its lowest.
const rise_quiet_db = th.onset.rise_quiet_db;
const mains_fall_db = th.mains.fall_db;
/// The input since an onset repeats at the mains period if, at a lag
/// within `mains_period_tolerance` of 1/50 or 1/60 s, its normalised
/// difference with itself is under `mains_periodic_max`; at least
/// `mains_periodic_min_s` of it must overlap.
const mains_period_tolerance = th.mains.period_tolerance;
const mains_periodic_max = th.mains.periodic_max;
const mains_periodic_min_s = th.mains.periodic_min_s;
const mains_search_span = th.mains.search_span;
/// The first readings of hum or buzz that has just switched on are within
/// this of 50 or 60 Hz times 1 to 4 (33 cents seen); only such readings
/// wait for the input to be judged, and no note in tune at A = 440 Hz is
/// within it (G1, G2, D3 and G3 are 35-37 cents away, F#3 47).
const mains_first_cents = th.mains.first_cents;
/// Hum and buzz read 50 or 60 Hz, or a low multiple where the fundamental
/// is weak: 4 x 60 Hz, and the first readings' 30 cents. Higher notes
/// repeat at the mains period wherever they lie within 17 cents of any
/// multiple, and are never taken for it.
const mains_reading_max_hz = th.mains.reading_max_hz;
/// Window levels kept for the mains rule (a little over 2 s at 30 Hz).
const level_history_len = 72;

/// Analyses kept for the Hampel filter, and entries (at most one every
/// stable_s / 20) for the stability slope.
const hampel_len = th.hold.hampel_len;
const history_len = 32;
/// The Hampel filter replaces a reading more than 3 scaled median absolute
/// deviations from the median, and at least this many cents.
const hampel_floor_cents = th.hold.hampel_floor_cents;

/// The refinement's input is the analysed signal low-passed again and
/// decimated to a rate from this up to twice it (the first partial is
/// under 2 kHz); rates under it are kept as they are.
const fine_rate_floor = th.refine.fine_rate_floor;
/// The longest period the refinement averages over: YIN's longest
/// (half the window) at the fastest fine rate.
const max_fine_period: usize = @as(usize, @intFromFloat(@ceil(2 * fine_rate_floor * window_seconds / 2))) + 1;

/// An onset is a 5 ms block of fine-rate input with `Options.onset_db`
/// more energy than the mean of the blocks 10 to 40 ms before it, at
/// least 50 ms after the last one.
const onset_block_s = th.onset.block_s;
const onset_history = th.onset.history;
const onset_refractory_s = th.onset.refractory_s;

/// The tuner's analyser.
pub const Analyser = AnalyserWith(.{});

pub fn AnalyserWith(comptime options: Options) type {
    const onset_ratio = comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk std.math.pow(f64, 10, options.onset_db / 10);
    };
    const max_window: usize = @intFromFloat(@ceil(window_seconds * options.max_analysis_rate));
    const max_fft = std.math.ceilPowerOfTwo(usize, max_window + max_window / 2) catch unreachable;
    const fine_needed = options.refinement != null or options.onset_gate or options.several_guard;
    const max_fine: usize = if (!fine_needed) 1 else @intFromFloat(@ceil(options.refine_window_s * 2 * fine_rate_floor));
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
        /// The period of the note showing at the last analysis, in fine
        /// samples (0 for none); the energy in the current block of the
        /// fine input less itself a period earlier (what isn't that note),
        /// that of the last `onset_history` full blocks and how many of
        /// them there have been since the period was set.
        comb_period: f64,
        comb_energy: f64,
        comb_blocks: [onset_history]f64,
        comb_seen: usize,
        /// The onset count of the last onset found that way, and the note
        /// that was ringing then (Hz): until the next onset, the note it
        /// started is measured with that one taken out.
        comb_onset: u64,
        comb_old_hz: f64,
        /// `onset_at` before the last such onset.
        comb_prev_onset_at: u64,
        /// Full blocks since the reset (onsets are looked for only once the
        /// blocks before one are input, not the reset's silence), and onsets
        /// in all.
        blocks_seen: usize,
        onset_count: u64,
        /// The fine input since the last onset (at most refine_window_s),
        /// oldest first, loaded by each analysis.
        segment: [max_fine]f64,
        segment_len: usize,
        windowed: [if (options.several_guard or options.hum_model) max_fft else 1]f64,
        spectrum: [if (options.several_guard or options.hum_model) max_fft / 2 + 1 else 1]f64,
        hum_window: [if (options.hum_model) max_fft else 1]f64,
        several_scratch: several.Scratch,
        /// Whether the last analysis heard several notes.
        heard_several: bool,
        /// The lag the subharmonic check moved from, this analysis.
        moved_from: ?usize,
        /// The refinement's last standard error (cents), and its ratio with
        /// the hum taken out to without (0 with no hum taken out).
        last_sigma: f64,
        hum_fit: f64,
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
        /// The settings the gate last decided with, and its state before it
        /// decided on the current input.
        gate_settings: Settings,
        gate_before: GateState,
        floor_db: f64,
        /// Floor learning stops at an onset until the gate has decided on it.
        floor_paused: bool,
        /// Kept samples to the next floor update.
        floor_countdown: usize,
        note_active: bool,
        note_onset_count: u64,
        note_start: f64,
        note_end: f64,
        note_may_resume: bool,
        /// The pitch measured at the note's last analysis, Hz (0 for none).
        note_last_hz: f64,
        /// The pitch a jump stopped a note at (0 if the last note didn't
        /// end at a jump), and the new pitch waited on since when.
        jump_from_hz: f64,
        jump_wait_hz: f64,
        jump_wait_since: f64,
        level_t: [level_history_len]f64,
        level_v: [level_history_len]f64,
        level_pos: usize,
        level_used: usize,
        /// The lowest window level in each span of slow_onset_s /
        /// rise_buckets (+inf for none), and the span of the latest.
        rise_min: [rise_buckets]f64,
        rise_last: u64,
        /// Whether the input had risen at the last analysis, with no note
        /// showing.
        rise_prev: bool,
        /// The onset count the lowest levels were kept since.
        rise_onset: u64,
        /// `fine_count` at the latest analysis whose level was within
        /// `rise_quiet_db` of the lowest.
        rise_quiet_at: u64,
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
            self.moved_from = null;
            self.last_sigma = 0;
            self.hum_fit = 0;
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
            self.gate_settings = .{};
            self.floor_db = std.math.nan(f64);
            self.floor_paused = false;
            self.floor_countdown = 0;
            self.note_active = false;
            self.note_onset_count = 0;
            self.note_start = 0;
            self.note_end = -std.math.inf(f64);
            self.note_may_resume = false;
            self.note_last_hz = 0;
            self.jump_from_hz = 0;
            self.jump_wait_hz = 0;
            self.jump_wait_since = 0;
            self.level_pos = 0;
            self.level_used = 0;
            @memset(&self.rise_min, std.math.inf(f64));
            self.rise_last = 0;
            self.rise_prev = false;
            self.rise_onset = 0;
            self.rise_quiet_at = 0;
            self.onset_seen = 0;
            self.onset_seen_at = 0;
            self.block_fill = 0;
            self.block_energy = 0;
            @memset(&self.blocks, 0);
            self.blocks_pos = 0;
            self.comb_period = 0;
            self.comb_energy = 0;
            @memset(&self.comb_blocks, 0);
            self.comb_seen = 0;
            self.comb_onset = 0;
            self.comb_old_hz = 0;
            self.comb_prev_onset_at = 0;
        }

        /// Adds mono input. Non-finite samples, and any beyond
        /// `max_sample` (60 dB over full scale: no audio, a plug-in blowing
        /// up), count as silence, so one bad sample can't poison the
        /// filters or the level.
        pub fn push(self: *Self, samples: []const f32) void {
            for (samples) |s| {
                const x: f64 = if (std.math.isFinite(s) and @abs(s) <= max_sample) s else 0;
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
            if (options.comb_onset and self.comb_period > 0) {
                const r = v - self.fineAt(@as(f64, @floatFromInt(self.fine_count - 1)) - self.comb_period);
                self.comb_energy += r * r;
            }
            self.block_fill += 1;
            if (self.block_fill < self.block_len) return;
            // Blocks 2 to onset_history back, 10 to 40 ms before this one.
            var before: f64 = 0;
            for (2..onset_history) |k| before += self.blocks[(self.blocks_pos + onset_history - k) % onset_history];
            before /= onset_history - 2;
            const since_last = self.fine_count - self.onset_at;
            const refractory: u64 = @intFromFloat(onset_refractory_s * self.fine_rate);
            const heard = self.blocks_seen >= onset_history;
            const free = self.onset_count == 0 or since_last >= refractory;
            if (heard and self.block_energy > onset_ratio * before and self.block_energy > 0 and free) {
                self.onset_at = self.fine_count - self.block_len;
                self.onset_count += 1;
                self.floor_paused = true;
            } else if (self.comb_period > 0) {
                // A new sound over a ringing note need not add energy (the
                // ringing one damped as the next is plucked), but what isn't
                // that note jumps, as much of the input as 1 / onset_ratio.
                var comb_before: f64 = 0;
                for (2..onset_history) |k| comb_before += self.comb_blocks[(self.blocks_pos + onset_history - k) % onset_history];
                comb_before /= onset_history - 2;
                if (self.comb_seen >= onset_history and free and self.comb_energy > onset_ratio * comb_before and onset_ratio * self.comb_energy > self.block_energy) {
                    self.comb_prev_onset_at = self.onset_at;
                    self.onset_at = self.fine_count - self.block_len;
                    self.onset_count += 1;
                    self.floor_paused = true;
                    self.comb_onset = self.onset_count;
                    self.comb_old_hz = self.fine_rate / self.comb_period;
                }
            }
            self.comb_blocks[self.blocks_pos] = self.comb_energy;
            self.comb_seen = if (self.comb_period > 0) self.comb_seen + 1 else 0;
            self.comb_energy = 0;
            self.blocks_seen += 1;
            self.blocks[self.blocks_pos] = self.block_energy;
            self.blocks_pos = (self.blocks_pos + 1) % onset_history;
            self.block_energy = 0;
            self.block_fill = 0;
        }

        /// The fine input at `pos` (in fine samples since the reset, at
        /// most `max_fine` back), linearly interpolated.
        fn fineAt(self: *const Self, pos: f64) f64 {
            if (pos < 0) return 0;
            const i: u64 = @intFromFloat(@floor(pos));
            const frac = pos - @as(f64, @floatFromInt(i));
            const x0 = self.fine[@intCast(i % max_fine)];
            const x1 = self.fine[@intCast((i + 1) % max_fine)];
            return x0 + frac * (x1 - x0);
        }

        /// Sets the period the fine input is compared with a period back
        /// to that of `hz` (null for none); a change of more than 1% starts
        /// the comparison's history afresh.
        fn setComb(self: *Self, hz: ?f64) void {
            const period = if (hz) |f| self.fine_rate / f else 0;
            if (period == 0 or self.comb_period == 0 or @abs(period / self.comb_period - 1) > 0.01) self.comb_seen = 0;
            self.comb_period = period;
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

        /// The loaded segment less itself a period of `hz` earlier: a period
        /// and a sample shorter, and empty if that leaves too little.
        fn combSegment(self: *Self, hz: f64) void {
            const period = self.fine_rate / hz;
            const skip: usize = @intFromFloat(@ceil(period) + 1);
            const n = self.segment_len;
            if (n <= skip + 16) {
                self.segment_len = 0;
                return;
            }
            // In place, forwards: sample i reads samples i and later only.
            for (0..n - skip) |i| {
                const back = @as(f64, @floatFromInt(i + skip)) - period;
                const j: usize = @intFromFloat(@floor(back));
                const frac = back - @as(f64, @floatFromInt(j));
                self.segment[i] = self.segment[i + skip] - (self.segment[j] + frac * (self.segment[j + 1] - self.segment[j]));
            }
            self.segment_len = n - skip;
        }

        /// The first partial's frequency near `guess_hz`, measured over the
        /// loaded segment, and its standard error in cents; null with too
        /// little input since the onset to measure.
        fn refine(self: *Self, guess_hz: f64) ?struct { hz: f64, sigma_cents: f64 } {
            self.last_sigma = 0;
            const method = options.refinement orelse return null;
            const e = first_partial.estimate(max_fine_period, &self.refine_work, self.segment[0..self.segment_len], self.fine_rate, guess_hz, method) orelse return null;
            // A partial a quarter-tone or more from the guess is not the
            // one YIN found.
            if (!(@abs(1200 * @log2(e.hz / guess_hz)) < 50)) return null;
            // 1200 / ln 2 cents per unit of relative frequency; the standard
            // error runs up to 15% under the observed scatter.
            self.last_sigma = 1.15 * 1731.234 * e.std_error_hz / e.hz;
            return .{ .hz = e.hz, .sigma_cents = self.last_sigma };
        }

        /// The several-notes verdict on the loaded segment's spectrum (its
        /// latest `max_fft` samples at most, Blackman-Harris windowed and
        /// zero-padded to a power of two) for partials `spacing_hz` apart,
        /// or null with the guard off.
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
                const settled_window = !options.hold_after_window or (self.fine_count - self.onset_at) * self.fine_decimation >= self.window;
                self.hold_set = settled_window and @abs(lf - self.hold_log2) <= quarter_tone;
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
            if (options.yin_consistency) |k| {
                if (@abs(offset) > k * @sqrt(vy + vf)) return fine.hz;
            }
            return coarse * std.math.pow(f64, 2, offset * vy / (vy + vf) / 1200);
        }

        /// The input sample (counted from `init` or `reset`) where the last
        /// onset began, to within a 5 ms block; null before the first.
        /// `init` with another sample rate starts the count again, so a
        /// value from before a rate change means nothing after it.
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
                self.setComb(null);
                var r = Reading.none;
                r.multiple = self.heard_several;
                r.starting = self.note_active and !self.gate_open;
                return r;
            };
            self.setComb(shown.hz);
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
            self.moved_from = null;
            // After an onset found over a ringing note by what isn't that
            // note, the input with that note taken out, unless what is left
            // reads as that note still (the same string plucked again).
            var combed = false;
            var best: usize = 0;
            if (options.comb_onset and self.comb_onset != 0 and self.comb_onset == self.onset_count) {
                self.difference(self.comb_old_hz);
                var related = false;
                if (self.pickPeriod(settings.range)) |b| {
                    const hz = self.analysis_rate / self.interpolate(b);
                    related = combRelated(hz, self.comb_old_hz);
                    // What is left of a note re-plucked a few cents off is
                    // their beat, which dips nowhere clearly.
                    const clear = !options.comb_confirm or self.cmnd[b] < options.dip_threshold;
                    if (clear and !(options.comb_unrelated and related) and @abs(1200 * @log2(hz / self.comb_old_hz)) >= 50) {
                        best = b;
                        combed = true;
                    }
                }
                if (!combed) {
                    self.moved_from = null;
                    // Once the window lies past the onset, what isn't the
                    // ringing note having no pitch, or reading as that note,
                    // means no new note after all: the onset is taken back
                    // and the note carries on. One harmonically related (a
                    // bass line's octave) stays a new note.
                    if (options.comb_confirm and !related and (self.fine_count - self.onset_at) * self.fine_decimation >= self.window) {
                        // The count stays (it orders onsets); a showing note
                        // takes it as its own.
                        self.onset_at = self.comb_prev_onset_at;
                        if (self.note_active) self.note_onset_count = self.onset_count;
                        self.comb_onset = 0;
                    }
                }
            }
            if (!combed) {
                self.difference(null);
                best = self.pickPeriod(settings.range) orelse return null;
            }
            if (fine_needed) self.loadSegment();
            const hum_out = options.hum_model and self.hum_valid and fine_needed;
            if (hum_out) @memcpy(self.windowed[0..self.segment_len], self.segment[0..self.segment_len]);
            if (hum_out) {
                // Out of the band the refinement passes, about the note
                // (the higher of the two periods considered, if two were).
                const top_period = self.moved_from orelse best;
                self.hum_now.subtract(self.segment[0..self.segment_len], self.fine_count - self.segment_len, self.fine_rate, 0, 2 * self.analysis_rate / self.interpolate(top_period));
            }
            if (combed and fine_needed) self.combSegment(self.comb_old_hz);
            if (self.moved_from) |orig| {
                // Hum adds periodicity at multiples of the period: under hum
                // the longer period must have a partial heard at its
                // frequency, once the hum is out.
                const low = self.analysis_rate / self.interpolate(best);
                if (hum_out) {
                    const heard = if (self.judgeSeveral(low)) |j| j.heard(low) else false;
                    if (!heard) best = orig;
                } else if (options.subharmonic_confirm_db) |db| {
                    // Nor without hum does the longer period stand unless
                    // the spectrum, once it can tell, has a partial near
                    // its frequency: a clean note whose own period dips
                    // a little (a slide, the window's edge) has nothing
                    // at half its pitch.
                    if (self.judgeSeveral(low)) |j| {
                        if (j.strongest > 0 and !j.heardWithin(low, db)) best = orig;
                    }
                }
            }
            const detected = self.analysis_rate / self.interpolate(best);
            const coarse = self.holdOctave(detected);
            // Of several notes, only one of them shows, never what repeats
            // under them all.
            if (self.judgeSeveral(coarse)) |j| {
                if (j.verdict == .several) {
                    self.heard_several = true;
                    if (!j.heard(coarse)) return null;
                }
            }
            const hz = self.combine(coarse);
            self.hum_fit = 0;
            if (hum_out and self.last_sigma > 0) {
                if (first_partial.estimate(max_fine_period, &self.refine_work, self.windowed[0..self.segment_len], self.fine_rate, coarse, .phase_slope)) |raw| {
                    self.hum_fit = (self.last_sigma / 1.15 / 1731.234 * raw.hz) / raw.std_error_hz;
                }
            }
            return .{ .hz = hz, .clarity = std.math.clamp(1 - self.cmnd[best], 0, 1) };
        }

        /// The RMS of the window's input (before the low-pass), dBFS.
        fn windowLevelDb(self: *const Self) f64 {
            // Summed afresh each time: a running sum would carry the
            // rounding of loud input long after it has left the window.
            var energy: f64 = 0;
            for (self.energy[0..self.window]) |v| energy += v;
            const rms = @sqrt(energy / @as(f64, @floatFromInt(self.window * self.decimation)));
            return 20 * std.math.log10(@max(rms, 1e-7));
        }

        /// `m` if a note may show: over the learned floor, started at an
        /// onset, still sounding, and not mains hum. Decides once per input,
        /// and again for the same input if the settings change, from the
        /// state it decided from.
        fn gate(self: *Self, m: ?Measured, level: f64, settings: Settings) ?Measured {
            if (self.kept_count == self.gate_at) {
                if (sameGateSettings(settings, self.gate_settings)) return if (self.gate_open) m else null;
                self.restoreGate();
            } else {
                self.saveGate();
                self.gate_at = self.kept_count;
                const t = @as(f64, @floatFromInt(self.kept_count)) / self.analysis_rate;
                self.level_t[self.level_pos] = t;
                self.level_v[self.level_pos] = level;
                self.level_pos = (self.level_pos + 1) % level_history_len;
                self.level_used = @min(self.level_used + 1, level_history_len);
                self.noteLevel(t, level);
            }
            self.gate_settings = settings;
            const now = @as(f64, @floatFromInt(self.kept_count)) / self.analysis_rate;
            // A rise in level with no note showing is an onset where the
            // level last stood near its lowest, from a floor at that level,
            // not the one learned as it rose. This input was measured from
            // the onset before, so a note can start only from the next.
            const rose = !self.note_active and self.risen(level);
            const rise_onset = rose and !self.rise_prev;
            if (rise_onset) {
                self.onset_at = self.rise_quiet_at;
                self.onset_count += 1;
                self.floor_paused = true;
                self.floor_db = @min(self.floor_db, std.mem.min(f64, &self.rise_min));
            }
            self.rise_prev = rose;
            // Every analysis sees a new onset, pitched or not.
            const fresh_onset = self.onsetFresh(now);

            const loud = if (options.floor_margin_db) |margin| std.math.isNan(self.floor_db) or level >= self.floor_db + margin else true;
            const pitched = m != null and level >= settings.silence_db;
            if (self.note_active) {
                // Without a new onset the name may only move as far as a
                // pitch moving continuously goes between two analyses: a
                // bigger jump is the note fading into something else.
                // Readings while the name is still held back don't count:
                // they were never shown.
                const named = !options.names_after_window or self.sinceOnset() >= self.window;
                const jumped = options.jump_stops and pitched and named and self.onset_count == self.note_onset_count and self.note_last_hz > 0 and @abs(1200 * @log2(m.?.hz / self.note_last_hz)) > th.hold.jump_cents;
                const keep = pitched and loud and !jumped and self.sounding() and !self.mainsHeld(m.?.hz, now);
                if (!keep) {
                    self.note_active = false;
                    self.note_end = now;
                    // Only a moment without a pitch, the level still up, may
                    // resume without a new onset.
                    self.note_may_resume = !pitched and loud;
                    self.jump_from_hz = if (jumped) self.note_last_hz else 0;
                    self.jump_wait_hz = 0;
                    self.note_last_hz = 0;
                } else self.note_last_hz = if (named) m.?.hz else 0;
            } else if (pitched and self.sounding()) {
                const resuming = loud and self.note_may_resume and now - self.note_end < resume_s and self.onset_count == self.note_onset_count;
                const at_onset = loud and !rise_onset and (!options.onset_gate or fresh_onset);
                // After a jump stopped a note, a pitch that holds within a
                // quarter tone for a window starts showing: a legato note,
                // the old one back after a moment's misreading, or 2, 3 or
                // 4 times a reading that was a note's octave or twelfth
                // under. Not a half, third or quarter of the old one: a
                // note fading under hum falls to those.
                var legato = false;
                if (options.legato_restart and !at_onset and self.jump_from_hz > 0 and loud and self.onset_count == self.note_onset_count) {
                    if (combRelated(m.?.hz, self.jump_from_hz) and !(options.restart_upward and m.?.hz > self.jump_from_hz)) {
                        self.jump_wait_hz = 0;
                    } else if (self.jump_wait_hz > 0 and @abs(1200 * @log2(m.?.hz / self.jump_wait_hz)) < 50) {
                        legato = now - self.jump_wait_since >= window_seconds;
                    } else {
                        self.jump_wait_hz = m.?.hz;
                        self.jump_wait_since = now;
                    }
                }
                if (resuming or legato or (at_onset and !self.mainsLike(m.?.hz, now, self.sinceOnset()))) {
                    self.jump_from_hz = 0;
                    self.jump_wait_hz = 0;
                    if (!resuming) self.note_start = now;
                    self.note_last_hz = if (!options.names_after_window or self.sinceOnset() >= self.window) m.?.hz else 0;
                    self.note_active = true;
                    self.note_onset_count = self.onset_count;
                }
            }
            // While the window still holds input from before the onset that
            // started it, the note shows no name.
            // A note already showing when a later onset comes keeps its
            // name until that onset proves a new note.
            const held = options.names_after_window and self.note_active and self.onset_count == self.note_onset_count and self.sinceOnset() < self.window;
            self.gate_open = self.note_active and !held;
            if (!self.note_active) self.learnHum();
            // An onset holds the floor until a note it started has ended, or
            // for `onset_floor_hold_s` if none shows (the window takes a while
            // to fill with a new note).
            if (!self.note_active and self.floor_paused) {
                const since_onset = @as(f64, @floatFromInt(self.fine_count - self.onset_at)) / self.fine_rate;
                if (self.note_onset_count == self.onset_count or since_onset >= onset_floor_hold_s) self.floor_paused = false;
            }
            return if (self.gate_open) m else null;
        }

        fn saveGate(self: *Self) void {
            self.gate_before = .{
                .note_last_hz = self.note_last_hz,
                .jump_from_hz = self.jump_from_hz,
                .jump_wait_hz = self.jump_wait_hz,
                .jump_wait_since = self.jump_wait_since,
                .rise_prev = self.rise_prev,
                .floor_db = self.floor_db,
                .onset_at = self.onset_at,
                .onset_count = self.onset_count,
                .note_active = self.note_active,
                .note_onset_count = self.note_onset_count,
                .note_start = self.note_start,
                .note_end = self.note_end,
                .note_may_resume = self.note_may_resume,
                .floor_paused = self.floor_paused,
            };
        }

        fn restoreGate(self: *Self) void {
            const g = self.gate_before;
            self.note_last_hz = g.note_last_hz;
            self.jump_from_hz = g.jump_from_hz;
            self.jump_wait_hz = g.jump_wait_hz;
            self.jump_wait_since = g.jump_wait_since;
            self.rise_prev = g.rise_prev;
            self.floor_db = g.floor_db;
            self.onset_at = g.onset_at;
            self.onset_count = g.onset_count;
            self.note_active = g.note_active;
            self.note_onset_count = g.note_onset_count;
            self.note_start = g.note_start;
            self.note_end = g.note_end;
            self.note_may_resume = g.note_may_resume;
            self.floor_paused = g.floor_paused;
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

        /// Keeps `level` among the lowest of its span of time, counting only
        /// windows full of input and wholly after the last onset (a rise
        /// since an onset is that onset's): an onset starts the lowest
        /// afresh.
        fn noteLevel(self: *Self, t: f64, level: f64) void {
            if (self.onset_count != self.rise_onset) {
                self.rise_onset = self.onset_count;
                @memset(&self.rise_min, std.math.inf(f64));
            }
            if (self.kept_count < self.window) return;
            if (self.onset_count > 0 and (self.fine_count - self.onset_at) * self.fine_decimation < self.window) return;
            const span: u64 = @intFromFloat(@floor(t / (slow_onset_s / @as(f64, @floatFromInt(rise_buckets)))));
            if (span > self.rise_last) {
                const fresh = @min(span - self.rise_last, rise_buckets);
                for (0..fresh) |k| self.rise_min[@intCast((span - k) % rise_buckets)] = std.math.inf(f64);
                self.rise_last = span;
            }
            const i: usize = @intCast(span % rise_buckets);
            self.rise_min[i] = @min(self.rise_min[i], level);
            if (level <= std.mem.min(f64, &self.rise_min) + rise_quiet_db) self.rise_quiet_at = self.fine_count;
        }

        /// Whether `level` stands `slow_onset_db` over the lowest of the last
        /// `slow_onset_s`.
        fn risen(self: *const Self, level: f64) bool {
            const margin = options.slow_onset_db orelse return false;
            return level - std.mem.min(f64, &self.rise_min) >= margin;
        }

        /// How many of the window's samples came after the block the last
        /// onset was found in (all of them with no onset): a sound that
        /// starts within that block has silence before it there.
        fn sinceOnset(self: *const Self) usize {
            if (self.onset_count == 0) return self.window;
            const fine_since = (self.fine_count - self.onset_at) -| self.block_len;
            return @intCast(@min(fine_since * self.fine_decimation, self.window));
        }

        /// Whether the latest `release_s` of input holds energy within
        /// `release_drop_db` of the window's mean.
        fn sounding(self: *const Self) bool {
            const drop = options.release_drop_db orelse return true;
            const n: usize = @intFromFloat(@round(release_s * self.analysis_rate));
            var recent: f64 = 0;
            for (0..n) |k| recent += self.energy[(self.write_pos + self.window - 1 - k) % self.window];
            const recent_mean = recent / @as(f64, @floatFromInt(n));
            var window_energy: f64 = 0;
            for (self.energy[0..self.window]) |v| window_energy += v;
            const window_mean = window_energy / @as(f64, @floatFromInt(self.window));
            return recent_mean >= window_mean * std.math.pow(f64, 10, -drop / 10);
        }

        /// Whether `hz` is within `mains_cents` of a harmonic of 50 or 60
        /// Hz and the level has fallen less than `mains_decay_db` over the
        /// last `mains_hold_s`, measured from a window wholly inside the
        /// note.
        /// Whether the input, reading `hz`, may be mains hum or buzz: see
        /// `Options.mains_start_hold`. The level history must hold the
        /// current input's level; `since_onset` is how many of the
        /// window's samples came after the onset.
        fn mainsLike(self: *const Self, hz: f64, now: f64, since_onset: usize) bool {
            if (!options.mains_start_hold or hz > mains_reading_max_hz) return false;
            var near = false;
            var multiple = false;
            for ([_]f64{ 50, 60 }) |base| {
                const k = @round(hz / base);
                if (k >= 1 and @abs(1200 * @log2(hz / (k * base))) <= mains_first_cents / k) {
                    near = true;
                    if (k >= 2) multiple = true;
                }
            }
            if (!near or !self.mainsPeriodic(since_onset)) return false;
            // Read at a multiple of the mains frequency, hum or buzz has
            // its fundamental too, so it doesn't repeat at the reading's
            // own period; a note there (a synth tone at 120 Hz) does.
            if (options.mains_own_period and multiple) {
                const own = self.analysis_rate / hz;
                const lo: usize = @intFromFloat(@floor(own));
                if (self.repeatsWithin(since_onset, lo, lo + 1)) return false;
            }
            const latest = self.levelAt(now) orelse return true;
            const before = self.levelAt(now - mains_fall_s) orelse return true;
            const earlier = self.levelAt(now - 2 * mains_fall_s) orelse return true;
            if (!(earlier - before >= mains_fall_db and before - latest >= mains_fall_db)) return true;
            var loudest = latest;
            for (0..self.level_used) |back| {
                const i = (self.level_pos + level_history_len - 1 - back) % level_history_len;
                if (self.level_t[i] < now - mains_hold_s) break;
                loudest = @max(loudest, self.level_v[i]);
            }
            return loudest - latest < mains_decay_db;
        }

        /// Whether the latest `since_onset` samples of the window, less
        /// their mean, repeat at a lag within `mains_period_tolerance` of
        /// 1/50 or 1/60 s; true while too few to tell (a note waits for
        /// them, at most `mains_periodic_min_s` more than 20 ms).
        fn mainsPeriodic(self: *const Self, since_onset: usize) bool {
            const w = self.window;
            const len = @min(since_onset, w);
            const min_overlap: usize = @intFromFloat(@ceil(mains_periodic_min_s * self.analysis_rate));
            var mean: f64 = 0;
            for (0..len) |i| mean += self.history[(self.write_pos + w - 1 - i) % w];
            mean /= @floatFromInt(@max(len, 1));
            for ([_]f64{ 50, 60 }) |base| {
                const lo: usize = @intFromFloat(@floor(self.analysis_rate / base * (1 - mains_period_tolerance)));
                const hi: usize = @intFromFloat(@ceil(self.analysis_rate / base * (1 + mains_period_tolerance)));
                // The best lag is looked for over a wider span: a tone
                // 2% off a mains period still nearly repeats at it, and
                // only where it repeats best tells.
                const wide_lo: usize = @intFromFloat(@floor(self.analysis_rate / base * (1 - mains_search_span)));
                const wide_hi: usize = @intFromFloat(@ceil(self.analysis_rate / base * (1 + mains_search_span)));
                if (len < wide_hi + min_overlap) return true;
                var best_lag = wide_lo;
                var best = std.math.inf(f64);
                for (wide_lo..wide_hi + 1) |lag| {
                    const e = self.normalisedDifference(len, mean, lag);
                    if (e < best) {
                        best = e;
                        best_lag = lag;
                    }
                }
                if (best_lag >= lo and best_lag <= hi and best < mains_periodic_max) return true;
            }
            return false;
        }

        /// The latest `len` samples of the window less `mean` against
        /// themselves `lag` earlier: their squared difference over their
        /// power (1 with none).
        fn normalisedDifference(self: *const Self, len: usize, mean: f64, lag: usize) f64 {
            const w = self.window;
            var diff: f64 = 0;
            var power: f64 = 0;
            for (0..len - lag) |i| {
                const a = self.history[(self.write_pos + w - 1 - i) % w] - mean;
                const b = self.history[(self.write_pos + w - 1 - i - lag) % w] - mean;
                diff += (a - b) * (a - b);
                power += a * a + b * b;
            }
            return if (power > 0) diff / power else 1;
        }

        /// Whether the latest `since_onset` samples of the window, less
        /// their mean, repeat at a lag from `lo` to `hi`; false with too
        /// few to tell.
        fn repeatsWithin(self: *const Self, since_onset: usize, lo: usize, hi: usize) bool {
            const w = self.window;
            const len = @min(since_onset, w);
            const min_overlap: usize = @intFromFloat(@ceil(mains_periodic_min_s * self.analysis_rate));
            if (len < hi + min_overlap) return false;
            var mean: f64 = 0;
            for (0..len) |i| mean += self.history[(self.write_pos + w - 1 - i) % w];
            mean /= @floatFromInt(@max(len, 1));
            return self.repeatsWithinFrom(len, mean, lo, hi);
        }

        fn repeatsWithinFrom(self: *const Self, len: usize, mean: f64, lo: usize, hi: usize) bool {
            for (lo..hi + 1) |lag| {
                if (self.normalisedDifference(len, mean, lag) < mains_periodic_max) return true;
            }
            return false;
        }

        /// The level of the latest analysis at or before `t`, if the
        /// history reaches back that far.
        fn levelAt(self: *const Self, t: f64) ?f64 {
            for (0..self.level_used) |back| {
                const i = (self.level_pos + level_history_len - 1 - back) % level_history_len;
                if (self.level_t[i] <= t) return self.level_v[i];
            }
            return null;
        }

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
            const new_input = self.kept_count != self.track_at;
            self.track_at = self.kept_count;
            const got = m orelse {
                if (new_input) self.track_voiced = false;
                return null;
            };
            const x = 1200 * @log2(got.hz);
            // A pitch for input last seen with none (the settings changed
            // in between) starts the note too.
            const fresh = new_input or !self.track_voiced;
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
                // At most one entry every `stable_s` / 20, so the history
                // spans `stable_s` however often the caller analyses.
                const latest = self.history_t[(self.history_pos + history_len - 1) % history_len];
                if (self.history_len_used == 0 or now - latest >= options.stable_s / 20) {
                    self.history_t[self.history_pos] = now;
                    self.history_v[self.history_pos] = self.track_value;
                    self.history_pos = (self.history_pos + 1) % history_len;
                    self.history_len_used = @min(self.history_len_used + 1, history_len);
                }
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
            const slope = (n * stv - st * sv) / den;
            if (!(@abs(slope) < options.stable_cents_per_s)) return false;
            const spread_max = options.stable_spread_cents orelse return true;
            // The shown pitch must also sit on that line: a pitch wobbling
            // about it (a hum that no longer fits beating with the note)
            // has turning points where the slope is flat.
            const intercept = (sv - slope * st) / n;
            var ss: f64 = 0;
            for (0..self.history_len_used) |k| {
                const i = (self.history_pos + history_len - 1 - k) % history_len;
                const t = self.history_t[i] - now;
                if (t < -options.stable_s - 1e-9) break;
                const r = self.history_v[i] - (intercept + slope * t);
                ss += r * r;
            }
            return @sqrt(ss / n) <= spread_max;
        }

        /// YIN's difference function d(tau) over the window, through the FFT
        /// autocorrelation r(tau): d(tau) = E(0, W-tau) + E(tau, W) - 2 r(tau),
        /// and its cumulative mean normalised form.
        /// YIN's difference function of the window, or with `comb_hz` of
        /// the window less itself a period of `comb_hz` earlier (a note
        /// taken out; the frame is a period and a sample shorter, and lags
        /// past half of it never dip).
        fn difference(self: *Self, comb_hz: ?f64) void {
            const w = self.window;
            var sum: f64 = 0;
            var len = w;
            if (comb_hz) |f| {
                const period = self.analysis_rate / f;
                const skip: usize = @intFromFloat(@ceil(period) + 1);
                len = w - skip;
                for (0..len) |i| {
                    const back = @as(f64, @floatFromInt(i + skip)) - period;
                    const j: usize = @intFromFloat(@floor(back));
                    const frac = back - @as(f64, @floatFromInt(j));
                    const x0 = self.history[(self.write_pos + j) % w];
                    const x1 = self.history[(self.write_pos + j + 1) % w];
                    const x = self.history[(self.write_pos + i + skip) % w] - (x0 + frac * (x1 - x0));
                    self.frame[i] = x;
                    sum += x * x;
                    self.cum_energy[i] = sum;
                }
            } else {
                for (0..w) |i| {
                    const x = self.history[(self.write_pos + i) % w];
                    self.frame[i] = x;
                    sum += x * x;
                    self.cum_energy[i] = sum;
                }
            }
            self.fft.autocorrelate(self.frame[0..len], self.fft_size, &self.fft_work, self.autocorr[0 .. len / 2]);
            for (len / 2..w / 2) |tau| {
                self.diff[tau] = std.math.inf(f64);
                self.cmnd[tau] = 1;
            }

            self.diff[0] = 0;
            self.cmnd[0] = 1;
            var running: f64 = 0;
            for (1..len / 2) |tau| {
                const head = self.cum_energy[len - tau - 1];
                const tail = self.cum_energy[len - 1] - self.cum_energy[tau - 1];
                const d = @max(0, head + tail - 2 * self.autocorr[tau]);
                self.diff[tau] = d;
                running += d;
                self.cmnd[tau] = if (running > 0) d * @as(f64, @floatFromInt(tau)) / running else 1;
            }
        }

        /// The period in analysed samples: the first local minimum of the
        /// normalised difference under `Options.dip_threshold`, or else the deepest
        /// one if it is under `options.voicing_threshold`; only periods
        /// within `range` if there is one.
        fn pickPeriod(self: *Self, range: ?Range) ?usize {
            const half = self.window / 2;
            var min_tau: usize = @max(2, @as(usize, @intFromFloat(self.analysis_rate / max_pitch_hz)));
            var end = half - 1;
            if (range) |r| {
                // Limits outside the analyser's own lags are clamped to them,
                // and a limit that isn't a positive number is ignored.
                const lags_from: f64 = @floatFromInt(min_tau);
                const lags_to: f64 = @floatFromInt(end);
                if (r.high_hz > 0 and std.math.isFinite(r.high_hz)) {
                    min_tau = @intFromFloat(std.math.clamp(@floor(self.analysis_rate / r.high_hz), lags_from, lags_to));
                }
                if (r.low_hz > 0 and std.math.isFinite(r.low_hz)) {
                    end = @intFromFloat(std.math.clamp(@ceil(self.analysis_rate / r.low_hz) + 2, lags_from, lags_to));
                }
                if (min_tau + 3 >= end) return null;
            }
            const c = self.cmnd[0..half];
            var tau = min_tau;
            while (tau < end - 1) : (tau += 1) {
                if (c[tau] < options.dip_threshold and c[tau] < c[tau - 1] and c[tau] <= c[tau + 1]) return self.subharmonic(tau, end);
            }
            var best = min_tau;
            for (min_tau + 1..end) |t| {
                if (c[t] < c[best]) best = t;
            }
            const limit = options.voicing_threshold orelse return best;
            return if (c[best] < limit) best else null;
        }

        /// `tau`, or the deepest dip of the raw difference near 2 tau when
        /// tau's dip is real (normalised depth `subharmonic_min_dip` or
        /// more) and that one is under `subharmonic_ratio` of it: the true
        /// period of a tone whose 2nd harmonic stands well over a weak 1st
        /// and 3rd, whose half period dips under the threshold first. On a
        /// true period the dip is near 0, so nothing moves. The raw
        /// difference, not the normalised one: the cumulative mean makes
        /// later dips look deeper at short lags.
        fn subharmonic(self: *Self, tau: usize, end: usize) usize {
            if (!options.subharmonic_check) return tau;
            if (self.cmnd[tau] < subharmonic_min_dip) return tau;
            const centre = 2 * tau;
            if (centre + 2 >= end) return tau;
            var best = centre - 2;
            for (centre - 1..centre + 3) |t| {
                if (self.diff[t] < self.diff[best]) best = t;
            }
            if (!(self.diff[best] < subharmonic_ratio * self.diff[tau])) return tau;
            self.moved_from = tau;
            return best;
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

/// Whether `hz` is within a quarter tone of 2, 3 or 4 times `other`, or
/// of a half, third or quarter of it.
fn combRelated(hz: f64, other: f64) bool {
    const ratios = [_]f64{ 2, 3, 4, 0.5, 1.0 / 3.0, 0.25 };
    for (ratios) |r| {
        if (@abs(1200 * @log2(hz / (other * r))) < 50) return true;
    }
    return false;
}

/// The gate's state that one decision changes.
const GateState = struct {
    note_last_hz: f64,
    jump_from_hz: f64,
    jump_wait_hz: f64,
    jump_wait_since: f64,
    rise_prev: bool,
    floor_db: f64,
    onset_at: u64,
    onset_count: u64,
    note_active: bool,
    note_onset_count: u64,
    note_start: f64,
    note_end: f64,
    note_may_resume: bool,
    floor_paused: bool,
};

/// Whether two settings gate alike (the reference pitch doesn't gate).
fn sameGateSettings(a: Settings, b: Settings) bool {
    if (a.silence_db != b.silence_db) return false;
    if ((a.range == null) != (b.range == null)) return false;
    if (a.range) |ra| {
        const rb = b.range.?;
        return std.meta.eql(ra, rb);
    }
    return true;
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
    // Without the comb onset, which takes the switch for a new note, and
    // without stopping at a jump, which ends the note instead.
    const held = try testing.allocator.create(AnalyserWith(.{ .comb_onset = false, .jump_stops = false }));
    defer testing.allocator.destroy(held);
    try held.init(48000);
    prime(held);
    const free = try testing.allocator.create(AnalyserWith(.{ .octave_hold = 0, .comb_onset = false, .jump_stops = false }));
    defer testing.allocator.destroy(free);
    try free.init(48000);
    prime(free);
    // E2, then E3 at the same level: no energy onset between them.
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
    // first reading, but nothing should hold it back for that. Names are
    // shown from the first reading, as the hold is what is tested.
    const a = try testing.allocator.create(AnalyserWith(.{ .names_after_window = false }));
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

test "a sustained string reads stable whether polled at 30 Hz or every 256 samples" {
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    signals.pluckedString(buf, 48000, .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .t60_s = 10 });
    for ([_]usize{ 1600, 256 }) |block| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        var stable_at: ?usize = null;
        var pos: usize = 0;
        while (pos + block <= 48000) : (pos += block) {
            a.push(buf[pos .. pos + block]);
            if (a.analyse(.{}).stable and stable_at == null) stable_at = pos;
        }
        errdefer std.debug.print("polled every {d} samples\n", .{block});
        try testing.expect(stable_at != null);
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

test "a note keeps reading at -64 dBFS while it stands 12 dB over the noise floor" {
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

test "a bass tone whose 2nd harmonic stands 15 dB over its 1st, its 3rd weak, reads its own note from 100 ms" {
    const buf = try generate(48000 * 2);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 41.2034, 55, 61.7354 }) |f0| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        const opts: signals.StringOptions = .{ .f0 = f0, .inharmonicity = 2e-4, .partial_gain = .{ 0.089, 1, 0.1, 1 } };
        signals.pluckedString(buf, 48000, opts);
        const note: i32 = @intFromFloat(@round(69 + 12 * @log2(f0 / 440)));
        var k: usize = 0;
        while ((k + 1) * 1600 <= buf.len) : (k += 1) {
            a.push(buf[k * 1600 .. (k + 1) * 1600]);
            const r = a.analyse(.{});
            if (k < 3 or r.freq_hz == 0) continue;
            errdefer std.debug.print("{d} Hz, reading {d}: {any}\n", .{ f0, k, r });
            try testing.expectEqual(note, r.note);
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

test "hum and buzz that switch on mid-signal never read as a note" {
    const buf = try generate(48000 * 3);
    defer testing.allocator.destroy(buf);
    for ([_]f64{ 50, 60 }) |hz| {
        for ([_]signals.Mains{ .hum, .buzz }) |kind| {
            const a = try newAnalyser(48000);
            defer testing.allocator.destroy(a);
            @memset(buf[0..24000], 0);
            signals.mains(buf[24000..], 48000, hz, kind, -40);
            signals.addNoise(buf, 3e-5, 6);
            errdefer std.debug.print("{d} Hz {s}\n", .{ hz, @tagName(kind) });
            try testing.expectEqual(@as(usize, 0), countNotes(a, buf, 48000, 0, null).shown);
        }
    }
}

test "a pluck on a mains harmonic, 34 cents sharp of G2, shows within half a second once its level is seen to fall" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 2);
    defer testing.allocator.destroy(buf);
    @memset(buf[0..12000], 0);
    signals.pluckedString(buf[12000..], 48000, .{ .f0 = 100, .inharmonicity = 1e-4, .t60_s = 3 });
    signals.addNoise(buf, 3e-5, 7);
    const tick: usize = 1600;
    var pos: usize = 0;
    var first: ?f64 = null;
    while (pos + tick <= buf.len) : (pos += tick) {
        a.push(buf[pos .. pos + tick]);
        const r = a.analyse(.{});
        if (r.freq_hz == 0) continue;
        try testing.expectEqual(@as(i32, 43), r.note);
        if (first == null) first = @as(f64, @floatFromInt(pos + tick - 12000)) / 48000;
    }
    try testing.expect(first.? <= 0.5);
}

test "a string swelling in over hum shows within 0.2 s of standing 12 dB over the hum" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 4);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 4);
    defer testing.allocator.destroy(other);
    // Hum throughout; A2 swelling in at 60 dB a second from 1 s.
    signals.mains(buf, 48000, 50, .hum, -50);
    @memset(other, 0);
    signals.pluckedString(other[48000..], 48000, .{ .f0 = 110, .inharmonicity = 6.5e-5, .t60_s = 20 });
    for (other[48000..], 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / 48000;
        v.* *= @floatCast(@min(1, std.math.pow(f64, 10, 3 * (t - 1))));
    }
    signals.mix(buf, other);
    signals.addNoise(buf, 3e-5, 8);
    // When the level over the analyser's window first stands 12 dB over
    // the hum's.
    const w: usize = @intFromFloat(@round(window_seconds * 48000));
    const hum_rms = signals.rms(buf[48000 - w .. 48000]);
    var crossed: usize = 48000;
    while (signals.rms(buf[crossed - w .. crossed]) < 4 * hum_rms) crossed += 48;
    const tick: usize = 1600;
    var pos: usize = 0;
    var first: ?usize = null;
    while (pos + tick <= buf.len) : (pos += tick) {
        a.push(buf[pos .. pos + tick]);
        const r = a.analyse(.{});
        if (r.freq_hz == 0) continue;
        try testing.expectEqual(@as(i32, 45), r.note);
        if (first == null) first = pos + tick;
    }
    errdefer std.debug.print("crossed {d:.3} s, shown {any}\n", .{ @as(f64, @floatFromInt(crossed)) / 48000, first });
    try testing.expect(first.? <= crossed + 9600);
}

test "a string plucked over another still ringing as loud reads the new string within 0.3 s" {
    for ([_][2]f64{ .{ 82.4069, 110 }, .{ 41.2034, 55 } }) |pair| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        const buf = try generate(48000 * 3);
        defer testing.allocator.destroy(buf);
        const other = try generate(48000 * 3);
        defer testing.allocator.destroy(other);
        @memset(buf[0..12000], 0);
        signals.pluckedString(buf[12000..], 48000, .{ .f0 = pair[0], .inharmonicity = 1.1e-4, .t60_s = 6 });
        // From 1 s on, the first string at half its level and the second
        // as loud as that.
        const at = 12000 + 48000;
        const level = 0.5 * signals.rms(buf[at - 4800 .. at]);
        for (buf[at..]) |*v| v.* *= 0.5;
        signals.pluckedString(other[0 .. buf.len - at], 48000, .{ .f0 = pair[1], .inharmonicity = 1.1e-4, .t60_s = 6, .seed = 2 });
        signals.scale(other[0 .. buf.len - at], level / signals.rms(other[0..4800]));
        signals.mix(buf[at..], other[0 .. buf.len - at]);
        signals.addNoise(buf, 3e-5, 9);
        const new_note: i32 = @intFromFloat(@round(69 + 12 * @log2(pair[1] / 440)));
        const tick: usize = 1600;
        var pos: usize = 0;
        var first: ?usize = null;
        while (pos + tick <= buf.len) : (pos += tick) {
            a.push(buf[pos .. pos + tick]);
            const r = a.analyse(.{});
            if (pos + tick <= at or r.freq_hz == 0) continue;
            if (first == null and r.note == new_note) first = pos + tick;
            errdefer std.debug.print("{d} Hz then {d} Hz: {d:.3} s, {d:.2} Hz\n", .{ pair[0], pair[1], @as(f64, @floatFromInt(pos + tick - at)) / 48000, r.freq_hz });
            if (first != null) try testing.expectEqual(new_note, r.note);
        }
        errdefer std.debug.print("{d} Hz then {d} Hz: first {any}\n", .{ pair[0], pair[1], first });
        try testing.expect(first.? <= at + 14400);
    }
}

test "a string with another ringing 15 dB under it in sympathy reads its first partial within 2 cents, not YIN's pulled period" {
    inline for ([_]?f64{ 3, null }) |k| {
        const a = try testing.allocator.create(AnalyserWith(.{ .yin_consistency = k }));
        defer testing.allocator.destroy(a);
        try a.init(48000);
        prime(a);
        const buf = try generate(48000 * 2);
        defer testing.allocator.destroy(buf);
        const other = try generate(48000 * 2);
        defer testing.allocator.destroy(other);
        const note: signals.StringOptions = .{ .f0 = 110, .inharmonicity = 6.5e-5 };
        @memset(buf[0..2400], 0);
        signals.pluckedString(buf[2400..], 48000, note);
        // The open E2 below, 15 dB under over the first half second.
        signals.pluckedString(other[0 .. buf.len - 2400], 48000, .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .t60_s = 10, .seed = 5 });
        signals.scale(other[0 .. buf.len - 2400], signals.rms(buf[2400..26400]) * std.math.pow(f64, 10, -15.0 / 20.0) / signals.rms(other[0..24000]));
        signals.mix(buf[2400..], other[0 .. buf.len - 2400]);
        signals.addNoise(buf, 3e-5, 10);
        var worst: f64 = 0;
        var pos: usize = 0;
        while (pos + 1600 <= buf.len) : (pos += 1600) {
            a.push(buf[pos .. pos + 1600]);
            const r = a.analyse(.{});
            const t = (@as(f64, @floatFromInt(pos + 1600)) - 2400) / 48000;
            if (t < 0.5 or r.freq_hz == 0) continue;
            worst = @max(worst, @abs(centsOff(r, note.firstPartialHz(t))));
        }
        if (k == null) {
            // YIN's period pulls the combination 17 cents.
            try testing.expect(worst > 10);
        } else try testing.expect(worst <= 2);
    }
}

test "a piezo pluck whose body modes make its first readings two octaves under is not held there" {
    var octave_reads = [_]usize{ 0, 0 };
    inline for ([_]bool{ true, false }, 0..) |after_window, which| {
        for ([_]u64{ 1, 2, 3 }) |seed| {
            const a = try testing.allocator.create(AnalyserWith(.{ .hold_after_window = after_window }));
            defer testing.allocator.destroy(a);
            try a.init(48000);
            prime(a);
            const buf = try generate(48000 * 2);
            defer testing.allocator.destroy(buf);
            @memset(buf[0..2400], 0);
            const f0: f64 = 329.628;
            signals.pluckedString(buf[2400..], 48000, .{ .f0 = f0, .inharmonicity = 1.1e-5, .seed = seed });
            // Body modes at 98, 163 and 231 Hz, 12, 8 and 6 dB under the
            // note's first 0.1 s.
            const level = signals.rms(buf[2400..7200]);
            for ([_][3]f64{ .{ 98, 0.6, -12 }, .{ 163, 0.4, -8 }, .{ 231, 0.3, -6 } }) |mode| {
                const amp = level * std.math.pow(f64, 10, mode[2] / 20) * std.math.sqrt2;
                for (buf[2400..], 0..) |*v, i| {
                    const t = @as(f64, @floatFromInt(i)) / 48000;
                    v.* += @floatCast(amp * @exp(-@log(1000.0) / mode[1] * t) * @sin(2 * std.math.pi * mode[0] * t));
                }
            }
            // A 1 ms pick click at the note's peak.
            var peak: f32 = 0;
            for (buf[2400..7200]) |v| peak = @max(peak, @abs(v));
            var rng = signals.MinStd.init(seed + 30);
            for (buf[2400..2448]) |*v| v.* += peak * @as(f32, @floatCast(rng.next()));
            signals.addNoise(buf, 3e-5, 11);
            const note: i32 = @intFromFloat(@round(69 + 12 * @log2(f0 / 440)));
            var pos: usize = 0;
            while (pos + 1600 <= buf.len) : (pos += 1600) {
                a.push(buf[pos .. pos + 1600]);
                const r = a.analyse(.{});
                const t = (@as(f64, @floatFromInt(pos + 1600)) - 2400) / 48000;
                if (t >= 0.1 and r.freq_hz > 0 and (r.note == note - 12 or r.note == note - 24)) octave_reads[which] += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), octave_reads[0]);
    // Anchored on the first two readings, the hold keeps them.
    try testing.expect(octave_reads[1] > 0);
}

test "a piezo note shows no wrong name, even in its first 93 ms" {
    var wrong = [_]usize{ 0, 0 };
    inline for ([_]bool{ true, false }, 0..) |after_window, which| {
        for ([_]f64{ 110, 146.832, 329.628 }) |f0| {
            for ([_]u64{ 1, 2, 3 }) |seed| {
                const a = try testing.allocator.create(AnalyserWith(.{ .names_after_window = after_window }));
                defer testing.allocator.destroy(a);
                try a.init(48000);
                prime(a);
                const buf = try generate(24000);
                defer testing.allocator.destroy(buf);
                @memset(buf[0..2400], 0);
                signals.pluckedString(buf[2400..], 48000, .{ .f0 = f0, .inharmonicity = 6.5e-5, .seed = seed });
                const level = signals.rms(buf[2400..7200]);
                for ([_][3]f64{ .{ 98, 0.6, -12 }, .{ 163, 0.4, -8 }, .{ 231, 0.3, -6 } }) |mode| {
                    const amp = level * std.math.pow(f64, 10, mode[2] / 20) * std.math.sqrt2;
                    for (buf[2400..], 0..) |*v, i| {
                        const t = @as(f64, @floatFromInt(i)) / 48000;
                        v.* += @floatCast(amp * @exp(-@log(1000.0) / mode[1] * t) * @sin(2 * std.math.pi * mode[0] * t));
                    }
                }
                signals.addNoise(buf, 3e-5, 12);
                const note: i32 = @intFromFloat(@round(69 + 12 * @log2(f0 / 440)));
                var pos: usize = 0;
                while (pos + 1600 <= buf.len) : (pos += 1600) {
                    a.push(buf[pos .. pos + 1600]);
                    const r = a.analyse(.{});
                    if (r.freq_hz > 0 and r.note != note) wrong[which] += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong[0]);
    // Shown from the first reading, the body modes flash the octave under.
    try testing.expect(wrong[1] > 0);
}

test "synth notes holding their level at 49.5 Hz and at a pure 120 Hz show, though near mains frequencies" {
    for ([_][2]f64{ .{ 49.5, 1.5 }, .{ 120, 4 } }) |tone| {
        const a = try newAnalyser(48000);
        defer testing.allocator.destroy(a);
        const buf = try generate(48000 * 2);
        defer testing.allocator.destroy(buf);
        @memset(buf[0..12000], 0);
        signals.pluckedString(buf[12000..], 48000, .{ .f0 = tone[0], .inharmonicity = 0, .rolloff = tone[1], .t60_s = 1000, .t60_slope = 0 });
        signals.addNoise(buf, 3e-5, 13);
        const note: i32 = @intFromFloat(@round(69 + 12 * @log2(tone[0] / 440)));
        const r = countNotes(a, buf, 48000, 0.75, note);
        errdefer std.debug.print("{d} Hz: {any}\n", .{ tone[0], r });
        try testing.expect(r.shown >= 35);
        try testing.expectEqual(@as(usize, 0), r.other);
    }
}

test "a comb reading harmonically related to the ringing note is recognised, other intervals are not" {
    for ([_]f64{ 2, 3, 4, 0.5, 1.0 / 3.0, 0.25, 2.01 }) |r| try testing.expect(combRelated(110 * r, 110));
    for ([_]f64{ 4.0 / 3.0, 1.5, 1.2, 1.06 }) |r| try testing.expect(!combRelated(110 * r, 110));
}

test "a note whose reading jumps more than 2 semitones without an onset stops showing instead of showing the jump" {
    // G4 decaying over a steady tone a twelfth under it, 30 dB down at
    // the pluck: as G4 fades, the reading falls to the lower tone with no
    // onset between.
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 4);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 4);
    defer testing.allocator.destroy(other);
    @memset(buf[0..12000], 0);
    signals.pluckedString(buf[12000..], 48000, .{ .f0 = 391.995, .inharmonicity = 3e-5, .t60_s = 2 });
    const level = signals.rms(buf[12000..16800]);
    signals.sine(other[0 .. buf.len - 12000], 48000, 130.665, level * std.math.sqrt2 * std.math.pow(f64, 10, -30.0 / 20.0), 0);
    signals.mix(buf[12000..], other[0 .. buf.len - 12000]);
    signals.addNoise(buf, 3e-5, 14);
    const r = countNotes(a, buf, 48000, 0, 67);
    errdefer std.debug.print("{any}\n", .{r});
    try testing.expect(r.shown > 10);
    try testing.expectEqual(@as(usize, 0), r.other);
}

test "a showing note keeps its name with no gap through a soft re-pluck of the same string" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000 * 2);
    defer testing.allocator.destroy(buf);
    const other = try generate(48000 * 2);
    defer testing.allocator.destroy(other);
    @memset(buf[0..2400], 0);
    const opts: signals.StringOptions = .{ .f0 = 55, .inharmonicity = 2e-4, .t60_s = 8 };
    signals.pluckedString(buf[2400..], 48000, opts);
    // At 1 s the string is damped to half and plucked again 10 dB under
    // its level then, 8 cents sharp.
    const at = 2400 + 48000;
    const level = signals.rms(buf[at - 4800 .. at]);
    for (buf[at..]) |*v| v.* *= 0.5;
    var again = opts;
    again.f0 *= std.math.pow(f64, 2, 8.0 / 1200.0);
    again.seed = 3;
    signals.pluckedString(other[0 .. buf.len - at], 48000, again);
    signals.scale(other[0 .. buf.len - at], level * std.math.pow(f64, 10, -10.0 / 20.0) / signals.rms(other[0..4800]));
    signals.mix(buf[at..], other[0 .. buf.len - at]);
    signals.addNoise(buf, 3e-5, 15);
    var pos: usize = 0;
    var gaps: usize = 0;
    while (pos + 1600 <= buf.len) : (pos += 1600) {
        a.push(buf[pos .. pos + 1600]);
        const r = a.analyse(.{});
        const t = (@as(f64, @floatFromInt(pos + 1600)) - 2400) / 48000;
        if (t >= 0.9 and t <= 1.4 and (r.freq_hz == 0 or r.note != 33)) gaps += 1;
    }
    try testing.expectEqual(@as(usize, 0), gaps);
}

test "while a new note's name is held back the reading says it is starting, and silence never does" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(48000);
    defer testing.allocator.destroy(buf);
    @memset(buf[0..9600], 0);
    signals.pluckedString(buf[9600..], 48000, .{ .f0 = 110, .inharmonicity = 6.5e-5 });
    signals.addNoise(buf, 3e-5, 16);
    var starting: usize = 0;
    var first_shown: ?f64 = null;
    var pos: usize = 0;
    while (pos + 1600 <= buf.len) : (pos += 1600) {
        a.push(buf[pos .. pos + 1600]);
        const r = a.analyse(.{});
        const t = (@as(f64, @floatFromInt(pos + 1600)) - 9600) / 48000;
        if (t <= 0) try testing.expect(!r.starting);
        if (r.starting) {
            try testing.expectEqual(@as(f64, 0), r.freq_hz);
            try testing.expect(first_shown == null);
            starting += 1;
        }
        if (r.freq_hz > 0 and first_shown == null) first_shown = t;
    }
    try testing.expect(starting >= 2);
    try testing.expect(first_shown.? <= 0.15);
}

test "an onset that shows no note expires, so without the slow onset a swell over hum long after a click never shows" {
    const a = try testing.allocator.create(AnalyserWith(.{ .slow_onset_db = null }));
    defer testing.allocator.destroy(a);
    try a.init(48000);
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

test "a change of silence threshold or range takes effect at once, without new input" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(24000);
    defer testing.allocator.destroy(buf);
    // 220 Hz at about -43 dBFS RMS.
    signals.sine(buf, 48000, 220, 0.01, 0);
    a.push(buf);
    // Too quiet for -30 first: nothing; then -90 shows it with no new input.
    try testing.expectEqual(@as(f64, 0), a.analyse(.{ .silence_db = -30 }).freq_hz);
    try testing.expectApproxEqAbs(@as(f64, 0), centsOff(a.analyse(.{ .silence_db = -90 }), 220), 0.05);
    try testing.expectEqual(@as(f64, 0), a.analyse(.{ .silence_db = -30 }).freq_hz);
    try testing.expectApproxEqAbs(@as(f64, 0), centsOff(a.analyse(.{ .silence_db = -90 }), 220), 0.05);
    try testing.expectEqual(@as(f64, 0), a.analyse(.{ .range = .{ .low_hz = 400, .high_hz = 800 } }).freq_hz);
    try testing.expectApproxEqAbs(@as(f64, 0), centsOff(a.analyse(.{}), 220), 0.05);
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

test "one absurd sample doesn't silence the analyser, at 44.1 or 48 kHz" {
    for ([_]f64{ 44100, 48000 }) |sr| {
        const a = try newAnalyser(sr);
        defer testing.allocator.destroy(a);
        const buf = try generate(96000);
        defer testing.allocator.destroy(buf);
        const n: usize = @intFromFloat(2 * sr);
        signals.sine(buf[0..n], sr, 220, 0.3, 0);
        buf[@intFromFloat(0.5 * sr)] = 1e10;
        const tick: usize = @intFromFloat(@round(sr / 30));
        var k: usize = 0;
        while ((k + 1) * tick <= n) : (k += 1) {
            a.push(buf[k * tick .. (k + 1) * tick]);
            const r = a.analyse(.{});
            if (@as(f64, @floatFromInt((k + 1) * tick)) / sr < 0.8) continue;
            errdefer std.debug.print("{d} at {d} s: {any}\n", .{ sr, @as(f64, @floatFromInt((k + 1) * tick)) / sr, r });
            try testing.expectApproxEqAbs(@as(f64, 0), centsOff(r, 220), 0.01);
        }
    }
}

test "the window's level after loud bursts is that of the quiet input left in it, at 44.1 kHz" {
    const a = try newAnalyser(44100);
    defer testing.allocator.destroy(a);
    var buf: [4410]f32 = undefined;
    for (0..100) |k| {
        @memset(&buf, 0);
        signals.addNoise(&buf, if (k % 7 == 0) 300 else 1e-4, k + 1);
        a.push(&buf);
    }
    // The window now holds only the last 1e-4 RMS noise: -80 dBFS.
    try testing.expectApproxEqAbs(@as(f64, -80), a.windowLevelDb(), 0.2);
}

test "after reset, the analyser reads new input exactly as a fresh one does" {
    const used = try bareAnalyser(48000);
    defer testing.allocator.destroy(used);
    const fresh = try bareAnalyser(48000);
    defer testing.allocator.destroy(fresh);
    const buf = try generate(96000);
    defer testing.allocator.destroy(buf);
    const other = try generate(96000);
    defer testing.allocator.destroy(other);
    // Earlier input: buzz, then a note over it, so every state is used.
    signals.mains(buf, 48000, 60, .buzz, -40);
    signals.pluckedString(other[24000..], 48000, .{ .f0 = 110, .inharmonicity = 6.5e-5 });
    signals.mix(buf, other);
    var k: usize = 0;
    while ((k + 1) * 1600 <= buf.len) : (k += 1) {
        used.push(buf[k * 1600 .. (k + 1) * 1600]);
        _ = used.analyse(.{});
    }
    used.reset();
    // New input: silence, then E2.
    @memset(buf, 0);
    signals.pluckedString(buf[12000..], 48000, .{ .f0 = 82.4069, .inharmonicity = 1.1e-4 });
    k = 0;
    while ((k + 1) * 1600 <= buf.len) : (k += 1) {
        used.push(buf[k * 1600 .. (k + 1) * 1600]);
        fresh.push(buf[k * 1600 .. (k + 1) * 1600]);
        try testing.expectEqual(fresh.analyse(.{}), used.analyse(.{}));
    }
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

test "a range outside the analyser's own is clamped to it, an unusable limit ignored, and an empty one reads nothing" {
    const a = try newAnalyser(48000);
    defer testing.allocator.destroy(a);
    const buf = try generate(24000);
    defer testing.allocator.destroy(buf);
    signals.sawtooth(buf, 48000, 110, 0.3);
    a.push(buf);
    const ranges = [_]Range{
        .{ .low_hz = 1e-20, .high_hz = 1e20 },
        .{ .low_hz = -5, .high_hz = std.math.inf(f64) },
        .{ .low_hz = std.math.nan(f64), .high_hz = std.math.nan(f64) },
    };
    for (ranges) |rg| {
        errdefer std.debug.print("{any}\n", .{rg});
        try testing.expectApproxEqAbs(@as(f64, 0), centsOff(a.analyse(.{ .range = rg }), 110), 0.05);
    }
    for ([_]Range{ .{ .low_hz = 500, .high_hz = 400 }, .{ .low_hz = 0, .high_hz = 1e-20 } }) |rg| {
        errdefer std.debug.print("{any}\n", .{rg});
        try testing.expectEqual(@as(f64, 0), a.analyse(.{ .range = rg }).freq_hz);
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
