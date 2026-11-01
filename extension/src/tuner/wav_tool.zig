//! Runs the tuner's analyser over a WAV recording, as the tuner would hear
//! it, and scores it against each note's offline ground truth:
//!
//!     zig build tuner-wav -Doptimize=ReleaseFast -- take.wav [options]
//!
//! (relative paths are from extension/, where zig build runs it.)
//!
//!     --out FILE        per-reading CSV (default: take.frames.csv)
//!     --notes FILE      per-note CSV (default: take.notes.csv)
//!     --channel N       read channel N (from 0); default the mean of all
//!     --reference HZ    A4 (default 440)
//!     --silence DB      the absolute silence threshold (default -90)
//!
//! Readings come every sample_rate / 30 samples, input pushed in 256-sample
//! blocks. A note is a run of readings with one note name, from the onset
//! the analyser detected for it. For each note at least 1.2 s long the
//! ground truth (truth.zig) is fitted over its whole sustain, from 0.1 s
//! after the onset to its last reading, and the readings are scored as the
//! targets bench scores synthetic strings: the error against the fitted
//! first partial at each reading's time, from 1 s on (its 95th percentile
//! and standard deviation), against the settled first partial nu_inf, the
//! time until every reading stays within 1 cent of nu_inf, the first
//! reading flagged stable, the time until the note name is right, and
//! octave errors. The analyser treats the start of the file as something
//! already sounding, not an onset: start recording before the first pluck.
const std = @import("std");
const pitch = @import("pitch.zig");
const wav_mod = @import("wav.zig");
const truth = @import("truth.zig");
const first_partial = @import("first_partial.zig");

/// The longest period the ground truth measures: 25 Hz at 384 kHz.
const max_period = 16384;
const max_reads = 1 << 20;

const Read = struct {
    t: f64,
    r: pitch.Reading,
    /// Input sample of the analyser's last onset at this reading.
    onset: u64,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);

    var input: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var notes_path: ?[]const u8 = null;
    var channel: ?usize = null;
    var settings: pitch.Settings = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--out")) {
            out_path = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--notes")) {
            notes_path = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--channel")) {
            channel = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--reference")) {
            settings.reference_hz = try std.fmt.parseFloat(f64, next);
            i += 1;
        } else if (std.mem.eql(u8, a, "--silence")) {
            settings.silence_db = try std.fmt.parseFloat(f64, next);
            i += 1;
        } else if (input == null) {
            input = a;
        } else return usage();
    }
    const path = input orelse return usage();
    const stem = if (std.mem.endsWith(u8, path, ".wav")) path[0 .. path.len - 4] else path;
    const frames_csv = out_path orelse try std.fmt.allocPrint(arena, "{s}.frames.csv", .{stem});
    const notes_csv = notes_path orelse try std.fmt.allocPrint(arena, "{s}.notes.csv", .{stem});

    const bytes = try std.fs.cwd().readFileAlloc(arena, path, 1 << 31);
    const wav = wav_mod.parse(bytes) catch |e| {
        std.debug.print("{s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    if (channel) |c| if (c >= wav.channels) {
        std.debug.print("{s} has {d} channels\n", .{ path, wav.channels });
        return error.NoSuchChannel;
    };
    const rate: f64 = @floatFromInt(wav.sample_rate);
    const n = wav.frames();
    const mono = try arena.alloc(f32, n);
    const mono64 = try arena.alloc(f64, n);
    for (mono, mono64, 0..) |*m, *m64, f| {
        m.* = wav.mono(f, channel);
        m64.* = m.*;
    }

    const a = try arena.create(pitch.Analyser);
    try a.init(rate);
    const reads = try arena.alloc(Read, max_reads);
    var nr: usize = 0;
    const tick: usize = @intFromFloat(@round(rate / 30));
    var pos: usize = 0;
    var next_tick = tick;
    while (pos < n and nr < reads.len) {
        const end = @min(n, pos + 256, next_tick);
        a.push(mono[pos..end]);
        pos = end;
        if (pos == next_tick) {
            const onset_input: u64 = a.lastOnset() orelse 0;
            reads[nr] = .{ .t = @as(f64, @floatFromInt(pos)) / rate, .r = a.analyse(settings), .onset = onset_input };
            nr += 1;
            next_tick += tick;
        }
    }
    const rs = reads[0..nr];

    var frames_file = try std.fs.cwd().createFile(frames_csv, .{});
    defer frames_file.close();
    var fbuf: [65536]u8 = undefined;
    var fw = frames_file.writer(&fbuf);
    const w = &fw.interface;
    try w.print("time_s,note,name,cents,freq_hz,clarity,settling,stable,multiple\n", .{});
    for (rs) |rd| {
        if (rd.r.freq_hz > 0) {
            try w.print("{d:.4},{d},{s},{d:.3},{d:.5},{d:.3},{d},{d},{d}\n", .{ rd.t, rd.r.note, noteName(rd.r.note), rd.r.cents, rd.r.freq_hz, rd.r.clarity, @intFromBool(rd.r.settling), @intFromBool(rd.r.stable), @intFromBool(rd.r.multiple) });
        } else {
            try w.print("{d:.4},,,,,,,,{d}\n", .{ rd.t, @intFromBool(rd.r.multiple) });
        }
    }
    try w.flush();

    var notes_file = try std.fs.cwd().createFile(notes_csv, .{});
    defer notes_file.close();
    var nbuf: [16384]u8 = undefined;
    var nw = notes_file.writer(&nbuf);
    const out = &nw.interface;
    try out.print("onset_s,end_s,name,truth_hz,truth_cents,glide_start_cents,glide_tau_s,fit_rms_cents,p95_err_cents,mean_err_cents,jitter_cents,p95_err_vs_settled_cents,to_within_1c_ms,first_stable_ms,lock_ms,octave_reads,reads_after_1s\n", .{});
    std.debug.print("{s}: {d} Hz, {d} channel(s), {d:.1} s, {d} readings -> {s}\n", .{ path, wav.sample_rate, wav.channels, @as(f64, @floatFromInt(n)) / rate, nr, frames_csv });
    std.debug.print("{s:>8} {s:>5} {s:>12} {s:>9} {s:>7} {s:>7} {s:>8} {s:>8} {s:>9} {s:>8}\n", .{ "onset s", "note", "truth Hz", "cents", "glide c", "p95 c", "jitter c", "to 1c ms", "stable ms", "lock ms" });

    const work = try arena.create(first_partial.Work(max_period));
    const points = try arena.alloc(truth.Point, 4096);
    const errs = try arena.alloc(f64, max_reads);
    var k: usize = 0;
    var notes: usize = 0;
    while (k < rs.len) {
        if (rs[k].r.freq_hz <= 0) {
            k += 1;
            continue;
        }
        // The run of readings with this note name, a one-reading gap allowed.
        const name = rs[k].r.note;
        var end = k;
        var j = k + 1;
        while (j < rs.len) : (j += 1) {
            if (rs[j].r.freq_hz > 0 and rs[j].r.note == name) end = j else if (!(j + 1 < rs.len and rs[j + 1].r.freq_hz > 0 and rs[j + 1].r.note == name)) break;
        }
        defer k = end + 1;
        const onset_s = @as(f64, @floatFromInt(rs[k].onset)) / rate;
        const end_s = rs[end].t;
        if (end_s - onset_s < 1.2) continue;

        var guesses: [64]f64 = undefined;
        var g: usize = 0;
        for (rs[k .. end + 1]) |rd| {
            if (rd.r.freq_hz > 0 and g < guesses.len) {
                guesses[g] = rd.r.freq_hz;
                g += 1;
            }
        }
        std.mem.sort(f64, guesses[0..g], {}, std.sort.asc(f64));
        const start: usize = @intCast(@min(rs[k].onset, n));
        const got = truth.track(max_period, work, mono64[start..], rate, guesses[g / 2], 0.1, end_s - onset_s, 0.2, 0.05, points);
        const fit = truth.fitGlide(got) orelse continue;
        notes += 1;

        var m: usize = 0;
        var sum: f64 = 0;
        var sum2: f64 = 0;
        var settled_errs: [4096]f64 = undefined;
        var ms: usize = 0;
        var octave: usize = 0;
        var within: ?f64 = null;
        var stable: ?f64 = null;
        var lock: ?f64 = null;
        const truth_note = noteOf(fit.nu_inf_hz, settings.reference_hz);
        for (rs[k .. end + 1]) |rd| {
            const t = rd.t - onset_s;
            const shown = rd.r.freq_hz > 0;
            if (shown) {
                const d = @abs(rd.r.note - truth_note);
                if ((d >= 11 and d <= 13) or (d >= 23 and d <= 25)) octave += 1;
                if (stable == null and rd.r.stable) stable = t;
            }
            const right_note = shown and rd.r.note == truth_note;
            if (right_note) {
                if (lock == null) lock = t;
            } else lock = null;
            const close = shown and !rd.r.settling and @abs(cents(rd.r.freq_hz, fit.nu_inf_hz)) <= 1;
            if (close) {
                if (within == null) within = t;
            } else within = null;
            if (t < 1 or !shown or rd.r.settling) continue;
            const e = cents(rd.r.freq_hz, fit.at(t));
            errs[m] = @abs(e);
            m += 1;
            sum += e;
            sum2 += e * e;
            if (ms < settled_errs.len) {
                settled_errs[ms] = @abs(cents(rd.r.freq_hz, fit.nu_inf_hz));
                ms += 1;
            }
        }
        const mf: f64 = @floatFromInt(@max(m, 1));
        const mean = sum / mf;
        const jitter = @sqrt(@max(0, sum2 / mf - mean * mean));
        const p95 = percentile(errs[0..m]);
        const p95s = percentile(settled_errs[0..ms]);
        const truth_cents = 100 * (69 + 12 * @log2(fit.nu_inf_hz / settings.reference_hz) - @as(f64, @floatFromInt(truth_note)));
        try out.print("{d:.3},{d:.3},{s},{d:.5},{d:.3},{d:.2},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{s},{s},{s},{d},{d}\n", .{
            onset_s,      end_s,         noteName(truth_note), fit.nu_inf_hz,  truth_cents, fit.start_cents, fit.tau_s, fit.rms_cents, p95, mean, jitter, p95s,
            msOrBlank(within), msOrBlank(stable), msOrBlank(lock), octave,
            m,
        });
        std.debug.print("{d:>8.2} {s:>5} {d:>12.4} {d:>9.2} {d:>7.2} {d:>7.3} {d:>8.3} {d:>8.0} {d:>9.0} {d:>8.0}\n", .{
            onset_s, noteName(truth_note), fit.nu_inf_hz, truth_cents, fit.start_cents, p95, jitter, ms_of(within), ms_of(stable), ms_of(lock),
        });
    }
    try out.flush();
    std.debug.print("{d} notes of 1.2 s or more -> {s}\n", .{ notes, notes_csv });
}

fn usage() error{Usage} {
    std.debug.print("usage: tuner-wav take.wav [--out frames.csv] [--notes notes.csv] [--channel N] [--reference HZ] [--silence DB]\n", .{});
    return error.Usage;
}

fn cents(hz: f64, ref: f64) f64 {
    return 1200 * @log2(hz / ref);
}

fn noteOf(hz: f64, reference_hz: f64) i32 {
    return @intFromFloat(@floor(69 + 12 * @log2(hz / reference_hz) + 0.5));
}

fn ms_of(t: ?f64) f64 {
    return if (t) |v| v * 1000 else std.math.nan(f64);
}

var ms_buf: [3][32]u8 = undefined;
var ms_next: usize = 0;

/// Milliseconds for the CSV, blank for never.
fn msOrBlank(t: ?f64) []const u8 {
    const v = t orelse return "";
    const b = &ms_buf[ms_next % ms_buf.len];
    ms_next += 1;
    return std.fmt.bufPrint(b, "{d:.0}", .{v * 1000}) catch "";
}

fn percentile(values: []f64) f64 {
    if (values.len == 0) return std.math.nan(f64);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const idx: usize = @intFromFloat(@ceil(0.95 * @as(f64, @floatFromInt(values.len))) - 1);
    return values[@min(idx, values.len - 1)];
}

const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
var name_buf: [8][8]u8 = undefined;
var name_next: usize = 0;

/// "E2" for MIDI note 40.
fn noteName(note: i32) []const u8 {
    const b = &name_buf[name_next % name_buf.len];
    name_next += 1;
    const pc: usize = @intCast(@mod(note, 12));
    const oct = @divFloor(note, 12) - 1;
    return std.fmt.bufPrint(b, "{s}{d}", .{ names[pc], oct }) catch "?";
}
