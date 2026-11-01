//! The tuner's accuracy targets, measured on strings whose first partial
//! is known exactly: `zig build tuner-targets -Doptimize=ReleaseFast` (or
//! `ReleaseSafe`; CPU figures from a Debug build mean nothing). A name
//! passed after `--` runs only the candidates whose name contains it; a
//! second name runs only the signals whose name contains it and prints
//! every reading of each (`-- analyser "E2 weak"`).
//!
//! The error is always against the true first partial f1 at the moment of
//! the reading (`sig.StringOptions.firstPartialHz`), never against n f0 or
//! a detector's period. The targets were fixed before the analyser was
//! changed to meet them (see `targets` below) and are not tuned to it.
//!
//! Every signal has a white noise floor at -90 dBFS RMS. A plucked signal
//! is 0.25 s of that floor, then the pluck (the onset), then 3 s of
//! sustain; the other signals are 3.25 s of hum, noise or muted strokes.
//! Every candidate hears the input in 256-sample blocks and is read every
//! sample_rate / 30 samples, as the tuner reads it, at 44.1, 48, 88.2 and
//! 96 kHz.
//!
//! A reading shows a note name, and cents unless it is still settling.
//! Measures, with t the time of a reading after the onset:
//!
//! - Error: cents from f1(t) to the shown frequency, for readings from
//!   t = 1 s to 3 s. A reading without cents in that span counts as an
//!   infinite error, so a candidate can't pass by saying nothing. The 95th
//!   percentile of |error| is pooled over a group's signals and rates.
//! - Jitter: the standard deviation of a sustained signal's error over the
//!   same 2 s; the worst signal's.
//! - Hum under a note: the error from t = 1 s on strings near the mains
//!   and its harmonics with hum or buzz under them, over the readings
//!   shown (the gate stops a note at 12 dB over the hum on purpose), with
//!   the share shown alongside, which must not fall under the analyser's
//!   89.0% at 57c6d9c.
//! - Single strings flagged several: readings flagged `multiple` on any
//!   one-string signal, from t = 0.1 s.
//! - Leading the report, what a player notices: time from the onset until
//!   the reading stays within 1 and 0.5 cent of f1(t), flicker (the
//!   error's spread over readings flagged stable), note-name changes per
//!   note, false-note events per idle minute, notes with an octave
//!   reading, the share shown, and the signed bias per string.
//! - Reported beside the targets, not targets: the pooled groups apart
//!   (stiff and weak, guitar and bass glides), glide errors from 0.5 s, and
//!   a Karplus-Strong pluck whose fundamental starts 20 dB under its
//!   octave (its octave readings count towards the octave-error target).
//! - Octave errors: readings from t = 0.1 s whose note is 11-13, 23-25 or
//!   35-37 semitones from f1(t)'s.
//! - False notes: readings that show a note on a signal with none.
//! - Two notes: readings from t = 0.1 s that show a note more than a
//!   semitone under the lower string's without flagging several notes,
//!   the common subharmonic a period detector can lock to.
//! - Ramp: a peg turned while the string rings; the error from t = 0.5 s,
//!   against f1(t) as it moves.
//! - Lock-on: from the onset to the first reading from which every reading
//!   to t = 1.5 s shows f1(t)'s note.
//! - Time to stable: from the onset to the first reading from which every
//!   reading to t = 3 s shows cents within 1 cent of the settled f1 (the
//!   glide's nu_inf), and to the first reading flagged stable.
//! - CPU: push() per second of input and the mean analyse() time on a
//!   sustained string, read at 30 Hz, as one core's share.
//! - Per-tick cost (1/30 s pushed, then one reading) while no onset has
//!   been heard and after one, the least of three runs per tick.
const std = @import("std");
const builtin = @import("builtin");
const sig = @import("signals.zig");
const jsfx = @import("jsfx_port.zig");
const pitch = @import("pitch.zig");

/// The pre-registered targets.
const targets = struct {
    /// 95th percentile |error| on gliding strings, t >= 1 s.
    const glide_p95_cents = 0.5;
    /// 95th percentile |error| on sustained stiff strings with no glide
    /// (bright, mellow and weak-fundamental spectra), t >= 1 s.
    const steady_p95_cents = 0.1;
    /// 95th percentile |error| on strings whose two polarisations beat.
    /// The truth is the stronger polarisation's f1, but the instantaneous
    /// frequency of two components Delta cents apart, the weaker at gain
    /// g, swings between -g / (1 - g) Delta and g / (1 + g) Delta about it
    /// (-0.21 to +0.12 cent here), so these strings are held to the glide
    /// target rather than the steady one.
    const beating_p95_cents = 0.5;
    /// Standard deviation of the shown cents over 2 s of a sustained,
    /// non-gliding string (stiff, weak-fundamental and beating), worst
    /// signal.
    const jitter_cents = 0.1;
    const octave_errors = 0;
    const false_notes = 0;
    const confident_subharmonics = 0;
    /// Ramp error allowance: this much, plus what the ramp moves in
    /// `ramp_lag_s` (the smoothing may lag a turning peg by that long).
    const ramp_cents = 0.5;
    const ramp_lag_s = 0.15;
    /// Lock-on (note name) average and worst, ms: no slower than the
    /// analyser at d759e43 (`baseline` below, measured by this bench).
    const lock_avg_ms = baseline.lock_avg_ms;
    const lock_worst_ms = baseline.lock_worst_ms;
    /// 95th percentile |error| on strings with mains hum or buzz under them
    /// (`hum_target`), t >= 1 s, over the readings shown. Missing readings
    /// don't count here, unlike the other error targets: the gate stops
    /// showing a note on purpose once it is within 12 dB of the learned
    /// floor, which here is the hum, and counting that as an error would
    /// set this target against the false-notes one. Coverage is reported.
    const hum_p95_cents = 0.5;
    /// The share of hum_target readings shown from 1 s to 3 s must stay at
    /// least the analyser's at 57c6d9c (89.0%), so the hum target can't be
    /// met by gating harder.
    const hum_coverage_pct = 89.0;
    /// The same for hum_drift (strings under changing hum), its coverage
    /// at least the analyser's at registration (`drift_coverage_pct`).
    const drift_p95_cents = 0.5;
    const drift_coverage_pct = baseline.drift_coverage_pct;
    /// Starts: every note in `starts` shows its note name within this of
    /// its pluck. Swells: every note in `swells` within `swell_show_s` of
    /// its level standing 12 dB over the floor, and from 0.5 s after that
    /// P95 <= `swell_p95_cents` against f1.
    const start_show_s = 0.3;
    const swell_show_s = 0.2;
    const swell_p95_cents = 0.5;
    /// The held-out corpora's findings, on dev cases made from their
    /// summaries. Body modes and sympathetic strings: no octave reading
    /// (from 0.1 s) and no note's name changing once shown; sympathetic
    /// strings also P95 <= `sympathetic_p95_cents` against f1 from 1 s.
    /// Beating polarisations against the composite truth: median time to
    /// stay within 1 cent <= `polar_settle_guitar_s` on guitar and
    /// `polar_settle_bass_s` on bass, at most `polar_never_pct` of notes
    /// never there, and the spread over stable readings at P90 <=
    /// `polar_flicker_cents`. Fretted bass and sympathetic strings: no
    /// signal's mean error from 1 s over `finding_bias_cents`.
    const sympathetic_p95_cents = 0.5;
    const polar_settle_guitar_s = 0.5;
    const polar_settle_bass_s = 1.0;
    const polar_never_pct = 10.0;
    const polar_flicker_cents = 0.15;
    const finding_bias_cents = 0.2;
    /// A wrong note name is worse than about 60 ms of delay: no note in
    /// the body group renamed once shown, and no reading from the onset
    /// on whose name isn't f1(t)'s on any one-string signal (ramps
    /// crossing a note's edge excepted, and the two-notes case judged by
    /// its own rule), with lock-on outside the finding groups held at
    /// its 42.6 / 83.3 ms; the body group's lock-on is reported.
    const wrong_names = 0;
    /// Never green while wrong: no reading in hum_drift flagged stable
    /// more than 0.5 cent off f1(t).
    const drift_stable_wrong = 0;
    /// And no false alarms where the hum holds still: readings flagged
    /// stable in hum_target and hum_note together at least as many as at
    /// registration.
    const steady_hum_stable = baseline.steady_hum_stable;
    /// Readings flagged `multiple` on a single string (with or without hum
    /// under it): a flagged reading that shows nothing must not be a free
    /// way round the subharmonic target.
    const single_flagged = 0;
    /// Per 30 Hz tick (1/30 s pushed, then one reading), at 48 and 96 kHz:
    /// the mean while no onset has been heard (a tuner opened over a note
    /// already ringing, or over hum) at most this many times the mean after
    /// one, and every tick in either state under `tick_worst_us`.
    const tick_idle_ratio = 2.0;
    const tick_worst_us = 1000.0;
    /// One core's share at 30 Hz, at 48 and 96 kHz.
    const cpu_percent = 1.0;
};

/// The analyser at d759e43 (YIN with the 2 kHz low-pass, the fixed 92.9
/// ms window and the 0.3 voicing gate), on this bench in ReleaseFast,
/// rounded up to 0.1 ms.
const baseline = struct {
    /// hum_drift's share shown from 1 s to 3 s at registration.
    const drift_coverage_pct = 95.5;
    /// Readings flagged stable in hum_target and hum_note at registration.
    const steady_hum_stable: usize = 17772;
    const lock_avg_ms = 42.7;
    const lock_worst_ms = 83.4;
};

const rates = [_]f64{ 44100, 48000, 88200, 96000 };
const lead_s: f64 = 0.25;
const sustain_s: f64 = 3.0;
const noise_floor_db: f64 = -90.0;

// ---------------------------------------------------------------------------
// Signals

const Group = enum {
    /// Sustained stiff strings, bright and mellow, no glide.
    stiff,
    /// Stiff strings whose fundamental is 20 dB under the octave.
    weak,
    /// Stiff strings whose two polarisations beat.
    beating,
    /// Stiff strings plucked at a third of their length: no 3rd or 6th
    /// partial (single strings for the several-notes flag; reported, no
    /// error target of their own).
    third,
    /// Guitar strings gliding down 2.6 or 10 cents, tau 0.3 s.
    glide_guitar,
    /// Bass strings gliding down from 4 or 9.6 cents, tau 0.6 s (up to 16
    /// cents a second).
    glide_bass,
    /// A string whose peg is turned while it rings.
    ramp,
    /// A sustained string with mains hum or buzz under it.
    hum_note,
    /// Bass and low guitar strings near the mains or its harmonics, with
    /// 50 or 60 Hz hum or buzz at -60 dBFS, or 30 or 40 dB under the note.
    hum_target,
    /// Two strings at once.
    two_notes,
    /// The Karplus-Strong 880 Hz pluck whose excitation leaves its
    /// fundamental 20 dB under the octave and its 3rd harmonic weak (seed
    /// 1014), with no range set.
    ks_weak,
    /// Strings under hum that drifts, steps, jumps, switches pickups or
    /// comes in bursts.
    hum_drift,
    /// Such hum alone.
    hum_drift_idle,
    /// Notes that clearly start but have no plain attack after silence: a
    /// soft re-pluck over a ringing string, compressed attacks, a palm-
    /// muted pluck that then rings, fingerstyle; each must show its note
    /// within `start_show_s`.
    starts,
    /// Swells, e-bow, bowed and pad attacks: each must show within
    /// `swell_show_s` of its level reaching 12 dB over the floor.
    swells,
    /// Bass tones with partial 2 12 or 17 dB over partial 1 and partial 3
    /// weak (a bridge pickup's or a miked amp's spectrum): counted towards
    /// octave errors, not towards lock-on.
    bass_h2,
    /// Strings through an acoustic's piezo: three body modes between 90
    /// and 250 Hz, not harmonic, at -20 to -6 dB under the note, and a
    /// pick click.
    body,
    /// A string with other open strings ringing in sympathy 15-30 dB under
    /// it.
    sympathetic,
    /// Strings whose two polarisations lie 0.35-3.5 cent apart and decay
    /// 1.2-3 times apart, the louder one at the pluck dying first in some,
    /// judged against both together (the composite truth).
    polar,
    /// Bass B0 open and fretted to the 21st fret, inharmonicity 2-4e-4
    /// open (rising as 1 / length^2), every partial gliding down from
    /// the pluck's tension.
    bass_fret,
    /// Hum or buzz alone.
    hum,
    /// A noise floor alone.
    noise,
    /// Fretting-hand-muted strokes.
    muted,

    fn pitched(g: Group) bool {
        return switch (g) {
            .hum, .noise, .muted, .two_notes, .hum_drift_idle, .starts, .swells => false,
            else => true,
        };
    }

    /// The groups made from the held-out corpora's findings: judged by
    /// their own targets, kept out of the pooled ones and the player's
    /// table so those stay comparable.
    fn finding(g: Group) bool {
        return switch (g) {
            .body, .sympathetic, .polar, .bass_fret => true,
            else => false,
        };
    }
};
const groups = std.enums.values(Group);

const Hum = struct {
    hz: f64,
    kind: sig.Mains,
    /// Drift, steps, a phase jump or switching (none by default).
    change: ?sig.MainsChange = null,
    /// dBFS RMS, or with `relative` dB from the note's RMS over its first
    /// second.
    db: f64,
    relative: bool = false,
};

const Background = enum { bare, noise, hum };

const Case = struct {
    name: []const u8,
    group: Group,
    strings: [2]?sig.StringOptions = .{ null, null },
    hum: ?Hum = null,
    /// White noise RMS, dBFS (the -90 dB floor is always there).
    noise_db: ?f64 = null,
    /// Low-passed noise RMS, dBFS.
    rumble_db: ?f64 = null,
    /// f0 of a muted string struck four times.
    muted_hz: ?f64 = null,
    /// Shapes strings[0]'s level over time after its onset.
    envelope: ?Envelope = null,
    /// Plays strings[1] from this many seconds after the onset, not with
    /// strings[0] (a second pluck), at `second_db` against strings[0]'s RMS
    /// over the 0.1 s before it; strings[0] is halved from then on (the
    /// re-plucked string damped, or the hand resting on the ringing one).
    second_at_s: ?f64 = null,
    second_db: f64 = 0,
    /// Adds low-passed noise under the first `bow_s` of the note (a bow's
    /// scrape) at -30 dB against it.
    bow_s: ?f64 = null,
    /// Body modes under strings[0]: dB under the note's RMS over its first
    /// 0.1 s for modes at 98, 163 and 231 Hz (t60 0.6, 0.4 and 0.3 s),
    /// with a 1 ms pick click at the note's peak.
    body_db: ?[3]f64 = null,
    /// strings[1] rings in sympathy this many dB under strings[0]'s RMS
    /// over its first 0.5 s, rising over 50 ms from the onset.
    sympathetic_db: ?f64 = null,
    /// A pickup switch's click (5 ms of noise at peak 0.03) at this time.
    click_at_s: ?f64 = null,
    /// Render strings[0] as a Karplus-Strong pluck (t60 3 s, peak 0.9) with
    /// this seed instead; its fundamental is at f0 exactly.
    ks_seed: ?u64 = null,
};

const Str = struct { name: []const u8, f0: f64, b: f64 };

/// A level envelope over a note, t seconds after its onset.
const Envelope = union(enum) {
    /// Rising linearly in amplitude from 0 over this many seconds.
    linear: f64,
    /// Rising from -60 dB, linearly in dB, over this many seconds.
    exponential: f64,
    /// A palm mute lifted: from 1 down to a tenth with a 30 ms time constant.
    palm,

    fn gain(e: Envelope, t: f64) f64 {
        return switch (e) {
            .linear => |d| @min(1, t / d),
            .exponential => |d| std.math.pow(f64, 10, @min(0, -60 + 60 * t / d) / 20),
            .palm => 0.1 + 0.9 * @exp(-t / 0.03),
        };
    }
};

/// The TU Munich electric-guitar B values (the research's table).
const guitar = [_]Str{
    .{ .name = "E2", .f0 = 82.4069, .b = 1.1e-4 },
    .{ .name = "A2", .f0 = 110.0, .b = 6.5e-5 },
    .{ .name = "D3", .f0 = 146.832, .b = 4.5e-5 },
    .{ .name = "G3", .f0 = 195.998, .b = 8.4e-5 },
    .{ .name = "B3", .f0 = 246.942, .b = 2.9e-5 },
    .{ .name = "E4", .f0 = 329.628, .b = 1.1e-5 },
};
/// High E fretted at 12 and 24: B scales with 1 / length^2.
const guitar_high = [_]Str{
    .{ .name = "E5", .f0 = 659.255, .b = 4.4e-5 },
    .{ .name = "E6", .f0 = 1318.51, .b = 1.8e-4 },
};
/// Open bass strings (B assumed 2e-4: "low" for open strings per Kemp
/// 2020, no figure published) and fretted ones at about 1e-3.
const bass = [_]Str{
    .{ .name = "B0", .f0 = 30.8677, .b = 2e-4 },
    .{ .name = "E1", .f0 = 41.2034, .b = 2e-4 },
    .{ .name = "A1", .f0 = 55.0, .b = 2e-4 },
    .{ .name = "D2", .f0 = 73.4162, .b = 2e-4 },
    .{ .name = "G2", .f0 = 97.9989, .b = 2e-4 },
};
const bass_fretted = [_]Str{
    .{ .name = "B1f", .f0 = 61.7354, .b = 1e-3 },
    .{ .name = "E2f", .f0 = 82.4069, .b = 1e-3 },
};
/// E2 across the B range.
const sweep = [_]Str{
    .{ .name = "E2 B1e-5", .f0 = 82.4069, .b = 1e-5 },
    .{ .name = "E2 B3e-4", .f0 = 82.4069, .b = 3e-4 },
};

fn isBass(f0: f64) bool {
    return f0 < 80;
}

fn string(s: Str, rolloff: f64) sig.StringOptions {
    return .{ .f0 = s.f0, .inharmonicity = s.b, .rolloff = rolloff, .t60_s = if (isBass(s.f0)) 8 else 6 };
}

const max_cases = 480;
var case_store: [max_cases]Case = undefined;
var name_store: [max_cases][40]u8 = undefined;
var case_count: usize = 0;

fn add(group: Group, comptime fmt: []const u8, args: anytype, c: Case) void {
    var v = c;
    v.group = group;
    v.name = std.fmt.bufPrint(&name_store[case_count], fmt, args) catch unreachable;
    case_store[case_count] = v;
    case_count += 1;
}

fn buildCases() []const Case {
    case_count = 0;
    const all_strings = guitar ++ guitar_high ++ bass ++ bass_fretted ++ sweep;
    for (all_strings) |s| {
        add(.stiff, "{s} bright", .{s.name}, .{ .name = "", .group = .stiff, .strings = .{ string(s, 1), null } });
        add(.stiff, "{s} mellow", .{s.name}, .{ .name = "", .group = .stiff, .strings = .{ string(s, 2), null } });
    }
    for (guitar[0..3].* ++ bass ++ bass_fretted) |s| {
        var o = string(s, 1);
        // Partial 2 is at 1/2 with rolloff 1, so 0.05 puts partial 1 20 dB under it.
        o.fundamental_gain = 0.05;
        add(.weak, "{s} weak", .{s.name}, .{ .name = "", .group = .weak, .strings = .{ o, null } });
    }
    for (guitar ++ bass[0..2].*) |s| {
        var o = string(s, 1);
        o.polarisation = .{ .cents = 0.5, .gain = 0.3, .t60_ratio = 0.5 };
        add(.beating, "{s} beating", .{s.name}, .{ .name = "", .group = .beating, .strings = .{ o, null } });
    }
    for (guitar ++ guitar_high) |s| {
        for ([_]f64{ 2.6, 10 }) |c| {
            var o = string(s, 1);
            o.pitch = .{ .glide = .{ .start_cents = c, .tau_s = 0.3 } };
            add(.glide_guitar, "{s} +{d} c", .{ s.name, c }, .{ .name = "", .group = .glide_guitar, .strings = .{ o, null } });
        }
    }
    for (bass ++ bass_fretted) |s| {
        for ([_]f64{ 4, 9.6 }) |c| {
            var o = string(s, 1);
            o.pitch = .{ .glide = .{ .start_cents = c, .tau_s = 0.6 } };
            add(.glide_bass, "{s} +{d} c", .{ s.name, c }, .{ .name = "", .group = .glide_bass, .strings = .{ o, null } });
        }
    }
    const ramps = [_]struct { s: Str, start: f64, rate: f64 }{
        .{ .s = guitar[0], .start = -40, .rate = 20 },
        .{ .s = bass[2], .start = -60, .rate = 40 },
        .{ .s = guitar[5], .start = 30, .rate = -20 },
    };
    for (ramps) |r| {
        var o = string(r.s, 1);
        o.t60_s = 12;
        o.pitch = .{ .ramp = .{ .start_cents = r.start, .cents_per_s = r.rate } };
        add(.ramp, "{s} {d} c/s", .{ r.s.name, r.rate }, .{ .name = "", .group = .ramp, .strings = .{ o, null } });
    }
    const hum_notes = [_]struct { s: Str, hum: Hum }{
        .{ .s = bass[2], .hum = .{ .hz = 50, .kind = .hum, .db = -50 } },
        .{ .s = bass_fretted[0], .hum = .{ .hz = 60, .kind = .hum, .db = -50 } },
        .{ .s = guitar[0], .hum = .{ .hz = 50, .kind = .buzz, .db = -50 } },
        .{ .s = bass[4], .hum = .{ .hz = 60, .kind = .buzz, .db = -50 } },
    };
    for (hum_notes) |h| {
        add(.hum_note, "{s} + {d} Hz {s}", .{ h.s.name, h.hum.hz, @tagName(h.hum.kind) }, .{ .name = "", .group = .hum_note, .strings = .{ string(h.s, 1), null }, .hum = h.hum });
    }
    const hum_strings = [_]Str{
        bass_fretted[0],
        bass[2],
        .{ .name = "G1", .f0 = 48.9994, .b = 2e-4 },
        guitar[0],
        guitar[1],
    };
    for (hum_strings) |hs| {
        for ([_]f64{ 50, 60 }) |hz| {
            for ([_]sig.Mains{ .hum, .buzz }) |kind| {
                for ([_][2]f64{ .{ -60, 0 }, .{ -30, 1 }, .{ -40, 1 } }) |lv| {
                    const h: Hum = .{ .hz = hz, .kind = kind, .db = lv[0], .relative = lv[1] == 1 };
                    add(.hum_target, "{s} + {d} {s} {d}{s}", .{ hs.name, hz, @tagName(kind), lv[0], if (h.relative) " rel" else " dBFS" }, .{ .name = "", .group = .hum_target, .strings = .{ string(hs, 1), null }, .hum = h });
                }
            }
        }
    }
    const pairs = [_][2]Str{
        .{ guitar[0], .{ .name = "B2", .f0 = 123.471, .b = 6.5e-5 } },
        .{ guitar[1], guitar[2] },
        .{ guitar[3], guitar[4] },
        .{ guitar[0], .{ .name = "E3", .f0 = 164.814, .b = 4.5e-5 } },
        .{ guitar[0], .{ .name = "F2", .f0 = 87.3071, .b = 1.1e-4 } },
        .{ guitar[0], .{ .name = "A#2", .f0 = 116.541, .b = 6.5e-5 } },
        .{ bass[2], guitar[0] },
    };
    for (pairs) |p| {
        var a = string(p[0], 1);
        var b = string(p[1], 1);
        a.peak = 0.35;
        b.peak = 0.35;
        b.seed = 2;
        add(.two_notes, "{s}+{s}", .{ p[0].name, p[1].name }, .{ .name = "", .group = .two_notes, .strings = .{ a, b } });
    }
    add(.ks_weak, "KS 880 Hz seed 1014", .{}, .{ .name = "", .group = .ks_weak, .strings = .{ .{ .f0 = 880, .inharmonicity = 0 }, null }, .ks_seed = 1014 });
    for ([_]f64{ 50, 60 }) |hz| {
        for ([_]f64{ -60, -50, -40, -30 }) |db| add(.hum, "{d} Hz hum {d} dB", .{ hz, db }, .{ .name = "", .group = .hum, .hum = .{ .hz = hz, .kind = .hum, .db = db } });
        for ([_]f64{ -50, -40 }) |db| add(.hum, "{d} Hz buzz {d} dB", .{ hz, db }, .{ .name = "", .group = .hum, .hum = .{ .hz = hz, .kind = .buzz, .db = db } });
    }
    add(.noise, "floor only", .{}, .{ .name = "", .group = .noise });
    for ([_]f64{ -70, -50, -30 }) |db| add(.noise, "white {d} dB", .{db}, .{ .name = "", .group = .noise, .noise_db = db });
    add(.noise, "rumble -40 dB", .{}, .{ .name = "", .group = .noise, .rumble_db = -40 });
    for ([_]f64{ 82.4069, 110, 41.2034 }) |hz| add(.muted, "muted {d} Hz", .{hz}, .{ .name = "", .group = .muted, .muted_hz = hz });
    add(.muted, "muted 82.4 Hz + 60 Hz hum", .{}, .{ .name = "", .group = .muted, .muted_hz = 82.4069, .hum = .{ .hz = 60, .kind = .hum, .db = -50 } });
    // Appended last: a case's noise seed follows its place in this list.
    const drift_strings = [_]struct { s: Str, hz: f64 }{
        .{ .s = bass_fretted[0], .hz = 60 },
        .{ .s = bass[2], .hz = 50 },
        .{ .s = .{ .name = "G1", .f0 = 48.9994, .b = 2e-4 }, .hz = 50 },
        .{ .s = guitar[0], .hz = 50 },
        .{ .s = guitar[1], .hz = 60 },
    };
    const changes = [_]struct { name: []const u8, change: sig.MainsChange, click: ?f64 = null }{
        .{ .name = "+2 mHz/s", .change = .{ .ramp_hz_per_s = 0.002 } },
        .{ .name = "-2 mHz/s", .change = .{ .ramp_hz_per_s = -0.002 } },
        .{ .name = "+5 mHz/s", .change = .{ .ramp_hz_per_s = 0.005 } },
        .{ .name = "-5 mHz/s", .change = .{ .ramp_hz_per_s = -0.005 } },
        .{ .name = "+20 mHz/s", .change = .{ .ramp_hz_per_s = 0.02 } },
        .{ .name = "-20 mHz/s", .change = .{ .ramp_hz_per_s = -0.02 } },
        .{ .name = "+6 dB", .change = .{ .step_at_s = 1.5, .step_db = 6 } },
        .{ .name = "-6 dB", .change = .{ .step_at_s = 1.5, .step_db = -6 } },
        .{ .name = "jump", .change = .{ .jump_at_s = 1.5, .jump_rad = std.math.pi / 2.0 } },
        .{ .name = "switch", .change = .{ .step_at_s = 1.5, .step_db = -4, .jump_at_s = 1.5, .jump_rad = 2 }, .click = 1.5 },
    };
    for (drift_strings) |d| {
        for (changes) |ch| {
            add(.hum_drift, "{s} {d} Hz {s}", .{ d.s.name, d.hz, ch.name }, .{ .name = "", .group = .hum_drift, .strings = .{ string(d.s, 1), null }, .hum = .{ .hz = d.hz, .kind = .hum, .db = -40, .relative = true, .change = ch.change }, .click_at_s = ch.click });
        }
        add(.hum_drift, "{s} {d} Hz buzz burst", .{ d.s.name, d.hz }, .{ .name = "", .group = .hum_drift, .strings = .{ string(d.s, 1), null }, .hum = .{ .hz = d.hz, .kind = .buzz, .db = -40, .relative = true, .change = .{ .on_s = 1.0, .off_s = 2.2 } } });
        for ([_]f64{ 0.005, -0.005 }) |r| {
            add(.hum_drift, "{s} {d} Hz {d} mHz/s -30", .{ d.s.name, d.hz, r * 1000 }, .{ .name = "", .group = .hum_drift, .strings = .{ string(d.s, 1), null }, .hum = .{ .hz = d.hz, .kind = .hum, .db = -30, .relative = true, .change = .{ .ramp_hz_per_s = r } } });
        }
    }
    for ([_]f64{ 50, 60 }) |hz| {
        for ([_]f64{ 0.005, 0.02 }) |r| {
            for ([_]sig.Mains{ .hum, .buzz }) |kind| add(.hum_drift_idle, "{d} Hz {s} {d} mHz/s", .{ hz, @tagName(kind), r * 1000 }, .{ .name = "", .group = .hum_drift_idle, .hum = .{ .hz = hz, .kind = kind, .db = -40, .change = .{ .ramp_hz_per_s = r } } });
        }
        add(.hum_drift_idle, "{d} Hz switch", .{hz}, .{ .name = "", .group = .hum_drift_idle, .hum = .{ .hz = hz, .kind = .hum, .db = -40, .change = .{ .step_at_s = 1.5, .step_db = -4, .jump_at_s = 1.5, .jump_rad = 2 } }, .click_at_s = 1.5 });
        add(.hum_drift_idle, "{d} Hz buzz bursts", .{hz}, .{ .name = "", .group = .hum_drift_idle, .hum = .{ .hz = hz, .kind = .buzz, .db = -40, .change = .{ .on_s = 1.0, .off_s = 2.2 } } });
    }
    for ([_]Str{ guitar[0], guitar[1], guitar[3], bass[1] }) |s| {
        var o = string(s, 1);
        o.pluck_at = 1.0 / 3.0;
        add(.third, "{s} at a third", .{s.name}, .{ .name = "", .group = .third, .strings = .{ o, null } });
    }
    const h2_strings = [_]Str{
        .{ .name = "E1", .f0 = 41.2034, .b = 2e-4 },
        .{ .name = "F#1", .f0 = 46.2493, .b = 2e-4 },
        .{ .name = "G#1", .f0 = 51.9131, .b = 2e-4 },
        .{ .name = "A1", .f0 = 55.0, .b = 2e-4 },
        .{ .name = "B1", .f0 = 61.7354, .b = 2e-4 },
        .{ .name = "D2", .f0 = 73.4162, .b = 2e-4 },
        .{ .name = "E2", .f0 = 82.4069, .b = 2e-4 },
        .{ .name = "A2", .f0 = 110.0, .b = 6.5e-5 },
    };
    for (h2_strings) |hs| {
        // With rolloff 1, partial 2 is 6 dB under partial 1; these gains
        // put it 12 or 17 dB over, and partial 3 20 dB under where it was.
        for ([_][2]f64{ .{ 12, 0.126 }, .{ 17, 0.0707 } }) |g| {
            var o = string(hs, 1);
            o.partial_gain = .{ g[1], 1, 0.1, 1 };
            add(.bass_h2, "{s} h2 +{d} dB", .{ hs.name, g[0] }, .{ .name = "", .group = .bass_h2, .strings = .{ o, null } });
        }
    }
    // Starts that must show.
    const e2 = string(guitar[0], 1);
    const a1 = string(bass[2], 1);
    for ([_]f64{ -3, -6, -10 }) |db| {
        var sharp = e2;
        sharp.f0 *= std.math.pow(f64, 2, 8.0 / 1200.0);
        sharp.seed = 3;
        add(.starts, "E2 re-pluck {d} dB", .{db}, .{ .name = "", .group = .starts, .strings = .{ e2, sharp }, .second_at_s = 1, .second_db = db });
        var sharp_a = a1;
        sharp_a.f0 *= std.math.pow(f64, 2, 8.0 / 1200.0);
        sharp_a.seed = 3;
        add(.starts, "A1 re-pluck {d} dB", .{db}, .{ .name = "", .group = .starts, .strings = .{ a1, sharp_a }, .second_at_s = 1, .second_db = db });
    }
    for ([_]f64{ -6, -10 }) |db| {
        var a2 = string(guitar[1], 1);
        a2.seed = 3;
        add(.starts, "E2 then A2 {d} dB", .{db}, .{ .name = "", .group = .starts, .strings = .{ e2, a2 }, .second_at_s = 1, .second_db = db });
    }
    {
        var e1 = string(bass[1], 1);
        e1.seed = 1;
        var a1b = a1;
        a1b.seed = 3;
        add(.starts, "E1 then A1 -6 dB", .{}, .{ .name = "", .group = .starts, .strings = .{ e1, a1b }, .second_at_s = 1, .second_db = -6 });
    }
    for ([_]Str{ guitar[0], bass[2] }) |st| {
        for ([_][2]f64{ .{ 4, 0.02 }, .{ 10, 0.03 } }) |cmp| {
            var o = string(st, 1);
            o.t60_s *= cmp[0];
            o.peak = 0.1;
            add(.starts, "{s} compressed {d}:1", .{ st.name, cmp[0] }, .{ .name = "", .group = .starts, .strings = .{ o, null }, .envelope = .{ .linear = cmp[1] } });
        }
    }
    for ([_]Str{ guitar[0], guitar[1] }) |st| {
        add(.starts, "{s} sustainer attack", .{st.name}, .{ .name = "", .group = .starts, .strings = .{ string(st, 1), null }, .envelope = .{ .linear = 0.2 } });
        add(.starts, "{s} palm then ring", .{st.name}, .{ .name = "", .group = .starts, .strings = .{ string(st, 1), null }, .envelope = .palm });
    }
    for ([_]Str{ guitar[5], guitar[4], guitar[3] }) |st| {
        var o = string(st, 2);
        o.peak = 0.02;
        add(.starts, "{s} fingerstyle", .{st.name}, .{ .name = "", .group = .starts, .strings = .{ o, null }, .envelope = .{ .linear = 0.008 } });
    }
    // Swells, held notes and slow attacks, over the bare floor, over white
    // noise at -70 dBFS and over 50 Hz hum at -50 dBFS.
    for ([_]Background{ .bare, .noise, .hum }) |bg| {
        const bg_noise: ?f64 = if (bg == .noise) -70 else null;
        const bg_hum: ?Hum = if (bg == .hum) .{ .hz = 50, .kind = .hum, .db = -50 } else null;
        const bg_name = @tagName(bg);
        for ([_]f64{ 0.3, 1, 2 }) |d| {
            var o = string(guitar[1], 1);
            o.t60_s = 30;
            add(.swells, "A2 linear swell {d} s, {s}", .{ d, bg_name }, .{ .name = "", .group = .swells, .strings = .{ o, null }, .envelope = .{ .linear = d }, .noise_db = bg_noise, .hum = bg_hum });
            add(.swells, "A2 exp swell {d} s, {s}", .{ d, bg_name }, .{ .name = "", .group = .swells, .strings = .{ o, null }, .envelope = .{ .exponential = d }, .noise_db = bg_noise, .hum = bg_hum });
        }
        var o = string(guitar[0], 1);
        o.t60_s = 30;
        add(.swells, "E2 volume pedal, {s}", .{bg_name}, .{ .name = "", .group = .swells, .strings = .{ o, null }, .envelope = .{ .exponential = 1.5 }, .noise_db = bg_noise, .hum = bg_hum });
        var ebow: sig.StringOptions = .{ .f0 = 164.814, .inharmonicity = 4.5e-5, .rolloff = 1.5, .t60_s = 1000 };
        ebow.t60_slope = 0;
        add(.swells, "E3 e-bow, {s}", .{bg_name}, .{ .name = "", .group = .swells, .strings = .{ ebow, null }, .envelope = .{ .exponential = 1.5 }, .noise_db = bg_noise, .hum = bg_hum });
        var bowed = string(bass[2], 1);
        bowed.t60_s = 1000;
        bowed.t60_slope = 0;
        add(.swells, "A1 bowed, {s}", .{bg_name}, .{ .name = "", .group = .swells, .strings = .{ bowed, null }, .envelope = .{ .linear = 0.4 }, .bow_s = 0.4, .noise_db = bg_noise, .hum = bg_hum });
        const pad: sig.StringOptions = .{ .f0 = 130.813, .inharmonicity = 0, .rolloff = 2, .t60_s = 1000, .t60_slope = 0 };
        add(.swells, "C3 pad, {s}", .{bg_name}, .{ .name = "", .group = .swells, .strings = .{ pad, null }, .envelope = .{ .linear = 1 }, .noise_db = bg_noise, .hum = bg_hum });
    }
    // From the held-out corpora's findings.
    for (guitar) |st| {
        for ([_][3]f64{ .{ -20, -14, -10 }, .{ -12, -8, -6 } }) |db| {
            add(.body, "{s} body {d}/{d}/{d} dB", .{ st.name, db[0], db[1], db[2] }, .{ .name = "", .group = .body, .strings = .{ string(st, 1), null }, .body_db = db });
        }
    }
    for (0..guitar.len) |k| {
        const other = guitar[(k + guitar.len - 1) % guitar.len];
        for ([_]f64{ -15, -22, -30 }) |db| {
            var o = string(other, 1);
            o.t60_s = 10;
            o.seed = 5;
            add(.sympathetic, "{s} + {s} {d} dB", .{ guitar[k].name, other.name, db }, .{ .name = "", .group = .sympathetic, .strings = .{ string(guitar[k], 1), o }, .sympathetic_db = db });
        }
    }
    for ([_]Str{ guitar[0], guitar[3], guitar[5], bass[0], bass[1], bass[2] }) |st| {
        for ([_]f64{ 0.35, 1, 3.5 }) |c| {
            for ([_][2]f64{ .{ 0.8, 1.0 / 1.2 }, .{ 0.5, 1.0 / 3.0 }, .{ 0.6, 3 } }) |pg| {
                var o = string(st, 1);
                o.polarisation = .{ .cents = c, .gain = pg[0], .t60_ratio = pg[1] };
                add(.polar, "{s} pol {d} c {d}x{d:.2}", .{ st.name, c, pg[0], pg[1] }, .{ .name = "", .group = .polar, .strings = .{ o, null } });
            }
        }
    }
    for ([_]f64{ 2e-4, 3e-4, 4e-4 }) |b| {
        for ([_]f64{ 0, 5, 7, 12, 21 }) |fret| {
            var o: sig.StringOptions = .{ .f0 = 30.8677 * std.math.pow(f64, 2, fret / 12), .inharmonicity = b * std.math.pow(f64, 2, 2 * fret / 12), .t60_s = 8 };
            o.pitch = .{ .glide = .{ .start_cents = 5, .tau_s = 0.6 } };
            add(.bass_fret, "B0 fret {d} B{e}", .{ fret, b }, .{ .name = "", .group = .bass_fret, .strings = .{ o, null } });
        }
    }
    // Steady sounds that start abruptly, to keep out.
    for ([_]f64{ 50, 60 }) |hz| add(.hum_drift_idle, "{d} Hz hum switching on", .{hz}, .{ .name = "", .group = .hum_drift_idle, .hum = .{ .hz = hz, .kind = .hum, .db = -40, .change = .{ .on_s = 1.0 } } });
    return case_store[0..case_count];
}

fn onsetSample(sr: f64) usize {
    return @intFromFloat(lead_s * sr);
}

/// Writes the case at `sr` into `buf` and returns the signal; `tmp` is
/// scratch of the same size.
fn render(c: Case, sr: f64, seed: u64, buf: []f32, tmp: []f32) []f32 {
    const n: usize = @intFromFloat((lead_s + sustain_s) * sr);
    const out = buf[0..n];
    @memset(out, 0);
    const onset = onsetSample(sr);
    for (c.strings, 0..) |maybe, si| {
        const s = maybe orelse continue;
        if (si == 1 and (c.second_at_s != null or c.sympathetic_db != null)) continue;
        const body = tmp[0 .. n - onset];
        if (c.ks_seed) |seed_ks| sig.pluck(body, sr, s.f0, .{ .amp = 0.9, .t60_s = 3, .seed = seed_ks }) else sig.pluckedString(body, sr, s);
        if (si == 0) if (c.envelope) |e| {
            for (body, 0..) |*v, i| v.* *= @floatCast(e.gain(@as(f64, @floatFromInt(i)) / sr));
        };
        sig.mix(out[onset..], body);
    }
    if (c.second_at_s) |at_s| {
        const at = onset + @as(usize, @intFromFloat(at_s * sr));
        const tenth: usize = @intFromFloat(0.1 * sr);
        const before = sig.rms(out[at - tenth .. at]);
        for (out[at..]) |*v| v.* *= 0.5;
        const body = tmp[0 .. n - at];
        sig.pluckedString(body, sr, c.strings[1].?);
        sig.scale(body, before * std.math.pow(f64, 10, c.second_db / 20) / sig.rms(body[0..tenth]));
        sig.mix(out[at..], body);
    }
    if (c.sympathetic_db) |db| {
        const half: usize = @intFromFloat(0.5 * sr);
        const level = sig.rms(out[onset .. onset + half]) * std.math.pow(f64, 10, db / 20);
        const body = tmp[0 .. n - onset];
        sig.pluckedString(body, sr, c.strings[1].?);
        const rise: usize = @intFromFloat(0.05 * sr);
        for (body[0..rise], 0..) |*v, i| v.* *= @floatCast(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rise)));
        sig.scale(body, level / sig.rms(body[0..half]));
        sig.mix(out[onset..], body);
    }
    if (c.body_db) |dbs| {
        const tenth: usize = @intFromFloat(0.1 * sr);
        const level = sig.rms(out[onset .. onset + tenth]);
        var peak: f64 = 0;
        for (out[onset .. onset + tenth]) |v| peak = @max(peak, @abs(v));
        const modes = [_][2]f64{ .{ 98, 0.6 }, .{ 163, 0.4 }, .{ 231, 0.3 } };
        var rng = sig.MinStd.init(seed + 31);
        for (modes, dbs) |mode, db| {
            // A decaying sinusoid's RMS over its first 0.1 s is about its
            // amplitude over sqrt 2.
            const amp = level * std.math.pow(f64, 10, db / 20) * std.math.sqrt2;
            const phase = std.math.pi * (rng.next() + 1);
            const decay = @log(1000.0) / mode[1];
            for (out[onset..], 0..) |*v, i| {
                const t = @as(f64, @floatFromInt(i)) / sr;
                if (decay * t > 14) break;
                v.* += @floatCast(amp * @exp(-decay * t) * @sin(2 * std.math.pi * mode[0] * t + phase));
            }
        }
        const click: usize = @intFromFloat(0.001 * sr);
        for (out[onset .. onset + click]) |*v| v.* += @floatCast(peak * rng.next());
    }
    if (c.bow_s) |bow| {
        const len: usize = @intFromFloat(bow * sr);
        const level = sig.rms(out[onset .. onset + len]) * std.math.pow(f64, 10, -30.0 / 20.0);
        @memset(tmp[0..len], 0);
        sig.addNoise(tmp[0..len], 1, seed + 29);
        var lp: f32 = 0;
        for (tmp[0..len]) |*v| {
            lp = 0.9 * lp + 0.1 * v.*;
            v.* = lp;
        }
        sig.scale(tmp[0..len], level / @max(sig.rms(tmp[0..len]), 1e-12));
        sig.mix(out[onset .. onset + len], tmp[0..len]);
    }
    if (c.hum) |h| {
        var db = h.db;
        if (h.relative) {
            const second: usize = @intFromFloat(sr);
            db += 20 * std.math.log10(sig.rms(out[onset .. onset + second]));
        }
        if (h.change) |ch| sig.mainsChanging(tmp[0..n], sr, h.hz, h.kind, db, ch) else sig.mains(tmp[0..n], sr, h.hz, h.kind, db);
        sig.mix(out, tmp[0..n]);
    }
    if (c.muted_hz) |hz| {
        for (0..4) |k| {
            const at = onset + @as(usize, @intFromFloat(0.75 * sr * @as(f64, @floatFromInt(k))));
            sig.mutedString(out[at..], sr, hz, 0.03, 0.5, seed + k);
        }
    }
    if (c.click_at_s) |at_s| {
        var rng = sig.MinStd.init(seed + 23);
        const at: usize = @intFromFloat(at_s * sr);
        const len: usize = @intFromFloat(0.005 * sr);
        for (out[at..@min(n, at + len)]) |*v| v.* += @floatCast(0.03 * rng.next());
    }
    if (c.noise_db) |db| sig.addNoise(out, std.math.pow(f64, 10, db / 20), seed + 11);
    if (c.rumble_db) |db| {
        @memset(tmp[0..n], 0);
        sig.addNoise(tmp[0..n], 0.1, seed + 13);
        var lp: f32 = 0;
        for (tmp[0..n]) |*v| {
            lp = 0.98 * lp + 0.02 * v.*;
            v.* = lp;
        }
        sig.scale(tmp[0..n], std.math.pow(f64, 10, db / 20) / sig.rms(tmp[0..n]));
        sig.mix(out, tmp[0..n]);
    }
    sig.addNoise(out, std.math.pow(f64, 10, noise_floor_db / 20), seed + 17);
    return out;
}

// ---------------------------------------------------------------------------
// Candidates

/// What a reading shows.
const Display = struct {
    /// The note name shown, or null for none.
    note: ?i32 = null,
    /// The frequency behind the cents shown, or null while there are none.
    hz: ?f64 = null,
    stable: bool = false,
    multiple: bool = false,
};

const Candidate = struct {
    name: []const u8,
    note: []const u8,
    ctx: *anyopaque,
    resetFn: *const fn (*anyopaque, f64) void,
    pushFn: *const fn (*anyopaque, []const f32) void,
    readFn: *const fn (*anyopaque) Display,

    fn reset(self: Candidate, sample_rate: f64) void {
        self.resetFn(self.ctx, sample_rate);
    }
    fn push(self: Candidate, samples: []const f32) void {
        self.pushFn(self.ctx, samples);
    }
    fn read(self: Candidate) Display {
        return self.readFn(self.ctx);
    }
};

fn display(r: pitch.Reading) Display {
    if (r.freq_hz <= 0) return .{};
    return .{ .note = r.note, .hz = if (r.settling) null else r.freq_hz, .stable = r.stable, .multiple = r.multiple };
}

fn analyserCandidate(comptime T: type, name: []const u8, about: []const u8, allocator: std.mem.Allocator) !Candidate {
    return analyserCandidateWith(T, .{}, name, about, allocator);
}

fn analyserCandidateWith(comptime T: type, comptime settings: pitch.Settings, name: []const u8, about: []const u8, allocator: std.mem.Allocator) !Candidate {
    const Adapter = struct {
        fn reset(ctx: *anyopaque, sample_rate: f64) void {
            const a: *T = @ptrCast(@alignCast(ctx));
            a.init(sample_rate) catch unreachable;
        }
        fn push(ctx: *anyopaque, samples: []const f32) void {
            const a: *T = @ptrCast(@alignCast(ctx));
            a.push(samples);
        }
        fn read(ctx: *anyopaque) Display {
            const a: *T = @ptrCast(@alignCast(ctx));
            return display(a.analyse(settings));
        }
    };
    return .{ .name = name, .note = about, .ctx = try allocator.create(T), .resetFn = Adapter.reset, .pushFn = Adapter.push, .readFn = Adapter.read };
}

fn jsfxCandidate(allocator: std.mem.Allocator) !Candidate {
    const Adapter = struct {
        fn reset(ctx: *anyopaque, sample_rate: f64) void {
            const p: *jsfx.JsfxPort = @ptrCast(@alignCast(ctx));
            p.init(sample_rate);
        }
        fn push(ctx: *anyopaque, samples: []const f32) void {
            const p: *jsfx.JsfxPort = @ptrCast(@alignCast(ctx));
            for (samples) |s| _ = p.pushSample(s);
        }
        fn read(ctx: *anyopaque) Display {
            const p: *jsfx.JsfxPort = @ptrCast(@alignCast(ctx));
            const o = p.outputs();
            if (o.freq <= 0) return .{};
            return .{ .note = @intFromFloat(o.note), .hz = o.freq };
        }
    };
    return .{ .name = "jsfx", .note = "PitchDetect.jsfx ported", .ctx = try allocator.create(jsfx.JsfxPort), .resetFn = Adapter.reset, .pushFn = Adapter.push, .readFn = Adapter.read };
}

var readings_buf: [256]Display = undefined;

/// Feeds `signal` in 256-sample blocks and reads at every 30 Hz tick:
/// readings[i] is the reading after (i + 1) ticks.
fn run(c: Candidate, sample_rate: f64, signal: []const f32) []const Display {
    c.reset(sample_rate);
    const tick: usize = @intFromFloat(@round(sample_rate / 30.0));
    var pos: usize = 0;
    var next_tick = tick;
    var n: usize = 0;
    while (pos < signal.len) {
        const end = @min(signal.len, pos + 256, next_tick);
        c.push(signal[pos..end]);
        pos = end;
        if (pos == next_tick) {
            readings_buf[n] = c.read();
            n += 1;
            next_tick += tick;
        }
    }
    return readings_buf[0..n];
}

/// Seconds from the onset to reading i.
fn readTime(i: usize, sample_rate: f64) f64 {
    const tick = @round(sample_rate / 30.0);
    return (@as(f64, @floatFromInt(i + 1)) * tick - @as(f64, @floatFromInt(onsetSample(sample_rate)))) / sample_rate;
}

fn midiOf(hz: f64) f64 {
    return 69 + 12 * @log2(hz / 440);
}

fn noteOf(hz: f64) i32 {
    return @intFromFloat(@floor(midiOf(hz) + 0.5));
}

// ---------------------------------------------------------------------------
// Results

const GroupStats = struct {
    errors: std.ArrayList(f64) = .empty,
    /// Errors against the settled f1 (the glide's nu_inf).
    settled_errors: std.ArrayList(f64) = .empty,
    /// Errors from t = 0.5 s rather than 1 s (reported beside the targets).
    early_errors: std.ArrayList(f64) = .empty,
    /// Beating strings: errors against the instantaneous frequency of the
    /// first partial's two polarisations together (a diagnostic, not a
    /// target).
    composite_errors: std.ArrayList(f64) = .empty,
    /// Reads in the 1-3 s span, and those that showed cents.
    span_reads: usize = 0,
    span_shown: usize = 0,
    worst_jitter: f64 = 0,
    worst_jitter_case: [48]u8 = undefined,
    worst_jitter_len: usize = 0,
    worst_error: f64 = 0,
    worst_error_case: [48]u8 = undefined,
    worst_error_len: usize = 0,
    reads: usize = 0,
    octave: usize = 0,
    wrong_note: usize = 0,
    false_notes: usize = 0,
    subharmonic: usize = 0,
    multiple: usize = 0,
    /// Per two-note read: on the lower, the upper, something else, none.
    two: [4]usize = .{ 0, 0, 0, 0 },
    lock_sum_ms: f64 = 0,
    lock_worst_ms: f64 = 0,
    lock_n: usize = 0,
    lock_never: usize = 0,
    stable_sum_ms: f64 = 0,
    stable_worst_ms: f64 = 0,
    stable_n: usize = 0,
    stable_never: usize = 0,
    flag_sum_ms: f64 = 0,
    flag_n: usize = 0,
    flag_never: usize = 0,
    /// Finding groups: notes, and those whose note name changed after it
    /// first showed; per note, the time until every reading to the last
    /// one shown is within 1 cent of the composite truth (guitar and bass
    /// apart, infinite if never) and the spread of the error against it
    /// over readings flagged stable; the worst signed mean error from 1 s
    /// of any one signal, and which.
    /// Readings from the onset on whose note name isn't f1(t)'s.
    wrong_name: usize = 0,
    finding_notes: usize = 0,
    name_changed: usize = 0,
    comp_settle_guitar: std.ArrayList(f64) = .empty,
    comp_settle_bass: std.ArrayList(f64) = .empty,
    comp_flicker: std.ArrayList(f64) = .empty,
    worst_bias: f64 = 0,
    worst_bias_case: [48]u8 = undefined,
    worst_bias_len: usize = 0,
    /// Starts and swells: notes, those whose note never showed in time,
    /// and the times it took (s).
    start_notes: usize = 0,
    start_missed: usize = 0,
    show_s: std.ArrayList(f64) = .empty,
    /// "name rate: time" for each miss, `; `-separated.
    missed: std.ArrayList(u8) = .empty,
    /// Readings flagged stable, and of them those more than 0.5 cent off
    /// f1(t), from t = 0.1 s.
    stable_reads: usize = 0,
    stable_wrong: usize = 0,
    /// Ramp: reads over the allowance.
    ramp_over: usize = 0,
    ramp_reads: usize = 0,
    ramp_worst: f64 = 0,
};

fn label(dst: []u8, c: Case, sr: f64) []const u8 {
    return std.fmt.bufPrint(dst, "{s} @{d}k", .{ c.name, sr / 1000 }) catch dst[0..0];
}

/// The p-th quantile; infinite for no values, so saying nothing can't pass.
fn percentile(values: []f64, p: f64) f64 {
    if (values.len == 0) return std.math.inf(f64);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const idx: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(values.len))) - 1);
    return values[@min(idx, values.len - 1)];
}

/// For a swell, seconds from its onset until the input's level over a
/// window of 92.9 ms first stands 12 dB over the floor, the level over the
/// same length of input before the onset.
var case_cross_s: f64 = 0;

fn levelCrossing(s: []const f32, sr: f64) f64 {
    const onset = onsetSample(sr);
    const w: usize = @intFromFloat(4096.0 / 44100.0 * sr);
    const threshold = sig.rms(s[onset - w .. onset]) * std.math.pow(f64, 10, 12.0 / 20.0);
    var energy: f64 = 0;
    for (s[onset .. onset + w]) |v| energy += @as(f64, v) * v;
    var i = onset + w;
    while (i < s.len) : (i += 1) {
        if (@sqrt(energy / @as(f64, @floatFromInt(w))) >= threshold) return @as(f64, @floatFromInt(i - onset)) / sr;
        energy += @as(f64, s[i]) * s[i] - @as(f64, s[i - w]) * s[i - w];
    }
    return std.math.inf(f64);
}

fn measureStart(alloc: std.mem.Allocator, st: *GroupStats, c: Case, sr: f64, rs: []const Display) !void {
    const s = if (c.second_at_s != null) c.strings[1].? else c.strings[0].?;
    const start = if (c.group == .swells) case_cross_s else (c.second_at_s orelse 0);
    const limit: f64 = if (c.group == .swells) targets.swell_show_s else targets.start_show_s;
    st.start_notes += 1;
    var shown: ?f64 = null;
    for (rs, 0..) |r, i| {
        const t = readTime(i, sr);
        if (t < start) continue;
        const since_pluck = t - (c.second_at_s orelse 0);
        const truth = s.firstPartialHz(@max(since_pluck, 0));
        if (shown == null) {
            if (r.note) |n| if (n == noteOf(truth)) {
                shown = t - start;
            };
        } else if (t - start - shown.? >= 0.5 and t >= 1) {
            st.span_reads += 1;
            if (r.hz) |hz| {
                st.span_shown += 1;
                try st.errors.append(alloc, @abs(sig.cents(hz, truth)));
            } else try st.errors.append(alloc, std.math.inf(f64));
        }
    }
    const v = shown orelse std.math.inf(f64);
    try st.show_s.append(alloc, v);
    if (v > limit) {
        st.start_missed += 1;
        try st.missed.writer(alloc).print("{s} {d:.0}k: {d:.3}; ", .{ c.name, sr / 1000, v });
    }
}

fn measureFinding(alloc: std.mem.Allocator, st: *GroupStats, c: Case, sr: f64, rs: []const Display) !void {
    const s = c.strings[0].?;
    st.finding_notes += 1;
    var first: ?i32 = null;
    var changed = false;
    var settle: ?f64 = null;
    var last_shown: usize = 0;
    for (rs, 0..) |r, i| {
        if (r.hz != null) last_shown = i;
    }
    var sum: f64 = 0;
    var sum2: f64 = 0;
    var stable_n: f64 = 0;
    var bias_sum: f64 = 0;
    var bias_n: f64 = 0;
    for (rs, 0..) |r, i| {
        const t = readTime(i, sr);
        if (t <= 0) continue;
        if (r.note) |n| {
            if (first) |f| {
                if (n != f) changed = true;
            } else first = n;
        }
        if (t >= 1) if (r.hz) |hz| {
            bias_sum += sig.cents(hz, s.firstPartialHz(t));
            bias_n += 1;
        };
        if (c.group != .polar or i > last_shown) continue;
        const e: ?f64 = if (r.hz) |hz| sig.cents(hz, s.compositeFirstPartialHz(t)) else null;
        if (e != null and @abs(e.?) <= 1) {
            if (settle == null) settle = t;
        } else settle = null;
        if (r.stable) if (e) |v| {
            sum += v;
            sum2 += v * v;
            stable_n += 1;
        };
    }
    if (changed) st.name_changed += 1;
    if (c.group == .polar) {
        try (if (isBass(s.f0)) &st.comp_settle_bass else &st.comp_settle_guitar).append(alloc, settle orelse std.math.inf(f64));
        if (stable_n >= 3) {
            const m = sum / stable_n;
            try st.comp_flicker.append(alloc, @sqrt(@max(0, sum2 / stable_n - m * m)));
        }
    }
    const bias = if (bias_n > 0) bias_sum / bias_n else std.math.inf(f64);
    if (@abs(bias) > @abs(st.worst_bias) or st.worst_bias_len == 0) {
        var name_buf: [48]u8 = undefined;
        const name = label(&name_buf, c, sr);
        st.worst_bias = bias;
        st.worst_bias_len = @min(name.len, st.worst_bias_case.len);
        @memcpy(st.worst_bias_case[0..st.worst_bias_len], name[0..st.worst_bias_len]);
    }
}

fn measure(alloc: std.mem.Allocator, st: *GroupStats, c: Case, sr: f64, rs: []const Display) !void {
    if (c.group == .starts or c.group == .swells) return measureStart(alloc, st, c, sr, rs);
    if (c.group.finding()) try measureFinding(alloc, st, c, sr, rs);
    var name_buf: [48]u8 = undefined;
    const name = label(&name_buf, c, sr);
    st.reads += rs.len;
    switch (c.group) {
        .hum, .noise, .muted, .hum_drift_idle => {
            for (rs) |r| {
                if (r.note != null) st.false_notes += 1;
            }
            return;
        },
        .two_notes => {
            const lo = c.strings[0].?;
            const hi = c.strings[1].?;
            const lower_note = @min(noteOf(lo.firstPartialHz(0)), noteOf(hi.firstPartialHz(0)));
            for (rs, 0..) |r, i| {
                if (readTime(i, sr) < 0.1) continue;
                const n = r.note orelse {
                    st.two[3] += 1;
                    continue;
                };
                if (r.multiple) st.multiple += 1;
                if (n < lower_note - 1 and !r.multiple) st.subharmonic += 1;
                if (n == noteOf(lo.firstPartialHz(readTime(i, sr)))) st.two[0] += 1 else if (n == noteOf(hi.firstPartialHz(readTime(i, sr)))) st.two[1] += 1 else st.two[2] += 1;
            }
            return;
        },
        else => {},
    }
    const s = c.strings[0].?;
    const settled = s.settledFirstPartialHz();
    var sum: f64 = 0;
    var sum2: f64 = 0;
    var n_err: usize = 0;
    var case_worst: f64 = 0;
    for (rs, 0..) |r, i| {
        const t = readTime(i, sr);
        if (t > 0) if (r.note) |n| {
            if (n != noteOf(s.firstPartialHz(t))) st.wrong_name += 1;
        };
        if (t < 0.1) continue;
        const truth = s.firstPartialHz(t);
        if (r.multiple) st.multiple += 1;
        if (r.stable) {
            st.stable_reads += 1;
            if (r.hz == null or @abs(sig.cents(r.hz.?, truth)) > 0.5) st.stable_wrong += 1;
        }
        if (r.note) |n| {
            const d = @abs(n - noteOf(truth));
            if ((d >= 11 and d <= 13) or (d >= 23 and d <= 25) or (d >= 35 and d <= 37)) st.octave += 1 else if (d != 0) st.wrong_note += 1;
        }
        if (c.group == .ramp) {
            if (t < 0.5) continue;
            const rate = @abs(s.pitch.ramp.cents_per_s);
            const allowed = targets.ramp_cents + rate * targets.ramp_lag_s;
            const e = if (r.hz) |hz| @abs(sig.cents(hz, truth)) else std.math.inf(f64);
            st.ramp_reads += 1;
            if (e > allowed) st.ramp_over += 1;
            st.ramp_worst = @max(st.ramp_worst, e);
            continue;
        }
        if (t >= 0.5) try st.early_errors.append(alloc, if (r.hz) |hz| @abs(sig.cents(hz, truth)) else std.math.inf(f64));
        if (t < 1.0) continue;
        const e = if (r.hz) |hz| sig.cents(hz, truth) else std.math.inf(f64);
        try st.errors.append(alloc, @abs(e));
        st.span_reads += 1;
        if (r.hz != null) st.span_shown += 1;
        if (c.group == .beating) try st.composite_errors.append(alloc, if (r.hz) |hz| @abs(sig.cents(hz, s.compositeFirstPartialHz(t))) else std.math.inf(f64));
        try st.settled_errors.append(alloc, if (r.hz) |hz| @abs(sig.cents(hz, settled)) else std.math.inf(f64));
        case_worst = @max(case_worst, @abs(e));
        if (std.math.isFinite(e)) {
            sum += e;
            sum2 += e * e;
            n_err += 1;
        }
    }
    if (case_worst > st.worst_error) {
        st.worst_error = case_worst;
        st.worst_error_len = @min(name.len, st.worst_error_case.len);
        @memcpy(st.worst_error_case[0..st.worst_error_len], name[0..st.worst_error_len]);
    }
    if (c.group == .stiff or c.group == .weak or c.group == .beating or c.group == .hum_note) {
        const nf: f64 = @floatFromInt(@max(n_err, 1));
        const mean = sum / nf;
        const jitter = if (n_err > 1) @sqrt(@max(0, sum2 / nf - mean * mean)) else std.math.inf(f64);
        if (jitter > st.worst_jitter) {
            st.worst_jitter = jitter;
            st.worst_jitter_len = @min(name.len, st.worst_jitter_case.len);
            @memcpy(st.worst_jitter_case[0..st.worst_jitter_len], name[0..st.worst_jitter_len]);
        }
    }
    if (c.group == .ramp) return;

    // Lock-on: the first reading from which every one to 1.5 s shows the note.
    var lock: ?usize = null;
    var i: usize = 0;
    while (i < rs.len and readTime(i, sr) <= 1.5) : (i += 1) {
        if (readTime(i, sr) <= 0) continue;
        const ok = if (rs[i].note) |n| n == noteOf(s.firstPartialHz(readTime(i, sr))) else false;
        if (ok) {
            if (lock == null) lock = i;
        } else lock = null;
    }
    if (lock) |l| {
        const ms = readTime(l, sr) * 1000;
        st.lock_sum_ms += ms;
        st.lock_worst_ms = @max(st.lock_worst_ms, ms);
        st.lock_n += 1;
    } else st.lock_never += 1;

    // Time to stable: within 1 cent of the settled f1 from then to the end.
    var stable: ?usize = null;
    for (rs, 0..) |r, k| {
        if (readTime(k, sr) <= 0) continue;
        const ok = if (r.hz) |hz| @abs(sig.cents(hz, settled)) <= 1 else false;
        if (ok) {
            if (stable == null) stable = k;
        } else stable = null;
    }
    if (stable) |l| {
        const ms = readTime(l, sr) * 1000;
        st.stable_sum_ms += ms;
        st.stable_worst_ms = @max(st.stable_worst_ms, ms);
        st.stable_n += 1;
    } else st.stable_never += 1;
    var flagged: ?usize = null;
    for (rs, 0..) |r, k| {
        if (readTime(k, sr) > 0 and r.stable) {
            flagged = k;
            break;
        }
    }
    if (flagged) |l| {
        st.flag_sum_ms += readTime(l, sr) * 1000;
        st.flag_n += 1;
    } else st.flag_never += 1;
}

const Cpu = struct { push_ns_per_s: f64 = 0, analyse_mean_ns: f64 = 0, analyse_max_ns: f64 = 0 };

const Ticks = struct { idle_mean_us: f64 = 0, idle_worst_us: f64 = 0, played_mean_us: f64 = 0, played_worst_us: f64 = 0 };

/// Per-tick cost over a session: hum at -60 dBFS throughout, a 110 Hz
/// string ringing from the start (no onset) for 3 s, then hum alone, then
/// a pluck at 4 s, to 7 s. Each tick's cost is its least over three runs
/// of the session, so a preempted tick doesn't count; ticks before 4 s are
/// the no-onset state, ticks from 4.1 s the played one.
fn measureTicks(c: Candidate, sr: f64, buf: []f32, tmp: []f32) !Ticks {
    const n: usize = @intFromFloat(7 * sr);
    const s = buf[0..n];
    sig.mains(s, sr, 50, .hum, -60);
    const pluck_at: usize = @intFromFloat(4 * sr);
    sig.pluckedString(tmp[0..@intFromFloat(3 * sr)], sr, .{ .f0 = 110, .inharmonicity = 6.5e-5 });
    sig.mix(s, tmp[0..@intFromFloat(3 * sr)]);
    sig.pluckedString(tmp[0 .. n - pluck_at], sr, .{ .f0 = 82.4069, .inharmonicity = 1.1e-4, .seed = 5 });
    sig.mix(s[pluck_at..], tmp[0 .. n - pluck_at]);
    sig.addNoise(s, 3e-5, 21);
    const tick: usize = @intFromFloat(@round(sr / 30));
    const count = n / tick;
    var best: [256]u64 = [_]u64{std.math.maxInt(u64)} ** 256;
    for (0..3) |_| {
        c.reset(sr);
        var timer = try std.time.Timer.start();
        for (0..@min(count, best.len)) |k| {
            timer.reset();
            var p = k * tick;
            while (p < (k + 1) * tick) : (p += 256) c.push(s[p..@min((k + 1) * tick, p + 256)]);
            std.mem.doNotOptimizeAway(c.read());
            best[k] = @min(best[k], timer.read());
        }
    }
    var out: Ticks = .{};
    var idle_n: f64 = 0;
    var played_n: f64 = 0;
    for (best[0..@min(count, best.len)], 0..) |ns, k| {
        const t = @as(f64, @floatFromInt((k + 1) * tick)) / sr;
        const us = @as(f64, @floatFromInt(ns)) / 1000;
        if (t < 4) {
            out.idle_mean_us += us;
            out.idle_worst_us = @max(out.idle_worst_us, us);
            idle_n += 1;
        } else if (t >= 4.1) {
            out.played_mean_us += us;
            out.played_worst_us = @max(out.played_worst_us, us);
            played_n += 1;
        }
    }
    out.idle_mean_us /= idle_n;
    out.played_mean_us /= played_n;
    return out;
}

fn measureCpu(c: Candidate, sr: f64, buf: []f32, tmp: []f32) !Cpu {
    const s = render(.{ .name = "", .group = .stiff, .strings = .{ string(guitar[0], 1), null } }, sr, 1, buf, tmp);
    const tick: usize = @intFromFloat(@round(sr / 30.0));
    var best: Cpu = .{ .push_ns_per_s = std.math.inf(f64), .analyse_mean_ns = std.math.inf(f64), .analyse_max_ns = 0 };
    // Best of three passes, to keep other processes' noise out.
    for (0..3) |_| {
        c.reset(sr);
        var push_ns: u64 = 0;
        var analyse_ns: u64 = 0;
        var analyse_max: u64 = 0;
        var reads: usize = 0;
        var pos: usize = 0;
        var timer = try std.time.Timer.start();
        while (pos + tick <= s.len) : (pos += tick) {
            timer.reset();
            var p = pos;
            while (p < pos + tick) : (p += 256) c.push(s[p..@min(pos + tick, p + 256)]);
            push_ns += timer.read();
            timer.reset();
            std.mem.doNotOptimizeAway(c.read());
            const t = timer.read();
            analyse_ns += t;
            analyse_max = @max(analyse_max, t);
            reads += 1;
        }
        const seconds = @as(f64, @floatFromInt(pos)) / sr;
        best.push_ns_per_s = @min(best.push_ns_per_s, @as(f64, @floatFromInt(push_ns)) / seconds);
        best.analyse_mean_ns = @min(best.analyse_mean_ns, @as(f64, @floatFromInt(analyse_ns)) / @as(f64, @floatFromInt(reads)));
        best.analyse_max_ns = @max(best.analyse_max_ns, @as(f64, @floatFromInt(analyse_max)));
    }
    return best;
}

fn coreShare(cpu: Cpu) f64 {
    return (cpu.push_ns_per_s + 30 * cpu.analyse_mean_ns) / 1e9 * 100;
}

/// What a player notices, over the one-string signals that are plucked
/// (every group but the ramp, two notes and the no-note ones).
const Player = struct {
    /// Per note, seconds from the onset until every reading to the last
    /// one shown has cents within 1 (and 0.5) cent of f1(t); infinite if
    /// never.
    settle_1c: std.ArrayList(f64) = .empty,
    settle_half_c: std.ArrayList(f64) = .empty,
    /// Per note, the standard deviation of the error over its readings
    /// flagged stable (3 or more), cents.
    flicker: std.ArrayList(f64) = .empty,
    /// Per note, how often the note name shown changes after the first.
    name_changes: std.ArrayList(f64) = .empty,
    notes: usize = 0,
    notes_with_octave: usize = 0,
    /// Idle signals (hum, noise, muted): false-note events (a run of
    /// readings showing a note) and seconds of input.
    false_events: usize = 0,
    idle_s: f64 = 0,
    /// Signed error from t = 1 s, per string (the case name's first word).
    bias_key: [48][12]u8 = undefined,
    bias_key_len: [48]usize = undefined,
    bias_sum: [48]f64 = [_]f64{0} ** 48,
    bias_n: [48]f64 = [_]f64{0} ** 48,
    bias_keys: usize = 0,

    fn biasSlot(self: *Player, key: []const u8) usize {
        for (0..self.bias_keys) |i| {
            if (std.mem.eql(u8, self.bias_key[i][0..self.bias_key_len[i]], key)) return i;
        }
        const i = self.bias_keys;
        const n = @min(key.len, 12);
        @memcpy(self.bias_key[i][0..n], key[0..n]);
        self.bias_key_len[i] = n;
        self.bias_keys += 1;
        return i;
    }
};

fn measurePlayer(alloc: std.mem.Allocator, pl: *Player, c: Case, sr: f64, rs: []const Display) !void {
    switch (c.group) {
        .hum, .noise, .muted, .hum_drift_idle => {
            var prev = false;
            for (rs) |r| {
                const on = r.note != null;
                if (on and !prev) pl.false_events += 1;
                prev = on;
            }
            pl.idle_s += @as(f64, @floatFromInt(rs.len)) / 30;
            return;
        },
        .two_notes, .ramp, .starts, .swells, .body, .sympathetic, .polar, .bass_fret => return,
        else => {},
    }
    const s = c.strings[0].?;
    pl.notes += 1;
    var settle1: ?f64 = null;
    var settle05: ?f64 = null;
    var sum: f64 = 0;
    var sum2: f64 = 0;
    var stable_n: f64 = 0;
    var last_note: ?i32 = null;
    var changes: f64 = 0;
    var octave = false;
    const key_end = std.mem.indexOfScalar(u8, c.name, ' ') orelse c.name.len;
    const slot = pl.biasSlot(c.name[0..key_end]);
    // Settling runs to the note's last reading shown: the gate ending a
    // decayed note on purpose is not a reading off the pitch.
    var last_shown: usize = 0;
    for (rs, 0..) |r, i| {
        if (r.hz != null) last_shown = i;
    }
    for (rs, 0..) |r, i| {
        const t = readTime(i, sr);
        if (t <= 0 or i > last_shown) continue;
        const truth = s.firstPartialHz(t);
        const e: ?f64 = if (r.hz) |hz| sig.cents(hz, truth) else null;
        if (e != null and @abs(e.?) <= 1) {
            if (settle1 == null) settle1 = t;
        } else settle1 = null;
        if (e != null and @abs(e.?) <= 0.5) {
            if (settle05 == null) settle05 = t;
        } else settle05 = null;
        if (r.stable) if (e) |v| {
            sum += v;
            sum2 += v * v;
            stable_n += 1;
        };
        if (r.note) |n| {
            if (last_note) |l| {
                if (l != n) changes += 1;
            }
            last_note = n;
            if (t >= 0.1) {
                const d = @abs(n - noteOf(truth));
                if ((d >= 11 and d <= 13) or (d >= 23 and d <= 25) or (d >= 35 and d <= 37)) octave = true;
            }
        }
        if (t >= 1) if (e) |v| {
            pl.bias_sum[slot] += v;
            pl.bias_n[slot] += 1;
        };
    }
    try pl.settle_1c.append(alloc, settle1 orelse std.math.inf(f64));
    try pl.settle_half_c.append(alloc, settle05 orelse std.math.inf(f64));
    if (stable_n >= 3) {
        const m = sum / stable_n;
        try pl.flicker.append(alloc, @sqrt(@max(0, sum2 / stable_n - m * m)));
    }
    try pl.name_changes.append(alloc, changes);
    if (octave) pl.notes_with_octave += 1;
}

const Results = struct {
    player: Player = .{},
    group: [groups.len]GroupStats = [_]GroupStats{.{}} ** groups.len,
    cpu: [rates.len]Cpu = [_]Cpu{.{}} ** rates.len,
    ticks: [rates.len]Ticks = [_]Ticks{.{}} ** rates.len,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const filter: []const u8 = if (args.len > 1) args[1] else "";
    const case_filter: ?[]const u8 = if (args.len > 2) args[2] else null;

    const all = [_]Candidate{
        try jsfxCandidate(allocator),
        try analyserCandidate(pitch.Analyser, "analyser", "the tuner's analyser", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .refinement = null }), "yin-only", "the analyser reporting YIN's period, unrefined", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .refinement = .pll }), "refine-pll", "the first partial by a phase-locked loop", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .refinement = .dtft_newton }), "refine-dtft", "the first partial by Newton on its DTFT power", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .refine_window_s = 0.2 }), "refine-0.2s", "the phase slope over at most 0.2 s", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .refine_window_s = 0.4 }), "refine-0.4s", "the phase slope over at most 0.4 s", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .octave_hold = 0 }), "no-octave-hold", "the analyser without the octave hold", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .smoothing = true }), "smoothing", "the analyser with the Hampel and one-euro filters", allocator),
        try analyserCandidateWith(pitch.AnalyserWith(.{ .floor_margin_db = null, .onset_gate = false, .release_drop_db = null, .mains_rule = false }), .{ .silence_db = -60 }, "fixed-gate", "the analyser gated only by the -60 dBFS silence threshold", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = null }), "no-floor", "the analyser without the learned noise floor", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .onset_gate = false }), "no-onset-gate", "the analyser showing notes without an onset", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .release_drop_db = null }), "no-release", "the analyser without the release check", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .mains_rule = true }), "mains-rule", "the analyser with the mains rule", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .several_guard = false }), "no-several-guard", "the analyser without the several-notes guard", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .hum_model = false }), "no-hum-model", "the analyser without the learned hum taken out", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .subharmonic_check = false }), "no-subharmonic-check", "the analyser without the subharmonic check", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .stable_spread_cents = null }), "no-stable-spread", "stable on the slope alone", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .slow_onset_db = null }), "no-slow-onset", "notes start only at an energy jump", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .lowpass_hz = null, .refinement = null, .octave_hold = 0, .floor_margin_db = null, .onset_gate = false, .release_drop_db = null, .slow_onset_db = null, .mains_start_hold = false, .comb_onset = false, .several_guard = false, .hum_model = false, .subharmonic_check = false, .stable_spread_cents = null, .yin_consistency = null, .hold_after_window = false }), "plain-yin", "YIN alone: no low-pass, refinement, hold, gates or guards", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 6 }), "sweep-floor-6", "learned-floor margin 6 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .onset_db = 3.03 }), "sweep-onset-6", "onset jump 3.03 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .slow_onset_db = 6 }), "sweep-rise-6", "slow-onset rise 6 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .release_drop_db = 14 }), "sweep-release-6", "release check 14 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 9 }), "sweep-floor-3", "learned-floor margin 9 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .onset_db = 6.03 }), "sweep-onset-3", "onset jump 6.03 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .slow_onset_db = 9 }), "sweep-rise-3", "slow-onset rise 9 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .release_drop_db = 17 }), "sweep-release-3", "release check 17 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 15 }), "sweep-floor+3", "learned-floor margin 15 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .onset_db = 12.03 }), "sweep-onset+3", "onset jump 12.03 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .slow_onset_db = 15 }), "sweep-rise+3", "slow-onset rise 15 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .release_drop_db = 23 }), "sweep-release+3", "release check 23 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 18 }), "sweep-floor+6", "learned-floor margin 18 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .onset_db = 15.03 }), "sweep-onset+6", "onset jump 15.03 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .slow_onset_db = 18 }), "sweep-rise+6", "slow-onset rise 18 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .release_drop_db = 26 }), "sweep-release+6", "release check 26 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .voicing_threshold = 0.1 }), "sweep-voicing-0.2", "voicing threshold 0.1", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .voicing_threshold = 0.2 }), "sweep-voicing-0.1", "voicing threshold 0.2", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .voicing_threshold = 0.4 }), "sweep-voicing+0.1", "voicing threshold 0.4", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .voicing_threshold = 0.5 }), "sweep-voicing+0.2", "voicing threshold 0.5", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .dip_threshold = 0.05 }), "sweep-dip-0.1", "YIN dip threshold 0.05", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .dip_threshold = 0.25 }), "sweep-dip+0.1", "YIN dip threshold 0.25", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .dip_threshold = 0.35 }), "sweep-dip+0.2", "YIN dip threshold 0.35", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 6, .onset_db = 3.03 }), "sweep-floor-onset-6", "floor margin and onset jump both -6 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 6, .slow_onset_db = 6 }), "sweep-floor-rise-6", "floor margin and slow-onset rise both -6 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 18, .onset_db = 15.03 }), "sweep-floor-onset+6", "floor margin and onset jump both +6 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .floor_margin_db = 18, .slow_onset_db = 18 }), "sweep-floor-rise+6", "floor margin and slow-onset rise both +6 dB", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .hold_after_window = false }), "hold-from-first", "the octave hold anchored on the first two readings after an onset", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .yin_consistency = null }), "no-yin-consistency", "YIN and the first partial always combined", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .comb_onset = false }), "no-comb-onset", "no onsets from what isn't the ringing note", allocator),
        try analyserCandidate(pitch.AnalyserWith(.{ .mains_start_hold = false }), "no-mains-hold", "notes that repeat at the mains period start at an onset like any other", allocator),
    };
    var cands: [all.len]Candidate = undefined;
    var nc: usize = 0;
    for (all) |c| {
        if (std.mem.indexOf(u8, c.name, filter) == null) continue;
        cands[nc] = c;
        nc += 1;
    }
    const results = try allocator.alloc(Results, nc);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};

    // The signals, or the 7 s tick-cost session.
    const len: usize = @intFromFloat(@max(lead_s + sustain_s, 7) * 96000 + 1);
    const buf = try allocator.alloc(f32, len);
    defer allocator.free(buf);
    const tmp = try allocator.alloc(f32, len);
    defer allocator.free(tmp);

    try w.print("tuner pitch-analyser targets ({s}, {s})\n", .{ @tagName(builtin.mode), @tagName(builtin.cpu.arch) });
    try w.flush();

    const cases = buildCases();
    for (cases, 0..) |c, ci| {
        if (case_filter) |f| if (std.mem.indexOf(u8, c.name, f) == null) continue;
        for (rates, 0..) |sr, ri| {
            const s = render(c, sr, 1 + ci * 7 + ri, buf, tmp);
            if (c.group == .swells) case_cross_s = levelCrossing(s, sr);
            for (cands[0..nc], results) |cand, *r| {
                const rs = run(cand, sr, s);
                if (case_filter != null) try trace(w, cand, c, sr, rs);
                try measure(allocator, &r.group[@intFromEnum(c.group)], c, sr, rs);
                try measurePlayer(allocator, &r.player, c, sr, rs);
            }
        }
    }
    if (case_filter != null) {
        try w.flush();
        return;
    }
    for (cands[0..nc], results) |cand, *r| {
        for (rates, 0..) |sr, ri| {
            r.cpu[ri] = try measureCpu(cand, sr, buf, tmp);
            r.ticks[ri] = try measureTicks(cand, sr, buf, tmp);
        }
    }

    try w.print("\n{d} signals at {d} rates. Candidates:\n\n", .{ cases.len, rates.len });
    for (cands[0..nc]) |c| try w.print("- {s}: {s}\n", .{ c.name, c.note });
    try printPlayer(w, cands[0..nc], results);
    try printTargets(w, cands[0..nc], results);
    try printPooledApart(w, cands[0..nc], results);
    try printTicks(w, cands[0..nc], results);
    try printHumFit(w, cands[0..nc], results);
    try printStarts(w, cands[0..nc], results);
    try printFindings(w, cands[0..nc], results);
    try printNames(w, cands[0..nc], results);
    for (cands[0..nc], results) |c, *r| try printDetail(w, c, r);
    try w.flush();
}

fn trace(w: anytype, cand: Candidate, c: Case, sr: f64, rs: []const Display) !void {
    try w.print("\n{s}, {s} @{d}k (t from the onset; cents vs f1(t))\n", .{ cand.name, c.name, sr / 1000 });
    for (rs, 0..) |r, i| {
        const t = readTime(i, sr);
        try w.print("{d:7.3} s ", .{t});
        if (r.note) |n| try w.print("note {d:3} ", .{n}) else try w.print("note   - ", .{});
        if (r.hz) |hz| {
            try w.print("{d:10.4} Hz", .{hz});
            if (c.strings[0]) |s| if (t > 0) try w.print(" {d:9.3} c", .{sig.cents(hz, s.firstPartialHz(t))});
        }
        if (r.stable) try w.print(" stable", .{});
        if (r.multiple) try w.print(" several", .{});
        try w.print("\n", .{});
    }
}

fn verdict(ok: bool) []const u8 {
    return if (ok) "pass" else "FAIL";
}

fn p95(alloc: std.mem.Allocator, st: GroupStats, settled: bool) f64 {
    const src = if (settled) st.settled_errors.items else st.errors.items;
    const copy = alloc.dupe(f64, src) catch return std.math.inf(f64);
    defer alloc.free(copy);
    return percentile(copy, 0.95);
}

/// The 95th percentile over the readings that showed cents only.
fn p95Shown(alloc: std.mem.Allocator, st: GroupStats) f64 {
    var shown: std.ArrayList(f64) = .empty;
    defer shown.deinit(alloc);
    for (st.errors.items) |e| if (std.math.isFinite(e)) shown.append(alloc, e) catch return std.math.inf(f64);
    return percentile(shown.items, 0.95);
}

fn printTargets(w: anytype, cands: []const Candidate, results: []Results) !void {
    const alloc = std.heap.page_allocator;
    try w.print(
        \\
        \\## Targets
        \\
        \\| candidate | glide P95 <= {d} c | steady P95 <= {d} c | beating P95 <= {d} c | jitter <= {d} c | octave errors = 0 | false notes = 0 | confident subharmonics = 0 | ramp within {d} c + {d} s | lock-on avg / worst (ms) <= {d:.1} / {d:.1} | hum under note P95 of shown <= {d} c, shown >= {d}% | hum drift P95 of shown <= {d} c, shown >= {d:.1}% | single strings flagged several = 0 | core at 30 Hz 48k / 96k <= {d}% |
        \\|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
        \\
    , .{ targets.glide_p95_cents, targets.steady_p95_cents, targets.beating_p95_cents, targets.jitter_cents, targets.ramp_cents, targets.ramp_lag_s, targets.lock_avg_ms, targets.lock_worst_ms, targets.hum_p95_cents, targets.hum_coverage_pct, targets.drift_p95_cents, targets.drift_coverage_pct, targets.cpu_percent });
    for (cands, results) |c, *r| {
        const g = &r.group;
        var glide: GroupStats = .{};
        defer glide.errors.deinit(alloc);
        try glide.errors.appendSlice(alloc, g[@intFromEnum(Group.glide_guitar)].errors.items);
        try glide.errors.appendSlice(alloc, g[@intFromEnum(Group.glide_bass)].errors.items);
        var steady: GroupStats = .{};
        defer steady.errors.deinit(alloc);
        try steady.errors.appendSlice(alloc, g[@intFromEnum(Group.stiff)].errors.items);
        try steady.errors.appendSlice(alloc, g[@intFromEnum(Group.weak)].errors.items);
        const glide_p = p95(alloc, glide, false);
        const steady_p = p95(alloc, steady, false);
        const beat_p = p95(alloc, g[@intFromEnum(Group.beating)], false);
        const jitter = @max(g[@intFromEnum(Group.stiff)].worst_jitter, @max(g[@intFromEnum(Group.weak)].worst_jitter, g[@intFromEnum(Group.beating)].worst_jitter));
        var octave: usize = 0;
        var lock_sum: f64 = 0;
        var lock_n: usize = 0;
        var lock_worst: f64 = 0;
        var lock_never: usize = 0;
        for (groups) |grp| {
            if (!grp.pitched() or grp.finding()) continue;
            const st = g[@intFromEnum(grp)];
            octave += st.octave;
            // Lock-on keeps the signals its baseline was measured on.
            if (grp == .hum_target or grp == .ks_weak or grp == .third or grp == .hum_drift or grp == .bass_h2) continue;
            lock_sum += st.lock_sum_ms;
            lock_n += st.lock_n;
            lock_never += st.lock_never;
            lock_worst = @max(lock_worst, st.lock_worst_ms);
        }
        const false_notes = g[@intFromEnum(Group.hum)].false_notes + g[@intFromEnum(Group.noise)].false_notes + g[@intFromEnum(Group.muted)].false_notes + g[@intFromEnum(Group.hum_drift_idle)].false_notes;
        const sub = g[@intFromEnum(Group.two_notes)].subharmonic;
        const ramp = g[@intFromEnum(Group.ramp)];
        const lock_avg = lock_sum / @as(f64, @floatFromInt(@max(lock_n, 1)));
        const cpu48 = coreShare(r.cpu[1]);
        const cpu96 = coreShare(r.cpu[3]);
        const hum = g[@intFromEnum(Group.hum_target)];
        var single_flagged: usize = 0;
        for (groups) |grp| {
            if (grp.pitched() and !grp.finding()) single_flagged += g[@intFromEnum(grp)].multiple;
        }
        const hum_p = p95Shown(alloc, hum);
        const hum_cover = 100 * @as(f64, @floatFromInt(hum.span_shown)) / @as(f64, @floatFromInt(@max(hum.span_reads, 1)));
        const drift = g[@intFromEnum(Group.hum_drift)];
        const drift_p = p95Shown(alloc, drift);
        const drift_cover = 100 * @as(f64, @floatFromInt(drift.span_shown)) / @as(f64, @floatFromInt(@max(drift.span_reads, 1)));
        try w.print("| {s} | {d:.3} {s} | {d:.3} {s} | {d:.3} {s} | {d:.3} {s} | {d} {s} | {d} {s} | {d} {s} | {d} of {d} over {s} | {d:.1} / {d:.1}{s} {s} |", .{
            c.name,
            glide_p,
            verdict(glide_p <= targets.glide_p95_cents),
            steady_p,
            verdict(steady_p <= targets.steady_p95_cents),
            beat_p,
            verdict(beat_p <= targets.beating_p95_cents),
            jitter,
            verdict(jitter <= targets.jitter_cents),
            octave,
            verdict(octave <= targets.octave_errors),
            false_notes,
            verdict(false_notes <= targets.false_notes),
            sub,
            verdict(sub <= targets.confident_subharmonics),
            ramp.ramp_over,
            ramp.ramp_reads,
            verdict(ramp.ramp_over == 0),
            lock_avg,
            lock_worst,
            if (lock_never > 0) " (some never)" else "",
            verdict(lock_never == 0 and lock_avg <= targets.lock_avg_ms + 1e-9 and lock_worst <= targets.lock_worst_ms + 1e-9),
        });
        try w.print(" {d:.3}, {d:.1}% {s} | {d:.3}, {d:.1}% {s} | {d} {s} | {d:.2}% / {d:.2}% {s} |\n", .{
            hum_p,
            hum_cover,
            verdict(hum_p <= targets.hum_p95_cents and hum_cover >= targets.hum_coverage_pct),
            drift_p,
            drift_cover,
            verdict(drift_p <= targets.drift_p95_cents and drift_cover >= targets.drift_coverage_pct),
            single_flagged,
            verdict(single_flagged <= targets.single_flagged),
            cpu48,
            cpu96,
            verdict(@max(cpu48, cpu96) <= targets.cpu_percent),
        });
    }
}

/// The pooled error targets' groups apart, and glide errors from 0.5 s:
/// reported beside the targets, not targets themselves.
fn printPooledApart(w: anytype, cands: []const Candidate, results: []Results) !void {
    const alloc = std.heap.page_allocator;
    try w.print(
        \\
        \\## Groups pooled by the targets, apart (reported, not targets)
        \\
        \\| candidate | stiff P95 (c) | weak P95 (c) | guitar glide P95 (c) | bass glide P95 (c) | glide P95 from 0.5 s (c) | guitar glide from 0.5 s (c) | bass glide from 0.5 s (c) | KS 880 Hz P95 (c), octave reads |
        \\|---|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for (cands, results) |c, *r| {
        const g = &r.group;
        var early: std.ArrayList(f64) = .empty;
        defer early.deinit(alloc);
        try early.appendSlice(alloc, g[@intFromEnum(Group.glide_guitar)].early_errors.items);
        try early.appendSlice(alloc, g[@intFromEnum(Group.glide_bass)].early_errors.items);
        const ks = g[@intFromEnum(Group.ks_weak)];
        try w.print("| {s} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {d:.3}, {d} |\n", .{
            c.name,
            p95(alloc, g[@intFromEnum(Group.stiff)], false),
            p95(alloc, g[@intFromEnum(Group.weak)], false),
            p95(alloc, g[@intFromEnum(Group.glide_guitar)], false),
            p95(alloc, g[@intFromEnum(Group.glide_bass)], false),
            percentileOf(alloc, early.items),
            percentileOf(alloc, g[@intFromEnum(Group.glide_guitar)].early_errors.items),
            percentileOf(alloc, g[@intFromEnum(Group.glide_bass)].early_errors.items),
            p95(alloc, ks, false),
            ks.octave,
        });
    }
}

/// The player-facing measures, which lead the report; the targets'
/// sub-cent numbers support them.
fn printPlayer(w: anytype, cands: []const Candidate, results: []Results) !void {
    const alloc = std.heap.page_allocator;
    try w.print(
        \\
        \\## What a player notices
        \\
        \\Over the plucked one-string signals; times from the onset, against f1(t). Bar: within 0.5 cent, and no string's bias over 0.2 cent.
        \\
        \\| candidate | to within 1 c: median / P90 (s), never | to within 0.5 c: median / P90 (s), never | flicker once stable: median / worst (c) | note-name changes per note: mean / worst | false notes per idle minute | notes with an octave reading | shown in 1-3 s | worst string bias (c) |
        \\|---|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for (cands, results) |c, *r| {
        const pl = &r.player;
        const a = try quantiles(alloc, pl.settle_1c.items);
        const b = try quantiles(alloc, pl.settle_half_c.items);
        const f = try quantiles(alloc, pl.flicker.items);
        var change_sum: f64 = 0;
        var change_worst: f64 = 0;
        for (pl.name_changes.items) |v| {
            change_sum += v;
            change_worst = @max(change_worst, v);
        }
        var shown: usize = 0;
        var reads: usize = 0;
        for (groups) |grp| {
            if (!grp.pitched() or grp == .ramp or grp.finding()) continue;
            shown += r.group[@intFromEnum(grp)].span_shown;
            reads += r.group[@intFromEnum(grp)].span_reads;
        }
        var worst_bias: f64 = 0;
        var worst_key: []const u8 = "";
        for (0..pl.bias_keys) |i| {
            if (pl.bias_n[i] == 0) continue;
            const m = pl.bias_sum[i] / pl.bias_n[i];
            if (@abs(m) > @abs(worst_bias)) {
                worst_bias = m;
                worst_key = pl.bias_key[i][0..pl.bias_key_len[i]];
            }
        }
        const notes: f64 = @floatFromInt(@max(pl.notes, 1));
        try w.print("| {s} | {d:.2} / {d:.2}, {d:.1}% | {d:.2} / {d:.2}, {d:.1}% | {d:.3} / {d:.3} | {d:.2} / {d:.0} | {d:.2} | {d:.1}% | {d:.1}% | {d:.3} {s} |\n", .{
            c.name,                                                      a.median,                                                                       a.p90,        a.never,
            b.median,                                                    b.p90,                                                                          b.never,      f.median,
            f.worst,                                                     change_sum / notes,                                                             change_worst, @as(f64, @floatFromInt(pl.false_events)) / @max(pl.idle_s / 60, 1e-9),
            100 * @as(f64, @floatFromInt(pl.notes_with_octave)) / notes, 100 * @as(f64, @floatFromInt(shown)) / @as(f64, @floatFromInt(@max(reads, 1))), worst_bias,   worst_key,
        });
    }
    try w.print("\n95% bootstrap intervals over notes ({d} resamples of the notes, with replacement):\n\n", .{bootstrap_resamples});
    for (cands, results) |c, *r| {
        const pl = &r.player;
        const m1 = try bootstrap(pl.settle_1c.items, .median);
        const p1 = try bootstrap(pl.settle_1c.items, .p90);
        const n1 = try bootstrap(pl.settle_1c.items, .never);
        const n05 = try bootstrap(pl.settle_half_c.items, .never);
        const fm = try bootstrap(pl.flicker.items, .median);
        const nc = try bootstrap(pl.name_changes.items, .mean);
        try w.print("- {s}: to within 1 c median [{d:.2}, {d:.2}] s, P90 [{d:.2}, {d:.2}] s, never [{d:.1}, {d:.1}]%; within 0.5 c never [{d:.1}, {d:.1}]%; flicker median [{d:.3}, {d:.3}] c; name changes per note [{d:.3}, {d:.3}]\n", .{ c.name, m1[0], m1[1], p1[0], p1[1], n1[0], n1[1], n05[0], n05[1], fm[0], fm[1], nc[0], nc[1] });
    }
    try w.print("\nSigned bias per string from 1 s (cents; one-string signals, every rate and spectrum):\n\n", .{});
    for (cands, results) |c, *r| {
        const pl = &r.player;
        try w.print("- {s}:", .{c.name});
        for (0..pl.bias_keys) |i| {
            if (pl.bias_n[i] == 0) continue;
            try w.print(" {s} {d:.3};", .{ pl.bias_key[i][0..pl.bias_key_len[i]], pl.bias_sum[i] / pl.bias_n[i] });
        }
        try w.print("\n", .{});
    }
}

const Quantiles = struct { median: f64, p90: f64, never: f64, worst: f64 };

const bootstrap_resamples = 1000;
const Statistic = enum { median, p90, never, mean };

/// The 2.5th and 97.5th percentiles of `stat` over resamples of `values`
/// (the same resamples every run).
fn bootstrap(values: []const f64, stat: Statistic) ![2]f64 {
    const alloc = std.heap.page_allocator;
    if (values.len == 0) return .{ std.math.nan(f64), std.math.nan(f64) };
    const sample = try alloc.alloc(f64, values.len);
    defer alloc.free(sample);
    var stats: [bootstrap_resamples]f64 = undefined;
    var rng = sig.MinStd.init(20261101);
    for (&stats) |*out| {
        for (sample) |*v| {
            const u = (rng.next() + 1) / 2;
            v.* = values[@min(values.len - 1, @as(usize, @intFromFloat(u * @as(f64, @floatFromInt(values.len)))))];
        }
        out.* = switch (stat) {
            .mean => blk: {
                var sum: f64 = 0;
                for (sample) |v| sum += v;
                break :blk sum / @as(f64, @floatFromInt(sample.len));
            },
            else => blk: {
                const q = try quantiles(alloc, sample);
                break :blk switch (stat) {
                    .median => q.median,
                    .p90 => q.p90,
                    .never => q.never,
                    .mean => unreachable,
                };
            },
        };
    }
    std.mem.sort(f64, &stats, {}, std.sort.asc(f64));
    return .{ stats[bootstrap_resamples * 25 / 1000], stats[bootstrap_resamples * 975 / 1000] };
}

/// Median, 90th percentile and worst of the finite values, and the share
/// that are infinite (never), percent.
fn quantiles(alloc: std.mem.Allocator, values: []const f64) !Quantiles {
    const copy = try alloc.dupe(f64, values);
    defer alloc.free(copy);
    std.mem.sort(f64, copy, {}, std.sort.asc(f64));
    var finite: usize = 0;
    for (copy) |v| {
        if (std.math.isFinite(v)) finite += 1;
    }
    const never = 100 * @as(f64, @floatFromInt(copy.len - finite)) / @as(f64, @floatFromInt(@max(copy.len, 1)));
    if (copy.len == 0) return .{ .median = std.math.nan(f64), .p90 = std.math.nan(f64), .never = 0, .worst = std.math.nan(f64) };
    // Never counts as later than any time, so it sits in the order.
    return .{
        .median = copy[copy.len / 2],
        .p90 = copy[@min(copy.len - 1, copy.len * 9 / 10)],
        .never = never,
        .worst = if (finite > 0) copy[finite - 1] else std.math.inf(f64),
    };
}

fn printNames(w: anytype, cands: []const Candidate, results: []Results) !void {
    try w.print(
        \\
        \\## Note names (targets: no body note renamed, no wrong name from the onset on, lock-on outside the finding groups <= {d:.1} / {d:.1} ms)
        \\
        \\| candidate | body notes renamed (of) | wrong-name readings: total, by group | lock-on avg / worst (ms) | body lock-on avg / worst (ms) | verdict |
        \\|---|---|---|---|---|---|
        \\
    , .{ targets.lock_avg_ms, targets.lock_worst_ms });
    for (cands, results) |c, *r| {
        const g = &r.group;
        var total: usize = 0;
        var by: [512]u8 = undefined;
        var len: usize = 0;
        var lock_sum: f64 = 0;
        var lock_n: usize = 0;
        var lock_worst: f64 = 0;
        for (groups) |grp| {
            if (!grp.pitched() or grp == .ramp) continue;
            const st = g[@intFromEnum(grp)];
            total += st.wrong_name;
            if (st.wrong_name > 0) len += (std.fmt.bufPrint(by[len..], " {s} {d};", .{ @tagName(grp), st.wrong_name }) catch "").len;
            if (grp.finding() or grp == .hum_target or grp == .ks_weak or grp == .third or grp == .hum_drift or grp == .bass_h2) continue;
            lock_sum += st.lock_sum_ms;
            lock_n += st.lock_n;
            lock_worst = @max(lock_worst, st.lock_worst_ms);
        }
        const body = g[@intFromEnum(Group.body)];
        const lock_avg = lock_sum / @as(f64, @floatFromInt(@max(lock_n, 1)));
        const ok = body.name_changed == 0 and total <= targets.wrong_names and lock_avg <= targets.lock_avg_ms + 1e-9 and lock_worst <= targets.lock_worst_ms + 1e-9;
        try w.print("| {s} | {d} ({d}) | {d}:{s} | {d:.1} / {d:.1} | {d:.1} / {d:.1} | {s} |\n", .{ c.name, body.name_changed, body.finding_notes, total, by[0..len], lock_avg, lock_worst, body.lock_sum_ms / @as(f64, @floatFromInt(@max(body.lock_n, 1))), body.lock_worst_ms, verdict(ok) });
    }
}

fn printFindings(w: anytype, cands: []const Candidate, results: []Results) !void {
    const alloc = std.heap.page_allocator;
    try w.print(
        \\
        \\## Held-out findings, on dev cases (targets: no octave reading or note-name change with body modes or sympathetic strings; sympathetic P95 <= {d} c; polarisations against both together: median to within 1 c <= {d} s guitar, {d} s bass, never <= {d}%, stable spread P90 <= {d} c; no signal's bias over {d} c on fretted bass or sympathetic strings)
        \\
        \\| candidate | body: octave reads, notes renamed (of) | sympathetic: octave reads, notes renamed (of), P95 (c), worst bias (c) | polar: to within 1 c guitar / bass median (s), never | polar stable spread median / P90 / worst (c) | fretted bass worst bias (c) | verdict |
        \\|---|---|---|---|---|---|---|
        \\
    , .{ targets.sympathetic_p95_cents, targets.polar_settle_guitar_s, targets.polar_settle_bass_s, targets.polar_never_pct, targets.polar_flicker_cents, targets.finding_bias_cents });
    for (cands, results) |c, *r| {
        const body = r.group[@intFromEnum(Group.body)];
        const sym = r.group[@intFromEnum(Group.sympathetic)];
        const pol = r.group[@intFromEnum(Group.polar)];
        const fret = r.group[@intFromEnum(Group.bass_fret)];
        const sym_p = p95(alloc, sym, false);
        const qg = try quantiles(alloc, pol.comp_settle_guitar.items);
        const qb = try quantiles(alloc, pol.comp_settle_bass.items);
        var never: usize = 0;
        for (pol.comp_settle_guitar.items) |v| never += @intFromBool(!std.math.isFinite(v));
        for (pol.comp_settle_bass.items) |v| never += @intFromBool(!std.math.isFinite(v));
        const never_pct = 100 * @as(f64, @floatFromInt(never)) / @as(f64, @floatFromInt(@max(pol.finding_notes, 1)));
        const flick = try alloc.dupe(f64, pol.comp_flicker.items);
        defer alloc.free(flick);
        const qf = try quantiles(alloc, flick);
        const flick_p90 = percentile(flick, 0.9);
        const ok = body.octave == 0 and body.name_changed == 0 and sym.octave == 0 and sym.name_changed == 0 and sym_p <= targets.sympathetic_p95_cents and @abs(sym.worst_bias) <= targets.finding_bias_cents and qg.median <= targets.polar_settle_guitar_s and qb.median <= targets.polar_settle_bass_s and never_pct <= targets.polar_never_pct and flick_p90 <= targets.polar_flicker_cents and @abs(fret.worst_bias) <= targets.finding_bias_cents;
        try w.print("| {s} | {d}, {d} ({d}) | {d}, {d} ({d}), {d:.3}, {d:.3} {s} | {d:.2} / {d:.2}, {d:.1}% | {d:.3} / {d:.3} / {d:.3} | {d:.3} {s} | {s} |\n", .{ c.name, body.octave, body.name_changed, body.finding_notes, sym.octave, sym.name_changed, sym.finding_notes, sym_p, sym.worst_bias, sym.worst_bias_case[0..sym.worst_bias_len], qg.median, qb.median, never_pct, qf.median, flick_p90, qf.worst, fret.worst_bias, fret.worst_bias_case[0..fret.worst_bias_len], verdict(ok) });
    }
}

fn printStarts(w: anytype, cands: []const Candidate, results: []Results) !void {
    const alloc = std.heap.page_allocator;
    try w.print(
        \\
        \\## Starts and swells (targets: none missed, starts within {d} s, swells within {d} s of 12 dB over the floor and P95 <= {d} c from 0.5 s on)
        \\
        \\| candidate | starts missed, of | time to show starts: median / worst (s) | swells missed, of | time to show swells: median / worst (s) | swells P95 (c), shown | verdict |
        \\|---|---|---|---|---|---|---|
        \\
    , .{ targets.start_show_s, targets.swell_show_s, targets.swell_p95_cents });
    for (cands, results) |c, *r| {
        const a = r.group[@intFromEnum(Group.starts)];
        const b = r.group[@intFromEnum(Group.swells)];
        const qa = try quantiles(alloc, a.show_s.items);
        const qb = try quantiles(alloc, b.show_s.items);
        const p = p95(alloc, b, false);
        const cover = 100 * @as(f64, @floatFromInt(b.span_shown)) / @as(f64, @floatFromInt(@max(b.span_reads, 1)));
        const ok = a.start_missed == 0 and b.start_missed == 0 and p <= targets.swell_p95_cents;
        try w.print("| {s} | {d} of {d} | {d:.3} / {d:.3} | {d} of {d} | {d:.3} / {d:.3} | {d:.3}, {d:.1}% | {s} |\n", .{ c.name, a.start_missed, a.start_notes, qa.median, qa.worst, b.start_missed, b.start_notes, qb.median, qb.worst, p, cover, verdict(ok) });
    }
    for (cands, results) |c, *r| {
        try w.print("\n{s}: starts missed: {s}\n{s}: swells missed: {s}\n", .{ c.name, r.group[@intFromEnum(Group.starts)].missed.items, c.name, r.group[@intFromEnum(Group.swells)].missed.items });
    }
}

fn printHumFit(w: anytype, cands: []const Candidate, results: []Results) !void {
    try w.print(
        \\
        \\## Hum that changes in a note (targets: no stable reading over 0.5 c off in hum_drift; stable readings where the hum holds still >= {d})
        \\
        \\| candidate | hum_drift stable readings, over 0.5 c off | hum_target + hum_note stable readings | verdict |
        \\|---|---|---|---|
        \\
    , .{targets.steady_hum_stable});
    for (cands, results) |c, *r| {
        const d = r.group[@intFromEnum(Group.hum_drift)];
        const steady = r.group[@intFromEnum(Group.hum_target)].stable_reads + r.group[@intFromEnum(Group.hum_note)].stable_reads;
        const ok = d.stable_wrong <= targets.drift_stable_wrong and steady >= targets.steady_hum_stable;
        try w.print("| {s} | {d}, {d} | {d} | {s} |\n", .{ c.name, d.stable_reads, d.stable_wrong, steady, verdict(ok) });
    }
}

fn printTicks(w: anytype, cands: []const Candidate, results: []Results) !void {
    try w.print(
        \\
        \\## Per-tick cost (target: no-onset mean <= {d}x the played mean, every tick < {d:.0} us)
        \\
        \\| candidate | 48k no onset mean / worst (us) | 48k played mean / worst (us) | 96k no onset mean / worst (us) | 96k played mean / worst (us) | verdict |
        \\|---|---|---|---|---|---|
        \\
    , .{ targets.tick_idle_ratio, targets.tick_worst_us });
    for (cands, results) |c, *r| {
        var ok = true;
        for ([_]usize{ 1, 3 }) |ri| {
            const t = r.ticks[ri];
            if (t.idle_mean_us > targets.tick_idle_ratio * t.played_mean_us) ok = false;
            if (@max(t.idle_worst_us, t.played_worst_us) >= targets.tick_worst_us) ok = false;
        }
        const a = r.ticks[1];
        const b = r.ticks[3];
        try w.print("| {s} | {d:.0} / {d:.0} | {d:.0} / {d:.0} | {d:.0} / {d:.0} | {d:.0} / {d:.0} | {s} |\n", .{ c.name, a.idle_mean_us, a.idle_worst_us, a.played_mean_us, a.played_worst_us, b.idle_mean_us, b.idle_worst_us, b.played_mean_us, b.played_worst_us, verdict(ok) });
    }
}

fn percentileOf(alloc: std.mem.Allocator, values: []const f64) f64 {
    const copy = alloc.dupe(f64, values) catch return std.math.inf(f64);
    defer alloc.free(copy);
    return percentile(copy, 0.95);
}

fn printDetail(w: anytype, c: Candidate, r: *Results) !void {
    const alloc = std.heap.page_allocator;
    try w.print("\n## {s}\n\n| group | reads | P95 |err| vs f1(t) (c) | shown in 1-3 s | P95 over shown (c) | P95 vs settled f1 (c) | worst (c) | worst jitter (c) | octave | other wrong note | flagged several | lock-on avg / worst (ms), never | to stable within 1 c avg / worst (ms), never | first stable flag avg (ms), never |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n", .{c.name});
    for (groups) |grp| {
        if (!grp.pitched() or grp == .ramp) continue;
        const st = r.group[@intFromEnum(grp)];
        var jitter_buf: [64]u8 = undefined;
        const jitter = if (st.worst_jitter_len > 0) std.fmt.bufPrint(&jitter_buf, "{d:.3} {s}", .{ st.worst_jitter, st.worst_jitter_case[0..st.worst_jitter_len] }) catch "?" else "n/a";
        try w.print("| {s} | {d} | {d:.3} | {d:.1}% | {d:.3} | {d:.3} | {d:.3} {s} | {s} | {d} | {d} | {d} | {d:.0} / {d:.0}, {d} | {d:.0} / {d:.0}, {d} | {d:.0}, {d} |\n", .{
            @tagName(grp),
            st.reads,
            p95(alloc, st, false),
            100 * @as(f64, @floatFromInt(st.span_shown)) / @as(f64, @floatFromInt(@max(st.span_reads, 1))),
            p95Shown(alloc, st),
            p95(alloc, st, true),
            st.worst_error,
            st.worst_error_case[0..st.worst_error_len],
            jitter,
            st.octave,
            st.wrong_note,
            st.multiple,
            st.lock_sum_ms / @as(f64, @floatFromInt(@max(st.lock_n, 1))),
            st.lock_worst_ms,
            st.lock_never,
            st.stable_sum_ms / @as(f64, @floatFromInt(@max(st.stable_n, 1))),
            st.stable_worst_ms,
            st.stable_never,
            st.flag_sum_ms / @as(f64, @floatFromInt(@max(st.flag_n, 1))),
            st.flag_never,
        });
    }
    const beating = r.group[@intFromEnum(Group.beating)];
    const composite = try alloc.dupe(f64, beating.composite_errors.items);
    defer alloc.free(composite);
    try w.print("\nBeating, against the instantaneous frequency of both polarisations' first partial together: P95 {d:.3} c.", .{percentile(composite, 0.95)});
    const ramp = r.group[@intFromEnum(Group.ramp)];
    try w.print("\nRamp: {d} of {d} reads over the allowance, worst {d:.2} c; octave {d}, other wrong note {d}.\n", .{ ramp.ramp_over, ramp.ramp_reads, ramp.ramp_worst, ramp.octave, ramp.wrong_note });
    const two = r.group[@intFromEnum(Group.two_notes)];
    try w.print("Two notes (reads from 0.1 s): lower {d}, upper {d}, other {d}, none {d}; flagged several {d}; confident subharmonic {d}.\n", .{ two.two[0], two.two[1], two.two[2], two.two[3], two.multiple, two.subharmonic });
    try w.print("False notes: hum/buzz {d} of {d} reads, noise {d} of {d}, muted {d} of {d}.\n", .{
        r.group[@intFromEnum(Group.hum)].false_notes,   r.group[@intFromEnum(Group.hum)].reads,
        r.group[@intFromEnum(Group.noise)].false_notes, r.group[@intFromEnum(Group.noise)].reads,
        r.group[@intFromEnum(Group.muted)].false_notes, r.group[@intFromEnum(Group.muted)].reads,
    });
    try w.print("CPU:", .{});
    for (rates, r.cpu) |sr, cpu| try w.print(" {d}k: push {d:.0} us/s, analyse mean {d:.1} us, max {d:.1} us, {d:.3}% of a core;", .{ sr / 1000, cpu.push_ns_per_s / 1000, cpu.analyse_mean_ns / 1000, cpu.analyse_max_ns / 1000, coreShare(cpu) });
    try w.print("\n", .{});
}
