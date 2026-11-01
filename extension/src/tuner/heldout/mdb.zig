//! Held-out check of the tuner's pitch analyser on MDB-bass-synth
//! (Salamon et al., ISMIR 2017): 71 bass stems from MedleyDB, resynthesised
//! from their analysed f0 so the annotation is exact for the audio, with
//! the songs' mixes. It is held out: nothing in the analyser was chosen
//! by measuring it, and this runner uses only the analyser's public API (`init`, `push`, `analyse`,
//! `lastOnset`, `Reading`, `Settings`).
//!
//! The dataset is CC BY-NC 4.0 and stays outside the repository: pass its
//! `MDB-bass-synth` directory as the first argument or in MDB_BASS_SYNTH.
//!
//! Each stem is fed as the tuner feeds it: 256-sample pushes at the file's
//! own rate and one `analyse` every 1/30 s of input, with default settings
//! (chromatic, A4 = 440 Hz, silence at -90 dBFS) unless `--range` is given.
//! Readings are aligned with the annotation (one f0 every 128/44100 s, 0 for
//! unvoiced, the first frame centred on 0 s) by the time of the reading's
//! last input sample. Every pitch comparison is in cents, so a song tuned
//! away from 440 Hz costs nothing, and a reading within 50 c of the
//! annotation is the right note even where the two round to different
//! note names.
//!
//! Units, and what the bootstrap resamples:
//! - Silence runs: unvoiced stretches of 200 ms or more. A reading shown
//!   while its whole 100 ms window lies inside one is a false note.
//! - Voiced runs: voiced stretches. A shown reading at a voiced frame is
//!   judged against the annotated f0 at its own frame (strict) and against
//!   the nearest annotated f0 in its window (lag-tolerant, so the window
//!   still holding the previous note is not an error).
//! - Sustained segments: stretches of voiced frames within a 40 c band
//!   (+-20 c of the band's middle, not of an equal-tempered note, so a
//!   detuned recording still has segments) lasting 0.5 s or more. Accuracy
//!   counts readings from 150 ms after the segment's start. A segment
//!   starting within 150 ms of its voiced run's start follows an onset,
//!   split by whether 100 ms or more of silence precedes the run; any other
//!   segment is reached legato.
//!
//! The reading's frequency is the first partial measured over the input
//! since the analyser's last onset, at most 0.3 s. Its truth is therefore
//! the mean annotated pitch (in cents) over the frames from the latest of
//! the segment's start, the last onset and 0.3 s back, to the reading;
//! the error against the annotation at the reading's own frame is reported
//! beside it.
const std = @import("std");
const pitch = @import("pitch");
const wav_mod = @import("wav");

const hop_s: f64 = 128.0 / 44100.0;
const push_len = 256;
const analyse_hz: f64 = 30.0;
/// A reading's YIN window is 92.9 ms; frames this far back may still be
/// heard in it.
const window_s: f64 = 0.1;
const silence_min_s: f64 = 0.2;
const segment_band_cents: f64 = 40;
const segment_min_s: f64 = 0.5;
const accuracy_from_s: f64 = 0.15;
const refine_s: f64 = 0.3;
const clear_onset_gap_s: f64 = 0.1;
const onset_settle_s: f64 = 0.15;
/// A reading whose refinement span's annotated pitch varies by no more than
/// this is "flat": its truth hardly depends on how the span is weighted.
/// The annotation is the performance's own f0, which moves: over 0.3 s of
/// voicing it varies by under 2 c almost nowhere and by under 5 c in about
/// 5% of windows (a quarter of the sustained segments' readings).
const flat_span_cents: f64 = 5;
/// Shorter truth spans, to see which one the readings follow: the
/// refinement's own span is `refine_s`.
const alt_spans_s = [_]f64{ 0.05, 0.1, 0.2 };
/// Bins of the annotated pitch's movement over a reading's span, in cents.
const movement_bins = [_]f64{ 5, 10, 20, 40 };
const right_note_cents: f64 = 50;
const bootstrap_reps = 1000;

const usage_text =
    \\usage: zig build tuner-mdb -Doptimize=ReleaseFast -- [MDB-bass-synth dir]
    \\         [--out dir] [--tracks substring] [--range low_hz high_hz] [--mix N]
    \\The directory defaults to $MDB_BASS_SYNTH. --out writes per-segment,
    \\per-track and failure CSVs there (never inside the repository).
    \\--mix N also runs the first N mixes, as an exploratory master-tuner check.
    \\
;

fn cents(hz: f64) f64 {
    return 1200 * @log2(hz / 440.0) + 6900;
}

fn frameAt(t: f64) isize {
    return @intFromFloat(@round(t / hop_s));
}

const Read = struct {
    t: f64,
    hz: f64,
    note: i32,
    settling: bool,
    onset_s: ?f64,
};

const OnsetKind = enum { clear, short_gap, legato };

const SilenceRun = struct {
    track: u16,
    start_s: f64,
    end_s: f64,
    eligible_s: f64,
    /// Peak level inside the run, 20 ms in from each edge.
    peak_db: f64,
    false_reads: u32 = 0,
    events: u32 = 0,
};

const VoicedRun = struct {
    track: u16,
    shown: u32 = 0,
    shown_firm: u32 = 0,
    strict_octave: u32 = 0,
    strict_other: u32 = 0,
    octave: u32 = 0,
    other: u32 = 0,
    octave_firm: u32 = 0,
    other_firm: u32 = 0,
};

const Segment = struct {
    track: u16,
    start_s: f64,
    end_s: f64,
    median_hz: f64,
    kind: OnsetKind,
    /// From its voiced run's start (the note's onset) to the segment's.
    after_run_start_s: f64,
    reads: u32 = 0,
    shown: u32 = 0,
    right: u32 = 0,
    acc_shown: u32 = 0,
    acc_wrong: u32 = 0,
    errs_at: u32 = 0,
    errs_len: u32 = 0,
    to_1c_s: f64 = std.math.nan(f64),
    lock_s: f64 = std.math.nan(f64),
    p95_abs: f64 = std.math.nan(f64),
};

const FalseEvent = struct { track: u16, t0: f64, t1: f64, note: i32, reads: u32 };
const NoteErrorEvent = struct { track: u16, t0: f64, t1: f64, shown_note: i32, true_note: i32, octave: bool, reads: u32 };

const Results = struct {
    tracks: std.ArrayList([]const u8) = .empty,
    track_minutes: std.ArrayList(f64) = .empty,
    silences: std.ArrayList(SilenceRun) = .empty,
    voiced: std.ArrayList(VoicedRun) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    errs: std.ArrayList(f64) = .empty,
    errs_inst: std.ArrayList(f64) = .empty,
    errs_flat: std.ArrayList(bool) = .empty,
    /// Per accuracy reading: how far the annotated pitch moves over its span.
    errs_movement: std.ArrayList(f64) = .empty,
    /// Per accuracy reading: |error| against each of `alt_spans_s`.
    errs_alt: [alt_spans_s.len]std.ArrayList(f64) = .{std.ArrayList(f64).empty} ** alt_spans_s.len,
    false_events: std.ArrayList(FalseEvent) = .empty,
    note_errors: std.ArrayList(NoteErrorEvent) = .empty,
    /// Per octave-error reading: its distance in cents from the nearest
    /// whole octave of the annotation, i.e. how far off the cents shown are.
    octave_residual: std.ArrayList(f64) = .empty,
    edge_reads: u64 = 0,
    reads: u64 = 0,
};

/// The annotation's f0 per frame; 0 is unvoiced.
fn parseAnnotation(gpa: std.mem.Allocator, text: []const u8) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, ',');
        const t = try std.fmt.parseFloat(f64, std.mem.trim(u8, cols.next() orelse return error.BadAnnotation, " "));
        const f = try std.fmt.parseFloat(f64, std.mem.trim(u8, cols.next() orelse return error.BadAnnotation, " "));
        if (@abs(t - @as(f64, @floatFromInt(out.items.len)) * hop_s) > 0.001) return error.AnnotationNotOnHop;
        try out.append(gpa, if (f > 0) f else 0);
    }
    return out.toOwnedSlice(gpa);
}

/// Feeds `mono` as the tuner does and returns every reading.
fn runAnalyser(gpa: std.mem.Allocator, mono: []const f32, rate: f64, settings: pitch.Settings) ![]Read {
    const analyser = try gpa.create(pitch.Analyser);
    defer gpa.destroy(analyser);
    try analyser.init(rate);
    var reads: std.ArrayList(Read) = .empty;
    var pushed: usize = 0;
    var k: usize = 1;
    while (true) : (k += 1) {
        const due: usize = @intFromFloat(@round(@as(f64, @floatFromInt(k)) * rate / analyse_hz));
        if (due > mono.len) break;
        while (pushed + push_len <= due) : (pushed += push_len) analyser.push(mono[pushed .. pushed + push_len]);
        const r = analyser.analyse(settings);
        const onset: ?f64 = if (analyser.lastOnset()) |o| @as(f64, @floatFromInt(o)) / rate else null;
        try reads.append(gpa, .{
            .t = @as(f64, @floatFromInt(pushed)) / rate,
            .hz = if (r.freq_hz > 0 and std.math.isFinite(r.freq_hz)) r.freq_hz else 0,
            .note = r.note,
            .settling = r.settling,
            .onset_s = onset,
        });
    }
    return reads.toOwnedSlice(gpa);
}

const Judgement = enum { right, octave, other };

/// A pitch error in cents: within 50 c is the right note; otherwise an
/// octave error when the nearest whole number of semitones is a nonzero
/// multiple of 12.
fn judge(d: f64) Judgement {
    if (@abs(d) <= right_note_cents) return .right;
    const semis: i64 = @intFromFloat(@round(d / 100));
    return if (@mod(semis, 12) == 0) .octave else .other;
}

const SegmentSpan = struct { lo: usize, hi: usize }; // frames, hi exclusive

/// Sustained segments in `c` (cents per frame, NaN for unvoiced): maximal
/// stretches of voiced frames whose pitch spans at most the band, of at
/// least `min_frames`. Segments don't overlap: after one ends, the next
/// starts at the frame that broke it; when a stretch is too short, its
/// start slides forward to keep the newest frames that fit the band.
fn findSegments(gpa: std.mem.Allocator, c: []const f64, band: f64, min_frames: usize) ![]SegmentSpan {
    var out: std.ArrayList(SegmentSpan) = .empty;
    var lo: usize = 0;
    var mn: f64 = 0;
    var mx: f64 = 0;
    var open = false;
    var j: usize = 0;
    while (j <= c.len) : (j += 1) {
        const voiced = j < c.len and !std.math.isNan(c[j]);
        if (!voiced) {
            if (open and j - lo >= min_frames) try out.append(gpa, .{ .lo = lo, .hi = j });
            open = false;
            continue;
        }
        if (!open) {
            lo = j;
            mn = c[j];
            mx = c[j];
            open = true;
            continue;
        }
        const nmn = @min(mn, c[j]);
        const nmx = @max(mx, c[j]);
        if (nmx - nmn <= band) {
            mn = nmn;
            mx = nmx;
            continue;
        }
        if (j - lo >= min_frames) {
            try out.append(gpa, .{ .lo = lo, .hi = j });
            lo = j;
            mn = c[j];
            mx = c[j];
        } else {
            var k = j;
            mn = c[j];
            mx = c[j];
            while (k > lo) {
                const a = @min(mn, c[k - 1]);
                const b = @max(mx, c[k - 1]);
                if (b - a > band) break;
                mn = a;
                mx = b;
                k -= 1;
            }
            lo = k;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Scores one track's readings against its annotation into `res`.
fn scoreTrack(gpa: std.mem.Allocator, res: *Results, track: u16, annot: []const f64, mono: []const f32, rate: f64, reads: []const Read) !void {
    const n = annot.len;
    const c = try gpa.alloc(f64, n);
    defer gpa.free(c);
    for (annot, c) |f, *x| x.* = if (f > 0) cents(f) else std.math.nan(f64);

    // Runs: each frame's silence run (long ones only) or voiced run.
    const none: u32 = std.math.maxInt(u32);
    const silence_of = try gpa.alloc(u32, n);
    defer gpa.free(silence_of);
    const voiced_of = try gpa.alloc(u32, n);
    defer gpa.free(voiced_of);
    @memset(silence_of, none);
    @memset(voiced_of, none);
    var i: usize = 0;
    while (i < n) {
        var e = i;
        const v = annot[i] > 0;
        while (e < n and (annot[e] > 0) == v) e += 1;
        const len_s = @as(f64, @floatFromInt(e - i)) * hop_s;
        if (v) {
            const id: u32 = @intCast(res.voiced.items.len);
            try res.voiced.append(gpa, .{ .track = track });
            @memset(voiced_of[i..e], id);
        } else if (len_s >= silence_min_s) {
            const s0: usize = @min(mono.len, @as(usize, @intFromFloat((@as(f64, @floatFromInt(i)) * hop_s + 0.02) * rate)));
            const s1: usize = @min(mono.len, @as(usize, @intFromFloat((@as(f64, @floatFromInt(e)) * hop_s - 0.02) * rate)));
            var peak: f32 = 0;
            if (s1 > s0) for (mono[s0..s1]) |s| {
                peak = @max(peak, @abs(s));
            };
            const id: u32 = @intCast(res.silences.items.len);
            try res.silences.append(gpa, .{
                .track = track,
                .start_s = @as(f64, @floatFromInt(i)) * hop_s,
                .end_s = @as(f64, @floatFromInt(e)) * hop_s,
                .eligible_s = len_s - window_s,
                .peak_db = if (peak > 0) 20 * @log10(@as(f64, peak)) else -200,
            });
            @memset(silence_of[i..e], id);
        }
        i = e;
    }

    // False notes and wrong notes, reading by reading.
    var false_open: ?usize = null;
    var err_open: ?usize = null;
    for (reads) |r| {
        const fi = frameAt(r.t);
        if (fi < 0 or fi >= n) continue;
        const f: usize = @intCast(fi);
        res.reads += 1;
        const w0: usize = @intCast(@max(0, frameAt(r.t - window_s)));
        const shown = r.hz > 0;
        const in_silence = silence_of[f] != none and silence_of[w0] == silence_of[f];

        if (in_silence and shown) {
            const run = &res.silences.items[silence_of[f]];
            run.false_reads += 1;
            if (false_open) |fe| {
                res.false_events.items[fe].t1 = r.t;
                res.false_events.items[fe].reads += 1;
            } else {
                run.events += 1;
                false_open = res.false_events.items.len;
                try res.false_events.append(gpa, .{ .track = track, .t0 = r.t, .t1 = r.t, .note = r.note, .reads = 1 });
            }
        } else false_open = null;

        if (!shown) {
            err_open = null;
            continue;
        }
        if (voiced_of[f] == none) {
            if (!in_silence) res.edge_reads += 1;
            err_open = null;
            continue;
        }
        const run = &res.voiced.items[voiced_of[f]];
        const rc = cents(r.hz);
        const strict = judge(rc - c[f]);
        var best: f64 = rc - c[f];
        for (w0..f + 1) |k| {
            if (std.math.isNan(c[k])) continue;
            if (@abs(rc - c[k]) < @abs(best)) best = rc - c[k];
        }
        const tolerant = judge(best);
        run.shown += 1;
        if (!r.settling) run.shown_firm += 1;
        switch (strict) {
            .octave => run.strict_octave += 1,
            .other => run.strict_other += 1,
            .right => {},
        }
        switch (tolerant) {
            .octave => {
                run.octave += 1;
                try res.octave_residual.append(gpa, @abs(best - 1200 * @round(best / 1200)));
                if (!r.settling) run.octave_firm += 1;
            },
            .other => {
                run.other += 1;
                if (!r.settling) run.other_firm += 1;
            },
            .right => {},
        }
        if (tolerant == .right) {
            err_open = null;
        } else if (err_open) |ee| {
            res.note_errors.items[ee].t1 = r.t;
            res.note_errors.items[ee].reads += 1;
        } else {
            err_open = res.note_errors.items.len;
            try res.note_errors.append(gpa, .{
                .track = track,
                .t0 = r.t,
                .t1 = r.t,
                .shown_note = r.note,
                .true_note = @intFromFloat(@round(c[f] / 100)),
                .octave = tolerant == .octave,
                .reads = 1,
            });
        }
    }

    // Sustained segments.
    const spans = try findSegments(gpa, c, segment_band_cents, @intFromFloat(@ceil(segment_min_s / hop_s)));
    defer gpa.free(spans);
    const sorted = try gpa.alloc(f64, n);
    defer gpa.free(sorted);
    const gap_frames: usize = @intFromFloat(@ceil(clear_onset_gap_s / hop_s));
    for (spans) |sp| {
        const vals = sorted[0 .. sp.hi - sp.lo];
        @memcpy(vals, c[sp.lo..sp.hi]);
        std.mem.sort(f64, vals, {}, std.sort.asc(f64));
        const median_c = quantileSorted(vals, 0.5);
        // A segment within 150 ms of its voiced run's start follows that
        // run's onset (a pitch settling into the band first is still the
        // same note); any later one is reached legato.
        var v0 = sp.lo;
        while (v0 > 0 and annot[v0 - 1] > 0) v0 -= 1;
        var kind: OnsetKind = .legato;
        if (@as(f64, @floatFromInt(sp.lo - v0)) * hop_s <= onset_settle_s) {
            kind = .short_gap;
            if (v0 >= gap_frames) {
                var all_silent = true;
                for (annot[v0 - gap_frames .. v0]) |f| all_silent = all_silent and f == 0;
                if (all_silent) kind = .clear;
            }
        }
        var seg: Segment = .{
            .track = track,
            .start_s = @as(f64, @floatFromInt(sp.lo)) * hop_s,
            .end_s = @as(f64, @floatFromInt(sp.hi)) * hop_s,
            .median_hz = 440 * std.math.pow(f64, 2, (median_c - 6900) / 1200),
            .kind = kind,
            .after_run_start_s = @as(f64, @floatFromInt(sp.lo - v0)) * hop_s,
            .errs_at = @intCast(res.errs.items.len),
        };
        var r_i = std.sort.lowerBound(Read, reads, seg.start_s, struct {
            fn cmp(t: f64, r: Read) std.math.Order {
                return std.math.order(t, r.t);
            }
        }.cmp);
        while (r_i < reads.len and reads[r_i].t < seg.end_s) : (r_i += 1) {
            const r = reads[r_i];
            const f: usize = @intCast(frameAt(r.t));
            if (f < sp.lo or f >= sp.hi) continue;
            seg.reads += 1;
            if (r.hz <= 0) continue;
            seg.shown += 1;
            // The reading's truth: the mean pitch over its refinement span.
            var from = @max(seg.start_s, r.t - refine_s);
            if (r.onset_s) |o| from = @max(from, o);
            const k0: usize = @intCast(std.math.clamp(frameAt(from), @as(isize, @intCast(sp.lo)), @as(isize, @intCast(f))));
            var sum: f64 = 0;
            var span_lo = c[f];
            var span_hi = c[f];
            for (c[k0 .. f + 1]) |x| {
                sum += x;
                span_lo = @min(span_lo, x);
                span_hi = @max(span_hi, x);
            }
            const truth = sum / @as(f64, @floatFromInt(f + 1 - k0));
            const rc = cents(r.hz);
            const d = rc - truth;
            if (@abs(d) <= right_note_cents) {
                seg.right += 1;
                if (std.math.isNan(seg.lock_s)) seg.lock_s = r.t - seg.start_s;
            }
            if (@abs(d) <= 1 and std.math.isNan(seg.to_1c_s)) seg.to_1c_s = r.t - seg.start_s;
            if (r.t >= seg.start_s + accuracy_from_s) {
                seg.acc_shown += 1;
                if (@abs(d) <= right_note_cents) {
                    try res.errs.append(gpa, d);
                    try res.errs_inst.append(gpa, rc - c[f]);
                    try res.errs_flat.append(gpa, span_hi - span_lo <= flat_span_cents);
                    try res.errs_movement.append(gpa, span_hi - span_lo);
                    for (alt_spans_s, &res.errs_alt) |len_s, *list| {
                        var alt_from = @max(seg.start_s, r.t - len_s);
                        if (r.onset_s) |o| alt_from = @max(alt_from, o);
                        const a0: usize = @intCast(std.math.clamp(frameAt(alt_from), @as(isize, @intCast(sp.lo)), @as(isize, @intCast(f))));
                        var alt_sum: f64 = 0;
                        for (c[a0 .. f + 1]) |x| alt_sum += x;
                        try list.append(gpa, @abs(rc - alt_sum / @as(f64, @floatFromInt(f + 1 - a0))));
                    }
                } else seg.acc_wrong += 1;
            }
        }
        seg.errs_len = @as(u32, @intCast(res.errs.items.len)) - seg.errs_at;
        if (seg.errs_len > 0) {
            const e = try gpa.alloc(f64, seg.errs_len);
            defer gpa.free(e);
            for (res.errs.items[seg.errs_at..][0..seg.errs_len], e) |x, *y| y.* = @abs(x);
            std.mem.sort(f64, e, {}, std.sort.asc(f64));
            seg.p95_abs = quantileSorted(e, 0.95);
        }
        try res.segments.append(gpa, seg);
    }
}

fn quantileSorted(v: []const f64, q: f64) f64 {
    if (v.len == 0) return std.math.nan(f64);
    const pos = q * @as(f64, @floatFromInt(v.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi = @min(lo + 1, v.len - 1);
    const frac = pos - @as(f64, @floatFromInt(lo));
    return v[lo] + (v[hi] - v[lo]) * frac;
}

// ---- Metrics over a set of units, and their bootstrap ----

const SilenceMetrics = struct { false_per_min: f64, events_per_min: f64 };

fn silenceMetrics(units: []const SilenceRun, idx: []const u32) SilenceMetrics {
    var t: f64 = 0;
    var fr: f64 = 0;
    var ev: f64 = 0;
    for (idx) |u| {
        t += units[u].eligible_s;
        fr += @floatFromInt(units[u].false_reads);
        ev += @floatFromInt(units[u].events);
    }
    const min = t / 60;
    return .{ .false_per_min = fr / min, .events_per_min = ev / min };
}

const VoicedMetrics = struct { octave: f64, other: f64, strict_octave: f64, strict_other: f64, octave_firm: f64, other_firm: f64 };

fn voicedMetrics(units: []const VoicedRun, idx: []const u32) VoicedMetrics {
    var s: [8]f64 = .{0} ** 8;
    for (idx) |u| {
        const v = units[u];
        s[0] += @floatFromInt(v.shown);
        s[1] += @floatFromInt(v.octave);
        s[2] += @floatFromInt(v.other);
        s[3] += @floatFromInt(v.strict_octave);
        s[4] += @floatFromInt(v.strict_other);
        s[5] += @floatFromInt(v.shown_firm);
        s[6] += @floatFromInt(v.octave_firm);
        s[7] += @floatFromInt(v.other_firm);
    }
    return .{
        .octave = 100 * s[1] / s[0],
        .other = 100 * s[2] / s[0],
        .strict_octave = 100 * s[3] / s[0],
        .strict_other = 100 * s[4] / s[0],
        .octave_firm = 100 * s[6] / s[5],
        .other_firm = 100 * s[7] / s[5],
    };
}

const SegmentMetrics = struct {
    bias: f64,
    median_abs: f64,
    p95_abs: f64,
    bias_inst: f64,
    median_abs_inst: f64,
    p95_abs_inst: f64,
    flat_share: f64,
    bias_flat: f64,
    median_abs_flat: f64,
    p95_abs_flat: f64,
    wrong_after_150ms: f64,
    coverage_any: f64,
    coverage_right: f64,
    ever_shown: f64,
    reached_1c: f64,
    to_1c_median_ms: f64,
    lock_median_ms: f64,
};

/// Buffers for `segmentMetrics`, grown to fit: a bootstrap resample can
/// hold more readings than the segments it was drawn from.
const Scratch = struct {
    gpa: std.mem.Allocator,
    a: []f64 = &.{},
    b: []f64 = &.{},
    c: []f64 = &.{},
    seg: []f64 = &.{},

    fn fit(self: *Scratch, errs: usize, segs: usize) void {
        if (self.a.len < errs) {
            self.gpa.free(self.a);
            self.gpa.free(self.b);
            self.gpa.free(self.c);
            self.a = self.gpa.alloc(f64, errs) catch @panic("out of memory");
            self.b = self.gpa.alloc(f64, errs) catch @panic("out of memory");
            self.c = self.gpa.alloc(f64, errs) catch @panic("out of memory");
        }
        if (self.seg.len < segs) {
            self.gpa.free(self.seg);
            self.seg = self.gpa.alloc(f64, segs) catch @panic("out of memory");
        }
    }

    fn deinit(self: *Scratch) void {
        self.gpa.free(self.a);
        self.gpa.free(self.b);
        self.gpa.free(self.c);
        self.gpa.free(self.seg);
    }
};

fn segmentMetrics(res: *const Results, idx: []const u32, scratch: *Scratch) SegmentMetrics {
    var total: usize = 0;
    for (idx) |u| total += res.segments.items[u].errs_len;
    scratch.fit(total, idx.len);
    var na: usize = 0;
    var nf: usize = 0;
    var sum: f64 = 0;
    var sum_inst: f64 = 0;
    var sum_flat: f64 = 0;
    var s: [6]f64 = .{0} ** 6;
    var ever: f64 = 0;
    for (idx) |u| {
        const seg = res.segments.items[u];
        const at = seg.errs_at;
        const len = seg.errs_len;
        for (res.errs.items[at..][0..len], res.errs_inst.items[at..][0..len], res.errs_flat.items[at..][0..len]) |e, ei, flat| {
            scratch.a[na] = @abs(e);
            scratch.b[na] = @abs(ei);
            sum += e;
            sum_inst += ei;
            na += 1;
            if (flat) {
                scratch.c[nf] = @abs(e);
                sum_flat += e;
                nf += 1;
            }
        }
        s[0] += @floatFromInt(seg.acc_shown);
        s[1] += @floatFromInt(seg.acc_wrong);
        s[2] += @floatFromInt(seg.reads);
        s[3] += @floatFromInt(seg.shown);
        s[4] += @floatFromInt(seg.right);
        if (seg.right > 0) ever += 1;
    }
    const a = scratch.a[0..na];
    const b = scratch.b[0..na];
    std.mem.sort(f64, a, {}, std.sort.asc(f64));
    std.mem.sort(f64, b, {}, std.sort.asc(f64));
    const cf = scratch.c[0..nf];
    std.mem.sort(f64, cf, {}, std.sort.asc(f64));
    var nr: usize = 0;
    for (idx) |u| {
        const v = res.segments.items[u].to_1c_s;
        if (!std.math.isNan(v)) {
            scratch.seg[nr] = v;
            nr += 1;
        }
    }
    std.mem.sort(f64, scratch.seg[0..nr], {}, std.sort.asc(f64));
    const to_1c = quantileSorted(scratch.seg[0..nr], 0.5);
    var nl: usize = 0;
    for (idx) |u| {
        const v = res.segments.items[u].lock_s;
        if (!std.math.isNan(v)) {
            scratch.seg[nl] = v;
            nl += 1;
        }
    }
    std.mem.sort(f64, scratch.seg[0..nl], {}, std.sort.asc(f64));
    const n: f64 = @floatFromInt(idx.len);
    const fna: f64 = @floatFromInt(na);
    return .{
        .bias = sum / fna,
        .median_abs = quantileSorted(a, 0.5),
        .p95_abs = quantileSorted(a, 0.95),
        .bias_inst = sum_inst / fna,
        .median_abs_inst = quantileSorted(b, 0.5),
        .p95_abs_inst = quantileSorted(b, 0.95),
        .flat_share = 100 * @as(f64, @floatFromInt(nf)) / fna,
        .bias_flat = sum_flat / @as(f64, @floatFromInt(nf)),
        .median_abs_flat = quantileSorted(cf, 0.5),
        .p95_abs_flat = quantileSorted(cf, 0.95),
        .wrong_after_150ms = 100 * s[1] / s[0],
        .coverage_any = 100 * s[3] / s[2],
        .coverage_right = 100 * s[4] / s[2],
        .ever_shown = 100 * ever / n,
        .reached_1c = 100 * @as(f64, @floatFromInt(nr)) / n,
        .to_1c_median_ms = 1000 * to_1c,
        .lock_median_ms = 1000 * quantileSorted(scratch.seg[0..nl], 0.5),
    };
}

fn Ci(comptime M: type) type {
    return struct { point: M, lo: M, hi: M };
}

/// Percentile bootstrap over units: `metric(units_ctx, resampled_idx)`.
fn bootstrap(comptime M: type, gpa: std.mem.Allocator, idx: []const u32, ctx: anytype, comptime metric: fn (@TypeOf(ctx), []const u32) M, seed: u64) !Ci(M) {
    const fields = @typeInfo(M).@"struct".fields;
    const point = metric(ctx, idx);
    if (idx.len == 0) return .{ .point = point, .lo = point, .hi = point };
    const draws = try gpa.alloc(u32, idx.len);
    defer gpa.free(draws);
    const samples = try gpa.alloc(M, bootstrap_reps);
    defer gpa.free(samples);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    for (samples) |*m| {
        for (draws) |*d| d.* = idx[rnd.uintLessThan(usize, idx.len)];
        m.* = metric(ctx, draws);
    }
    var lo: M = undefined;
    var hi: M = undefined;
    const col = try gpa.alloc(f64, bootstrap_reps);
    defer gpa.free(col);
    inline for (fields) |fl| {
        var n: usize = 0;
        for (samples) |m| {
            const v = @field(m, fl.name);
            if (!std.math.isNan(v)) {
                col[n] = v;
                n += 1;
            }
        }
        std.mem.sort(f64, col[0..n], {}, std.sort.asc(f64));
        @field(lo, fl.name) = quantileSorted(col[0..n], 0.025);
        @field(hi, fl.name) = quantileSorted(col[0..n], 0.975);
    }
    return .{ .point = point, .lo = lo, .hi = hi };
}

const SegCtx = struct { res: *const Results, scratch: *Scratch };
fn segMetricFn(ctx: SegCtx, idx: []const u32) SegmentMetrics {
    return segmentMetrics(ctx.res, idx, ctx.scratch);
}
fn silMetricFn(units: []const SilenceRun, idx: []const u32) SilenceMetrics {
    return silenceMetrics(units, idx);
}
fn voiMetricFn(units: []const VoicedRun, idx: []const u32) VoicedMetrics {
    return voicedMetrics(units, idx);
}

// ---- Output ----

fn ci(w: *std.Io.Writer, comptime fmt: []const u8, c: anytype, comptime field: []const u8) !void {
    try w.print("{d:" ++ fmt ++ "} [{d:" ++ fmt ++ "}, {d:" ++ fmt ++ "}]", .{ @field(c.point, field), @field(c.lo, field), @field(c.hi, field) });
}

const RangeBin = struct { name: []const u8, lo: f64, hi: f64 };
const range_bins = [_]RangeBin{
    .{ .name = "below E1 (<41.2 Hz)", .lo = 0, .hi = 41.2034 },
    .{ .name = "E1-A1 (41.2-55 Hz)", .lo = 41.2034, .hi = 55.0 },
    .{ .name = "A1-E2 (55-82.4 Hz)", .lo = 55.0, .hi = 82.4069 },
    .{ .name = "above E2 (>82.4 Hz)", .lo = 82.4069, .hi = 1e9 },
};

fn allIdx(gpa: std.mem.Allocator, n: usize) ![]u32 {
    const v = try gpa.alloc(u32, n);
    for (v, 0..) |*x, i| x.* = @intCast(i);
    return v;
}

fn segmentIdx(gpa: std.mem.Allocator, res: *const Results, ctx: anytype, comptime keep: fn (@TypeOf(ctx), Segment) bool) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (res.segments.items, 0..) |s, i| if (keep(ctx, s)) try out.append(gpa, @intCast(i));
    return out.toOwnedSlice(gpa);
}

fn writeSegmentRow(w: *std.Io.Writer, label: []const u8, n: usize, c: Ci(SegmentMetrics)) !void {
    try w.print("| {s} | {d} | ", .{ label, n });
    try ci(w, ".2", c, "bias");
    try w.writeAll(" | ");
    try ci(w, ".2", c, "median_abs");
    try w.writeAll(" | ");
    try ci(w, ".2", c, "p95_abs");
    try w.writeAll(" | ");
    try ci(w, ".1", c, "wrong_after_150ms");
    try w.writeAll(" |\n");
}

fn writeCoverageRow(w: *std.Io.Writer, label: []const u8, n: usize, c: Ci(SegmentMetrics)) !void {
    try w.print("| {s} | {d} | ", .{ label, n });
    try ci(w, ".1", c, "coverage_any");
    try w.writeAll(" | ");
    try ci(w, ".1", c, "coverage_right");
    try w.writeAll(" | ");
    try ci(w, ".1", c, "ever_shown");
    try w.writeAll(" | ");
    try ci(w, ".0", c, "lock_median_ms");
    try w.writeAll(" | ");
    try ci(w, ".1", c, "reached_1c");
    try w.writeAll(" | ");
    try ci(w, ".0", c, "to_1c_median_ms");
    try w.writeAll(" |\n");
}

fn report(gpa: std.mem.Allocator, w: *std.Io.Writer, res: *const Results, title: []const u8, full: bool) !void {
    var minutes: f64 = 0;
    for (res.track_minutes.items) |m| minutes += m;
    try w.print("\n## {s}\n\n{d} tracks, {d:.1} min, {d} readings; {d} silence runs of 200 ms or more, {d} voiced runs, {d} sustained segments.\n", .{
        title, res.tracks.items.len, minutes, res.reads, res.silences.items.len, res.voiced.items.len, res.segments.items.len,
    });

    // Silence level sanity check.
    {
        const v = try gpa.alloc(f64, res.silences.items.len);
        defer gpa.free(v);
        var sounding: usize = 0;
        var eligible: f64 = 0;
        for (res.silences.items, v) |s, *x| {
            x.* = s.peak_db;
            if (s.peak_db > -90) sounding += 1;
            eligible += s.eligible_s;
        }
        std.mem.sort(f64, v, {}, std.sort.asc(f64));
        try w.print("Unvoiced runs: {d:.1} min judged for false notes; peak level 20 ms in from the edges: median {d:.1} dBFS, max {d:.1}; {d} runs peak above -90 dBFS.\n", .{ eligible / 60, quantileSorted(v, 0.5), if (v.len > 0) v[v.len - 1] else 0, sounding });
        try w.print("Shown readings at unvoiced frames near voicing (neither judged false nor pitched): {d}.\n", .{res.edge_reads});
    }

    const sil_idx = try allIdx(gpa, res.silences.items.len);
    defer gpa.free(sil_idx);
    const sil = try bootstrap(SilenceMetrics, gpa, sil_idx, @as([]const SilenceRun, res.silences.items), silMetricFn, 1);
    try w.writeAll("\n### 1. False notes (units: silence runs)\n\n| Measure | Value [95% CI] |\n|---|---|\n| False readings per minute of silence | ");
    try ci(w, ".2", sil, "false_per_min");
    try w.writeAll(" |\n| False-note events per minute | ");
    try ci(w, ".2", sil, "events_per_min");
    try w.print(" |\n| False-note events, total | {d} |\n", .{res.false_events.items.len});

    const voi_idx = try allIdx(gpa, res.voiced.items.len);
    defer gpa.free(voi_idx);
    const voi = try bootstrap(VoicedMetrics, gpa, voi_idx, @as([]const VoicedRun, res.voiced.items), voiMetricFn, 2);
    var shown: u64 = 0;
    for (res.voiced.items) |v| shown += v.shown;
    try w.print("\n### 2. Wrong notes, % of {d} shown readings at voiced frames (units: voiced runs)\n\n| Judged against | Octave (+-12/24/36) | Other |\n|---|---|---|\n| nearest annotated f0 in the reading's 100 ms window | ", .{shown});
    try ci(w, ".2", voi, "octave");
    try w.writeAll(" | ");
    try ci(w, ".2", voi, "other");
    try w.writeAll(" |\n| same, readings not flagged settling | ");
    try ci(w, ".2", voi, "octave_firm");
    try w.writeAll(" | ");
    try ci(w, ".2", voi, "other_firm");
    try w.writeAll(" |\n| annotated f0 at the reading's own frame (strict) | ");
    try ci(w, ".2", voi, "strict_octave");
    try w.writeAll(" | ");
    try ci(w, ".2", voi, "strict_other");
    try w.writeAll(" |\n");
    {
        const v = try gpa.dupe(f64, res.octave_residual.items);
        defer gpa.free(v);
        std.mem.sort(f64, v, {}, std.sort.asc(f64));
        try w.print("\nOctave-error readings' cents against the nearest whole octave of the annotation: median {d:.2} c, P95 {d:.2} c (n = {d}).\n", .{ quantileSorted(v, 0.5), quantileSorted(v, 0.95), v.len });
    }

    var scratch: Scratch = .{ .gpa = gpa };
    defer scratch.deinit();
    const ctx: SegCtx = .{ .res = res, .scratch = &scratch };

    const Group = struct { label: []const u8, idx: []u32 };
    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |g| gpa.free(g.idx);
        groups.deinit(gpa);
    }
    try groups.append(gpa, .{ .label = "all", .idx = try allIdx(gpa, res.segments.items.len) });
    inline for (.{ OnsetKind.clear, OnsetKind.short_gap, OnsetKind.legato }) |kind| {
        try groups.append(gpa, .{ .label = switch (kind) {
            .clear => "after an onset, >=100 ms silence before",
            .short_gap => "after an onset, <100 ms silence before",
            .legato => "legato (reached within a voiced run)",
        }, .idx = try segmentIdx(gpa, res, kind, struct {
            fn keep(k: OnsetKind, s: Segment) bool {
                return s.kind == k;
            }
        }.keep) });
    }
    for (range_bins) |bin| {
        try groups.append(gpa, .{ .label = bin.name, .idx = try segmentIdx(gpa, res, bin, struct {
            fn keep(b: RangeBin, s: Segment) bool {
                return s.median_hz >= b.lo and s.median_hz < b.hi;
            }
        }.keep) });
    }
    const cis = try gpa.alloc(Ci(SegmentMetrics), groups.items.len);
    defer gpa.free(cis);
    for (groups.items, cis, 0..) |g, *c, gi| c.* = try bootstrap(SegmentMetrics, gpa, g.idx, ctx, segMetricFn, 10 + gi);

    try w.writeAll("\n### 3. Cents error on sustained segments, readings from 150 ms after the start with the right note (units: segments)\n\nTruth: mean annotated pitch over the reading's refinement span (from the latest of segment start, last onset, 0.3 s back).\n\n| Segments | n | Bias (mean e) c | Median abs c | P95 abs c | Wrong note after 150 ms % |\n|---|---|---|---|---|---|\n");
    for (groups.items, cis) |g, c| try writeSegmentRow(w, g.label, g.idx.len, c);
    try w.writeAll("\nSame readings against the annotation at the reading's own frame:\n\n| Segments | Bias c | Median abs c | P95 abs c |\n|---|---|---|---|\n");
    for (groups.items, cis) |g, c| {
        try w.print("| {s} | ", .{g.label});
        try ci(w, ".2", c, "bias_inst");
        try w.writeAll(" | ");
        try ci(w, ".2", c, "median_abs_inst");
        try w.writeAll(" | ");
        try ci(w, ".2", c, "p95_abs_inst");
        try w.writeAll(" |\n");
    }
    try w.print("\nFlat readings only (the annotated pitch over the refinement span varies by {d} c or less):\n\n| Segments | Share of readings % | Bias c | Median abs c | P95 abs c |\n|---|---|---|---|---|\n", .{flat_span_cents});
    for (groups.items, cis) |g, c| {
        try w.print("| {s} | ", .{g.label});
        try ci(w, ".1", c, "flat_share");
        try w.writeAll(" | ");
        try ci(w, ".2", c, "bias_flat");
        try w.writeAll(" | ");
        try ci(w, ".2", c, "median_abs_flat");
        try w.writeAll(" | ");
        try ci(w, ".2", c, "p95_abs_flat");
        try w.writeAll(" |\n");
    }
    try writeLagTables(gpa, w, res);
    {
        var offs: std.ArrayList(f64) = .empty;
        defer offs.deinit(gpa);
        for (res.segments.items) |sg| if (sg.kind == .clear) try offs.append(gpa, sg.after_run_start_s);
        std.mem.sort(f64, offs.items, {}, std.sort.asc(f64));
        try w.print("\nTimes below run from the segment's start. Segments after a clear onset start a median {d:.0} ms (P90 {d:.0} ms) after the onset itself.\n", .{ 1000 * quantileSorted(offs.items, 0.5), 1000 * quantileSorted(offs.items, 0.9) });
    }
    try w.writeAll("\n### 4. Coverage and timing (units: segments)\n\n| Segments | n | Time with any note % | Time with right note % | Segments ever shown right % | Median lock ms | Segments reaching +-1 c % | Median time to +-1 c ms |\n|---|---|---|---|---|---|---|---|\n");
    for (groups.items, cis) |g, c| try writeCoverageRow(w, g.label, g.idx.len, c);

    if (!full) return;

    // Per track (point estimates).
    try w.writeAll("\n### 5. Per track (point estimates)\n\n| Track | min | False/min | Octave % | Other % | Segs | Median abs c | P95 abs c | Right-note time % | Ever shown % |\n|---|---|---|---|---|---|---|---|---|---|\n");
    for (res.tracks.items, 0..) |name, ti| {
        const t16: u16 = @intCast(ti);
        var s_idx: std.ArrayList(u32) = .empty;
        defer s_idx.deinit(gpa);
        for (res.silences.items, 0..) |s, i| if (s.track == t16) try s_idx.append(gpa, @intCast(i));
        var v_idx: std.ArrayList(u32) = .empty;
        defer v_idx.deinit(gpa);
        for (res.voiced.items, 0..) |v, i| if (v.track == t16) try v_idx.append(gpa, @intCast(i));
        var g_idx: std.ArrayList(u32) = .empty;
        defer g_idx.deinit(gpa);
        for (res.segments.items, 0..) |s, i| if (s.track == t16) try g_idx.append(gpa, @intCast(i));
        const sm = silenceMetrics(res.silences.items, s_idx.items);
        const vm = voicedMetrics(res.voiced.items, v_idx.items);
        const gm = segmentMetrics(res, g_idx.items, &scratch);
        try w.print("| {s} | {d:.1} | {d:.2} | {d:.2} | {d:.2} | {d} | {d:.2} | {d:.2} | {d:.1} | {d:.1} |\n", .{
            name, res.track_minutes.items[ti], sm.false_per_min, vm.octave, vm.other, g_idx.items.len, gm.median_abs, gm.p95_abs, gm.coverage_right, gm.ever_shown,
        });
    }
}

/// Point estimates over every accuracy reading: the error by how much the
/// annotated pitch moves over the reading's span, and against shorter
/// truth spans.
fn writeLagTables(gpa: std.mem.Allocator, w: *std.Io.Writer, res: *const Results) !void {
    const n = res.errs.items.len;
    const v = try gpa.alloc(f64, n);
    defer gpa.free(v);
    try w.writeAll("\nError by how far the annotated pitch moves over the reading's span (all segments, point estimates):\n\n| Movement c | Readings | Median abs c | P95 abs c |\n|---|---|---|---|\n");
    var lo: f64 = 0;
    for (movement_bins) |hi| {
        var k: usize = 0;
        for (res.errs.items, res.errs_movement.items) |e, m| if (m >= lo and m < hi) {
            v[k] = @abs(e);
            k += 1;
        };
        std.mem.sort(f64, v[0..k], {}, std.sort.asc(f64));
        try w.print("| {d}-{d} | {d} | {d:.2} | {d:.2} |\n", .{ lo, hi, k, quantileSorted(v[0..k], 0.5), quantileSorted(v[0..k], 0.95) });
        lo = hi;
    }
    try w.writeAll("\nThe same readings against the mean pitch over shorter spans (each from the latest of segment start, last onset and the span back; point estimates):\n\n| Truth span s | Median abs c | P95 abs c |\n|---|---|---|\n");
    for (alt_spans_s, res.errs_alt) |len_s, list| {
        @memcpy(v, list.items);
        std.mem.sort(f64, v, {}, std.sort.asc(f64));
        try w.print("| {d} | {d:.2} | {d:.2} |\n", .{ len_s, quantileSorted(v, 0.5), quantileSorted(v, 0.95) });
    }
    for (res.errs.items, v) |e, *x| x.* = @abs(e);
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    try w.print("| {d} (the refinement's) | {d:.2} | {d:.2} |\n", .{ refine_s, quantileSorted(v, 0.5), quantileSorted(v, 0.95) });
}

fn writeFailures(gpa: std.mem.Allocator, w: *std.Io.Writer, res: *const Results) !void {
    try w.writeAll("\n### Longest false-note events\n\n| Track | From s | To s | Note shown (MIDI) | Readings |\n|---|---|---|---|---|\n");
    const fe = res.false_events.items;
    std.mem.sort(FalseEvent, fe, {}, struct {
        fn lt(_: void, a: FalseEvent, b: FalseEvent) bool {
            return a.reads > b.reads;
        }
    }.lt);
    for (fe[0..@min(15, fe.len)]) |e| try w.print("| {s} | {d:.2} | {d:.2} | {d} | {d} |\n", .{ res.tracks.items[e.track], e.t0, e.t1, e.note, e.reads });

    const ne = res.note_errors.items;
    std.mem.sort(NoteErrorEvent, ne, {}, struct {
        fn lt(_: void, a: NoteErrorEvent, b: NoteErrorEvent) bool {
            return a.reads > b.reads;
        }
    }.lt);
    try w.writeAll("\n### Longest wrong-note runs (lag-tolerant)\n\n| Track | From s | To s | Shown (MIDI) | Annotated (MIDI) | Kind | Readings |\n|---|---|---|---|---|---|---|\n");
    for (ne[0..@min(20, ne.len)]) |e| try w.print("| {s} | {d:.2} | {d:.2} | {d} | {d} | {s} | {d} |\n", .{ res.tracks.items[e.track], e.t0, e.t1, e.shown_note, e.true_note, if (e.octave) "octave" else "other", e.reads });
    var hist = [_]u32{0} ** 7;
    for (ne) |e| hist[@min(e.reads, 7) - 1] += 1;
    try w.print("Wrong-note runs by length in readings (1..6, 7+): {any}\n", .{hist});

    try w.writeAll("\n### Clear-onset segments never shown with the right note (first 20 by length)\n\n| Track | Start s | End s | Median Hz | Readings shown |\n|---|---|---|---|---|\n");
    var listed: usize = 0;
    const order = try gpa.alloc(u32, res.segments.items.len);
    defer gpa.free(order);
    var n_order: usize = 0;
    for (res.segments.items, 0..) |s, i| if (s.kind == .clear and s.right == 0) {
        order[n_order] = @intCast(i);
        n_order += 1;
    };
    std.mem.sort(u32, order[0..n_order], res, struct {
        fn lt(r: *const Results, a: u32, b: u32) bool {
            const sa = r.segments.items[a];
            const sb = r.segments.items[b];
            return sa.end_s - sa.start_s > sb.end_s - sb.start_s;
        }
    }.lt);
    for (order[0..n_order]) |i| {
        if (listed == 20) break;
        const s = res.segments.items[i];
        try w.print("| {s} | {d:.2} | {d:.2} | {d:.1} | {d} |\n", .{ res.tracks.items[s.track], s.start_s, s.end_s, s.median_hz, s.shown });
        listed += 1;
    }
    try w.print("({d} such segments in all)\n", .{n_order});

    try w.writeAll("\n### Segments with the largest P95 error (at least 10 readings)\n\n| Track | Start s | End s | Median Hz | Kind | P95 abs c |\n|---|---|---|---|---|---|\n");
    n_order = 0;
    for (res.segments.items, 0..) |s, i| if (s.errs_len >= 10) {
        order[n_order] = @intCast(i);
        n_order += 1;
    };
    std.mem.sort(u32, order[0..n_order], res, struct {
        fn lt(r: *const Results, a: u32, b: u32) bool {
            return r.segments.items[a].p95_abs > r.segments.items[b].p95_abs;
        }
    }.lt);
    for (order[0..@min(15, n_order)]) |i| {
        const s = res.segments.items[i];
        try w.print("| {s} | {d:.2} | {d:.2} | {d:.1} | {s} | {d:.2} |\n", .{ res.tracks.items[s.track], s.start_s, s.end_s, s.median_hz, @tagName(s.kind), s.p95_abs });
    }
}

fn writeCsvs(dir_path: []const u8, res: *const Results) !void {
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    var buf: [65536]u8 = undefined;
    {
        var file = try dir.createFile("segments.csv", .{});
        defer file.close();
        var fw = file.writer(&buf);
        const w = &fw.interface;
        try w.writeAll("track,start_s,end_s,median_hz,kind,reads,shown,right,acc_shown,acc_wrong,acc_reads,p95_abs_cents,lock_ms,to_1c_ms\n");
        for (res.segments.items) |s| try w.print("{s},{d:.3},{d:.3},{d:.3},{s},{d},{d},{d},{d},{d},{d},{d:.3},{d:.0},{d:.0}\n", .{
            res.tracks.items[s.track], s.start_s, s.end_s, s.median_hz, @tagName(s.kind), s.reads, s.shown, s.right, s.acc_shown, s.acc_wrong, s.errs_len, s.p95_abs, s.lock_s * 1000, s.to_1c_s * 1000,
        });
        try w.flush();
    }
    {
        var file = try dir.createFile("false_events.csv", .{});
        defer file.close();
        var fw = file.writer(&buf);
        const w = &fw.interface;
        try w.writeAll("track,from_s,to_s,note,readings\n");
        for (res.false_events.items) |e| try w.print("{s},{d:.3},{d:.3},{d},{d}\n", .{ res.tracks.items[e.track], e.t0, e.t1, e.note, e.reads });
        try w.flush();
    }
    {
        var file = try dir.createFile("note_errors.csv", .{});
        defer file.close();
        var fw = file.writer(&buf);
        const w = &fw.interface;
        try w.writeAll("track,from_s,to_s,shown_note,annotated_note,kind,readings\n");
        for (res.note_errors.items) |e| try w.print("{s},{d:.3},{d:.3},{d},{d},{s},{d}\n", .{ res.tracks.items[e.track], e.t0, e.t1, e.shown_note, e.true_note, if (e.octave) "octave" else "other", e.reads });
        try w.flush();
    }
}

const Track = struct { name: []const u8, audio: []const u8, annotation: []const u8 };

fn evaluate(gpa: std.mem.Allocator, res: *Results, tracks: []const Track, settings: pitch.Settings) !void {
    for (tracks, 0..) |tr, ti| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const bytes = try std.fs.cwd().readFileAlloc(arena, tr.audio, 1 << 31);
        const wav = try wav_mod.parse(bytes);
        const rate: f64 = @floatFromInt(wav.sample_rate);
        const mono = try arena.alloc(f32, wav.frames());
        for (mono, 0..) |*m, f| m.* = wav.mono(f, null);
        const annot = try parseAnnotation(arena, try std.fs.cwd().readFileAlloc(arena, tr.annotation, 1 << 28));
        const reads = try runAnalyser(arena, mono, rate, settings);
        try res.tracks.append(gpa, tr.name);
        try res.track_minutes.append(gpa, @as(f64, @floatFromInt(mono.len)) / rate / 60);
        try scoreTrack(gpa, res, @intCast(ti), annot, mono, rate, reads);
        std.debug.print("\r{d}/{d} {s}                    ", .{ ti + 1, tracks.len, tr.name });
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa_state.allocator());
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    var root: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var mixes: usize = 0;
    var settings: pitch.Settings = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--out") and has) {
            out_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--tracks") and has) {
            filter = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--mix") and has) {
            mixes = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--range") and i + 2 < args.len) {
            settings.range = .{ .low_hz = try std.fmt.parseFloat(f64, args[i + 1]), .high_hz = try std.fmt.parseFloat(f64, args[i + 2]) };
            i += 2;
        } else if (root == null and !std.mem.startsWith(u8, a, "--")) {
            root = a;
        } else {
            std.debug.print(usage_text, .{});
            return error.BadArguments;
        }
    }
    const dir_path = root orelse std.process.getEnvVarOwned(gpa, "MDB_BASS_SYNTH") catch {
        std.debug.print(usage_text, .{});
        return error.NoDataset;
    };

    // Stems and their annotations, in name order.
    var stems: std.ArrayList(Track) = .empty;
    {
        const bass_dir = try std.fs.path.join(gpa, &.{ dir_path, "audio_bass" });
        var dir = try std.fs.cwd().openDir(bass_dir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (!std.mem.endsWith(u8, e.name, ".RESYN.wav")) continue;
            if (filter) |f| if (std.mem.indexOf(u8, e.name, f) == null) continue;
            const base = e.name[0 .. e.name.len - ".RESYN.wav".len];
            try stems.append(gpa, .{
                .name = try gpa.dupe(u8, base),
                .audio = try std.fs.path.join(gpa, &.{ bass_dir, e.name }),
                .annotation = try std.fs.path.join(gpa, &.{ dir_path, "annotation_bass", try std.fmt.allocPrint(gpa, "{s}.RESYN.csv", .{base}) }),
            });
        }
    }
    std.mem.sort(Track, stems.items, {}, struct {
        fn lt(_: void, a: Track, b: Track) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var obuf: [16384]u8 = undefined;
    var ow = std.fs.File.stdout().writer(&obuf);
    const w = &ow.interface;
    try w.print("# MDB-bass-synth held-out run\n\nSettings: reference {d} Hz, silence {d} dBFS, range ", .{ settings.reference_hz, settings.silence_db });
    if (settings.range) |r| try w.print("{d}-{d} Hz", .{ r.low_hz, r.high_hz }) else try w.writeAll("none (chromatic)");
    try w.print("; 256-sample pushes, analyse at 30 Hz; bootstrap {d} resamples.\n", .{bootstrap_reps});
    try w.flush();

    var res: Results = .{};
    try evaluate(gpa, &res, stems.items, settings);
    try report(gpa, w, &res, "Bass stems", true);
    try writeFailures(gpa, w, &res);
    try w.flush();
    if (out_dir) |d| try writeCsvs(d, &res);

    if (mixes > 0) {
        // Exploratory: the first N mixes, scored against the bass annotation.
        var mix_tracks: std.ArrayList(Track) = .empty;
        for (stems.items[0..@min(mixes, stems.items.len)]) |s| {
            const cut = std.mem.indexOf(u8, s.name, "_STEM_") orelse continue;
            try mix_tracks.append(gpa, .{
                .name = s.name,
                .audio = try std.fs.path.join(gpa, &.{ dir_path, "audio_mix", try std.fmt.allocPrint(gpa, "{s}_MIX_basssynth.wav", .{s.name[0..cut]}) }),
                .annotation = s.annotation,
            });
        }
        var mres: Results = .{};
        try evaluate(gpa, &mres, mix_tracks.items, settings);
        try report(gpa, w, &mres, "EXPLORATORY: full mixes (stereo mean) against the bass annotation", false);
        try w.flush();
    }
}

test "judge splits right notes, octaves and other intervals by cents" {
    try std.testing.expectEqual(Judgement.right, judge(49.9));
    try std.testing.expectEqual(Judgement.right, judge(-50));
    try std.testing.expectEqual(Judgement.other, judge(51));
    try std.testing.expectEqual(Judgement.other, judge(700));
    try std.testing.expectEqual(Judgement.octave, judge(1180));
    try std.testing.expectEqual(Judgement.octave, judge(-1220));
    try std.testing.expectEqual(Judgement.octave, judge(2400));
    try std.testing.expectEqual(Judgement.other, judge(1900));
}

test "findSegments keeps stretches within the band and drops a glide's frames" {
    const nan = std.math.nan(f64);
    // A glide of 10 frames rising 30 c each, then 30 steady frames, a gap,
    // then 5 steady frames (too short).
    var c: [10 + 30 + 1 + 5]f64 = undefined;
    for (0..10) |k| c[k] = 4000 + 30 * @as(f64, @floatFromInt(k));
    for (10..40) |k| c[k] = 4300;
    c[40] = nan;
    for (41..46) |k| c[k] = 4300;
    const segs = try findSegments(std.testing.allocator, &c, 40, 20);
    defer std.testing.allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    // Of the glide only its last frame (4270) is within 40 c of 4300.
    try std.testing.expectEqual(@as(usize, 9), segs[0].lo);
    try std.testing.expectEqual(@as(usize, 40), segs[0].hi);
}

test "findSegments splits a long note that drifts out of the band without overlap" {
    var c: [60]f64 = undefined;
    for (0..30) |k| c[k] = 5000;
    for (30..60) |k| c[k] = 5100;
    const segs = try findSegments(std.testing.allocator, &c, 40, 20);
    defer std.testing.allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqual(@as(usize, 30), segs[0].hi);
    try std.testing.expectEqual(@as(usize, 30), segs[1].lo);
    try std.testing.expectEqual(@as(usize, 60), segs[1].hi);
}

test "quantileSorted interpolates between ranks" {
    const v = [_]f64{ 0, 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(f64, 2), quantileSorted(&v, 0.5));
    try std.testing.expectApproxEqAbs(@as(f64, 3.8), quantileSorted(&v, 0.95), 1e-12);
}
