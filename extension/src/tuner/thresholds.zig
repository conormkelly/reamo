//! Every tuned threshold and constant of the tuner's analyser, in one
//! place: what each means, its unit, and how the targets bench answers
//! when it moves. pitch.zig's Options take their defaults from here, and
//! pitch.zig, several.zig, hum.zig and first_partial.zig read the rest
//! from here.
//!
//! `version` goes up whenever any value here changes, so a set of
//! measurements can name the thresholds it was made with.
//!
//! "Sweep" notes come from `zig build tuner-targets -- sweep`, one value
//! moved at a time with the rest at their defaults. They were measured
//! with names shown from the first reading; showing no name until the
//! window is past the onset moves lock-on alone. "Plateau" means every
//! target that held at the default still held; "breaks" names the first
//! target to fail on each side. Values not swept say so.

/// Bumped on any change to a value below.
pub const version = 6;

/// The analysis window and YIN.
pub const yin = struct {
    /// The window, seconds (the JSFX's 4096 samples at 44.1 kHz).
    pub const window_s = 4096.0 / 44100.0;
    /// The shortest period searched, as a frequency, Hz.
    pub const max_pitch_hz = 2000.0;
    /// Input low-pass cut-off, Hz (also the anti-alias filter before
    /// decimation to 48 kHz or under). Not swept.
    pub const lowpass_hz = 2000.0;
    /// Absolute threshold on the normalised difference: the first dip
    /// under it is the period. Sweep: plateau 0.15 only. At 0.05, 628
    /// octave readings; at 0.25, sympathetic-string notes renamed (0 to
    /// 14) and bias -15 c; at 0.35, false notes and lock-on fail too.
    pub const dip = 0.15;
    /// With no dip under `dip`, the deepest is the period only if under
    /// this; otherwise no pitch. Sweep: plateau 0.3 only. At 0.2 and 0.1,
    /// lock-on fails (50.4 and 57.4 ms average); at 0.4 and 0.5, false
    /// notes (268 and 424 reads).
    pub const voicing = 0.3;
    /// The subharmonic check: a dip at least this deep (normalised) ...
    pub const subharmonic_min_dip = 0.03;
    /// ... gives way to a raw-difference dip near twice its lag under this
    /// share of it. Not swept.
    pub const subharmonic_ratio = 0.25;
    /// Without hum, the longer period also needs a partial near its
    /// frequency within this of the strongest, dB: bass whose 2nd partial
    /// stands 12-17 dB over a weak fundamental has one; a clean note has
    /// nothing at half its pitch within 35 dB. Not swept.
    pub const subharmonic_confirm_db = 25.0;
};

/// The first-partial refinement and its combination with YIN.
pub const refine = struct {
    /// The phase slope is fitted over at most this much input since the
    /// onset, seconds (0.2 is too short for B0, 0.4 lags a turning peg).
    /// Not swept here; the refine-0.2s and refine-0.4s candidates measure
    /// its neighbours.
    pub const window_s = 0.3;
    /// Its input rate is from this up to twice it, Hz.
    pub const fine_rate_floor = 11025.0;
    /// YIN's standard error assumed in the combination, cents. Not swept.
    pub const yin_sigma_cents = 1.0;
    /// The first partial is reported alone when it and YIN differ by more
    /// than this many combined standard errors. Not swept; 1.5, 2 and 3
    /// gave the same worst error on the sympathetic-string unit test.
    pub const yin_consistency = 3.0;
    /// A phase fit whose residual exceeds this RMS, radians, has no
    /// standard error (infinite). Not swept.
    pub const max_residual_rad = 0.25;
};

/// What starts a note.
pub const onset = struct {
    /// An onset is a block with this many dB more energy than the mean of
    /// the blocks 10 to 40 ms before it (8 times). Sweep: plateau from -3
    /// to +6 dB around it for the targets that held; -3 dB already adds
    /// flicker spikes (worst 66.8 c) and hum-under-note coverage 88.6%;
    /// at -6 dB glide and steady P95 fail, 8 false notes and 6 starts
    /// missed. The lower side breaks first.
    pub const jump_db = 9.030899869919435;
    /// Block length, seconds.
    pub const block_s = 0.005;
    /// Blocks kept: the one compared and those 10 to 40 ms before it.
    pub const history = 8;
    /// No onset within this long of the last, seconds.
    pub const refractory_s = 0.05;
    /// An onset starts a note only within this long of the first analysis
    /// that saw it, seconds.
    pub const life_s = 0.25;
    /// With no note showing, the window level rising this many dB over its
    /// lowest of the last `rise_span_s` is an onset (a swell). Sweep:
    /// plateau 12 to 15 dB; at 9 and 6 dB, 12 swells missed; at 18 dB, 31.
    pub const rise_db = 12.0;
    /// How far back the rise looks, seconds, over the lowest window level
    /// in each of `rise_buckets` spans. Not swept.
    pub const rise_span_s = 2.0;
    pub const rise_buckets: usize = 40;
    /// A rise starts where the level last stood within this of its
    /// lowest, dB. Not swept.
    pub const rise_quiet_db = 3.0;
};

/// The gate: what keeps a note showing.
pub const gate = struct {
    /// A note shows only while the window level stands this many dB over
    /// the learned floor. Sweep: plateau 12 dB only. At 9 dB, 119 octave
    /// readings; at 15 dB, 14 swells missed
    /// and hum-under-note coverage falls to 80.2%. Both sides break
    /// within 3 dB: the value to check first on real input.
    pub const floor_margin_db = 12.0;
    /// The floor follows the level down at once and up at this, dB/s.
    /// Not swept.
    pub const floor_rise_db_per_s = 20.0;
    /// An onset holds the floor this long if no note shows, seconds.
    pub const onset_floor_hold_s = 0.25;
    /// A note that drops out with the level still up may resume within
    /// this, seconds. Not swept.
    pub const resume_s = 0.25;
    /// The release check: the latest `release_s` (longer than B0's
    /// period) must hold energy within `release_drop_db` of the window's
    /// mean. Sweep of the drop: plateau from 14 to 26 dB, nothing moved.
    pub const release_s = 0.04;
    pub const release_drop_db = 20.0;
    /// Input samples beyond this magnitude are taken for silence.
    pub const max_sample = 1000.0;
};

/// Mains hum and buzz that switch on.
pub const mains = struct {
    /// Readings within `first_cents / k` of k x 50 or 60 Hz (k up to 4,
    /// and readings up to `reading_max_hz`) whose input repeats at the
    /// mains period wait to start until their level falls. Not swept.
    pub const first_cents = 45.0;
    pub const reading_max_hz = 4 * 60 * 1.02;
    /// Repeats at the mains period: normalised difference under
    /// `periodic_max` at a lag within `period_tolerance` of 1/50 or 1/60
    /// s, over at least `periodic_min_s`. 0.5% is the grids' own range
    /// (49.75-50.25 Hz; Ireland runs 49.8-50.2): at 1%, synth notes
    /// held at 49.5-49.6 Hz never showed. Not swept.
    pub const period_tolerance = 0.005;
    /// The lag the input repeats at best is looked for within this of the
    /// mains period, and must fall within `period_tolerance` of it.
    pub const search_span = 0.03;
    pub const periodic_max = 0.01;
    pub const periodic_min_s = 0.005;
    /// The level is seen to fall: by `fall_db` over each of the last two
    /// `fall_s` spans, and `decay_db` under the loudest of the last
    /// `hold_s`. Not swept.
    pub const fall_s = 0.1;
    pub const fall_db = 0.1;
    pub const decay_db = 1.0;
    pub const hold_s = 1.0;
    /// An onset the mains hold is waiting on lives this long, seconds,
    /// rather than `onset.life_s`: a falling level is seen only 0.28-0.45
    /// s after the onset, and a note that hasn't fallen by then is held.
    pub const wait_s = 1.0;
    /// The mains rule (off by default): a note within this many cents of
    /// a mains harmonic that hasn't decayed stops showing.
    pub const rule_cents = 15.0;
};

/// The learned hum (hum.zig).
pub const hum = struct {
    /// Learned every `hop_s` of idle input (every `relearn_s` once two
    /// learns agree), from between `learn_min_s` and `learn_max_s` of it,
    /// seconds. Not swept.
    pub const learn_min_s = 0.15;
    pub const learn_max_s = 0.5;
    pub const hop_s = 0.05;
    pub const relearn_s = 0.25;
    /// Two learns agree within this mains frequency, Hz, and this level
    /// of their strongest harmonic, dB. Not swept.
    pub const agree_hz = 0.05;
    pub const agree_db = 1.5;
    /// Harmonics fitted up to this, Hz.
    pub const top_hz = 2000.0;
    /// A harmonic is kept at this many times the median amplitude between
    /// harmonics (12 dB).
    pub const over_noise = 4.0;
    /// Amplitude and phase from the last this-much of the input, seconds;
    /// the frequency from slopes of the strongest `slope_harmonics` and
    /// half-window advances of `advance_harmonics`.
    pub const tail_s = 0.15;
    pub const slope_harmonics = 3;
    pub const advance_harmonics = 4;
};

/// The several-notes guard (several.zig). Not swept.
pub const several = struct {
    /// A strong peak is within this many dB of the strongest.
    pub const strong_db = 20.0;
    /// A harmonic is present if a local maximum near it is within
    /// `present_db` of the strongest peak and `over_floor` (as a power
    /// ratio) over the noise floor.
    pub const present_db = 50.0;
    pub const over_floor = 10.0;
    /// Peaks match harmonics within 30 cents plus a stiff string's
    /// stretch at this inharmonicity.
    pub const max_inharmonicity = 1.5e-3;
    /// Two partials are told apart only this many main-lobe half-widths
    /// apart.
    pub const resolution = 2.0;
};

/// Holds and the flags on a reading.
pub const hold = struct {
    /// A jump by 2, 3 or 4 times is held until this many analyses in a
    /// row make it. Not swept.
    pub const octave_analyses = 3;
    /// `settling` for this long after an onset or a jump, seconds.
    pub const settle_s = 0.12;
    /// `stable` needs the shown pitch's least-squares slope over
    /// `stable_s` under `stable_cents_per_s`, and its RMS about that line
    /// under `stable_spread_cents`. Not swept.
    pub const stable_s = 0.3;
    pub const stable_cents_per_s = 0.5;
    pub const stable_spread_cents = 0.1;
    /// Without a new onset, a showing note's reading may move at most this
    /// far between analyses, cents; a bigger jump stops the note. A peg
    /// turn moves a few cents per analysis. Not swept.
    pub const jump_cents = 200.0;
    /// Two readings within this are the same note's (a quarter tone),
    /// cents.
    pub const quarter_tone_cents = 50.0;
    /// While a later onset is unproven, a showing note's reading that has
    /// moved this far, cents, is from a window mixing it with whatever
    /// came, and shows no name (a re-plucked string moves a few cents; the
    /// mixed window that read E2 47 c flat as G4 came in did not).
    pub const mixed_cents = 25.0;
    /// The Hampel filter (smoothing, off by default): `hampel_len`
    /// analyses, replacing a reading 3 scaled MADs and at least
    /// `hampel_floor_cents` from the median.
    pub const hampel_len = 5;
    pub const hampel_floor_cents = 1.0;
};
