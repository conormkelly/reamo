//! Runs the tuner's analyser over a WAV recording, as the tuner would hear
//! it, and scores it against each note's ground truth (take.zig):
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
//! A note is the readings from one onset to the next, judged if it lasts
//! 1.2 s. Its truth is measured from the recording alone, never from the
//! analyser's readings; hum learned before the onset is taken out first,
//! so leave a second or two before each pluck. A note whose pitch drifts
//! (a slipping peg) is reported as drifting, with its rate. The analyser
//! takes the start of the file for something already sounding, not an
//! onset: start recording before the first pluck.
const std = @import("std");
const pitch = @import("pitch.zig");
const wav_mod = @import("wav.zig");
const take = @import("take.zig");

const max_reads = 1 << 20;

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

    const analyser = try arena.create(pitch.Analyser);
    const reads = try take.readTake(analyser, mono, rate, settings, try arena.alloc(take.Read, max_reads));
    try writeFrames(frames_csv, reads);
    std.debug.print("{s}: {d} Hz, {d} channel(s), {d:.1} s, {d} readings -> {s}\n", .{ path, wav.sample_rate, wav.channels, @as(f64, @floatFromInt(n)) / rate, reads.len, frames_csv });

    const work = try arena.create(take.Work);
    work.init();
    const notes = try take.judgeNotes(arena, work, reads, mono64, rate, settings);
    try writeNotes(notes_csv, notes);
    std.debug.print("{s:>8} {s:>5} {s:>12} {s:>7} {s:>8} {s:>7} {s:>8} {s:>8} {s:>9} {s:>8} {s:>6}\n", .{ "onset s", "note", "truth Hz", "cents", "drift", "p95 c", "jitter c", "to 1c ms", "stable ms", "lock ms", "octave" });
    for (notes) |nt| {
        std.debug.print("{d:>8.2} {s:>5} {d:>12.4} {d:>7.2} {s:>8} {d:>7.3} {d:>8.3} {d:>8.0} {d:>9.0} {d:>8.0} {d:>6}\n", .{
            nt.onset_s,                      noteName(nt.truth_note), nt.truth.hz,           nt.truth_cents, if (nt.truth.drifting) "drifting" else "", nt.p95_err_cents,
            nt.jitter_cents,                 ms(nt.to_within_1c_s),   ms(nt.first_stable_s), ms(nt.lock_s),  nt.octave_reads,
        });
    }
    std.debug.print("{d} notes of {d} s or more -> {s}\n", .{ notes.len, take.min_note_s, notes_csv });
}

fn writeFrames(path: []const u8, reads: []const take.Read) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [65536]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;
    try w.print("time_s,note,name,cents,freq_hz,clarity,settling,stable,multiple,onset_sample\n", .{});
    for (reads) |rd| {
        if (rd.r.freq_hz > 0) {
            try w.print("{d:.4},{d},{s},{d:.3},{d:.5},{d:.3},{d},{d},{d},", .{ rd.t, rd.r.note, noteName(rd.r.note), rd.r.cents, rd.r.freq_hz, rd.r.clarity, @intFromBool(rd.r.settling), @intFromBool(rd.r.stable), @intFromBool(rd.r.multiple) });
        } else {
            try w.print("{d:.4},,,,,,,,{d},", .{ rd.t, @intFromBool(rd.r.multiple) });
        }
        if (rd.onset) |o| try w.print("{d}\n", .{o}) else try w.print("\n", .{});
    }
    try w.flush();
}

fn writeNotes(path: []const u8, notes: []const take.Note) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [16384]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;
    try w.print("onset_s,end_s,name,truth_hz,truth_cents,drifting,drift_cents_per_s,glide_start_cents,glide_tau_s,hum_removed,p95_err_cents,mean_err_cents,jitter_cents,p95_err_vs_settled_cents,to_within_1c_ms,first_stable_ms,lock_ms,octave_reads,reads_after_1s\n", .{});
    for (notes) |nt| {
        const g = nt.truth.glide;
        try w.print("{d:.3},{d:.3},{s},{d:.5},{d:.3},{d},{d:.3},", .{ nt.onset_s, nt.end_s, noteName(nt.truth_note), nt.truth.hz, nt.truth_cents, @intFromBool(nt.truth.drifting), nt.truth.drift_cents_per_s });
        if (g) |v| try w.print("{d:.2},{d:.3},", .{ v.start_cents, v.tau_s }) else try w.print(",,", .{});
        try w.print("{d},{d:.3},{d:.3},{d:.3},{d:.3},", .{ @intFromBool(nt.hum_removed), nt.p95_err_cents, nt.mean_err_cents, nt.jitter_cents, nt.p95_err_vs_settled_cents });
        for ([_]?f64{ nt.to_within_1c_s, nt.first_stable_s, nt.lock_s }) |v| {
            if (v) |s| try w.print("{d:.0},", .{s * 1000}) else try w.print(",", .{});
        }
        try w.print("{d},{d}\n", .{ nt.octave_reads, nt.reads_after_1s });
    }
    try w.flush();
}

fn usage() error{Usage} {
    std.debug.print("usage: tuner-wav take.wav [--out frames.csv] [--notes notes.csv] [--channel N] [--reference HZ] [--silence DB]\n", .{});
    return error.Usage;
}

fn ms(t: ?f64) f64 {
    return if (t) |v| v * 1000 else std.math.nan(f64);
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
