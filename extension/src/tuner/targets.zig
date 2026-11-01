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
    /// Hum or buzz alone.
    hum,
    /// A noise floor alone.
    noise,
    /// Fretting-hand-muted strokes.
    muted,

    fn pitched(g: Group) bool {
        return switch (g) {
            .hum, .noise, .muted, .two_notes, .hum_drift_idle => false,
            else => true,
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
    /// A pickup switch's click (5 ms of noise at peak 0.03) at this time.
    click_at_s: ?f64 = null,
    /// Render strings[0] as a Karplus-Strong pluck (t60 3 s, peak 0.9) with
    /// this seed instead; its fundamental is at f0 exactly.
    ks_seed: ?u64 = null,
};

const Str = struct { name: []const u8, f0: f64, b: f64 };

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

const max_cases = 260;
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
    for (c.strings) |maybe| {
        const s = maybe orelse continue;
        const body = tmp[0 .. n - onset];
        if (c.ks_seed) |seed_ks| sig.pluck(body, sr, s.f0, .{ .amp = 0.9, .t60_s = 3, .seed = seed_ks }) else sig.pluckedString(body, sr, s);
        sig.mix(out[onset..], body);
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

fn measure(alloc: std.mem.Allocator, st: *GroupStats, c: Case, sr: f64, rs: []const Display) !void {
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
        if (t < 0.1) continue;
        const truth = s.firstPartialHz(t);
        if (r.multiple) st.multiple += 1;
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
        .two_notes, .ramp => return,
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
            if (!grp.pitched()) continue;
            const st = g[@intFromEnum(grp)];
            octave += st.octave;
            // Lock-on keeps the signals its baseline was measured on.
            if (grp == .hum_target or grp == .ks_weak or grp == .third or grp == .hum_drift) continue;
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
            if (grp.pitched()) single_flagged += g[@intFromEnum(grp)].multiple;
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
            if (!grp.pitched() or grp == .ramp) continue;
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
            c.name,                                       a.median,                          a.p90, a.never,
            b.median,                                     b.p90,                             b.never, f.median,
            f.worst,                                      change_sum / notes,                change_worst,
            @as(f64, @floatFromInt(pl.false_events)) / @max(pl.idle_s / 60, 1e-9),
            100 * @as(f64, @floatFromInt(pl.notes_with_octave)) / notes,
            100 * @as(f64, @floatFromInt(shown)) / @as(f64, @floatFromInt(@max(reads, 1))),
            worst_bias,                                   worst_key,
        });
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
