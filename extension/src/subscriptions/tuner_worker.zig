//! One tuner's analysis thread: REAmo's pitch analyser (tuner/pitch.zig)
//! reading one of the audio hook's mono rings, for whichever source fills
//! it: the master tuner's post-master output (master_tuner.zig), or a track
//! tuner's hardware input (input_tuners.zig).
//!
//! Three threads:
//! - the audio thread only copies samples into the ring;
//! - the worker thread, running while the tuner is open, drains the ring
//!   into the analyser and analyses at 30 Hz (`Analysis.tick`), once however
//!   many phones share the tuner, and publishes the reading;
//! - the main thread's 30 Hz subscription poll sends the latest reading to
//!   each phone, and takes the phones' settings to the worker.
//!
//! The analysis is off the main thread because that is REAPER's UI thread:
//! on the worker the UI pays nothing for the analysis, whatever a tick
//! costs, however many sources are tuned. A tick (1/30 s of samples pushed,
//! one reading) is timed by the analyser's targets bench, `make
//! tuner-targets`, under "Per-tick cost". The reading and settings cross
//! under a lock held only to copy them.
//!
//! A note shows no name, and so no pitch, until the analyser's window is
//! wholly past its onset: about 0.1 s after a pluck, the first tick past
//! the 93 ms window. Meanwhile the reading says `starting`, which tells a
//! note on its way from silence. The analyser shows a note only from an
//! onset: a string already ringing when the tuner opens shows once it is
//! plucked again.
const std = @import("std");
const logging = @import("../core/logging.zig");
const pitch = @import("../tuner/pitch.zig");
const audio_hook = @import("../audio/audio_hook.zig");
const mono_ring = @import("../audio/mono_ring.zig");
const no_alloc = @import("../core/no_alloc.zig");

const Allocator = std.mem.Allocator;

/// The tuner's A4 range, as the phone's settings offer it.
pub const reference_min_hz = 400.0;
pub const reference_max_hz = 480.0;
/// The silence threshold's range, as the phone's slider offers it. The
/// analyser's default, the lowest, leaves the gating to its learned noise
/// floor.
pub const silence_min_db = -90.0;
pub const silence_max_db = -30.0;

/// The analysis rate: the tuner's 30 Hz, the rate the phones are sent
/// readings at.
const default_tick_ns: u64 = std.time.ns_per_s / 30;

/// Ticks without a sample before the reading clears and the analyser
/// forgets: half a second at 30 Hz, longer than any audio block (8192
/// samples at 22.05 kHz is 0.37 s). The device has stopped, or REAPER has
/// closed it.
pub const quiet_ticks_limit = 15;

/// Samples drained per push.
const chunk_len = 1024;

/// The analyser and what it needs between ticks. Owned by the worker thread
/// while the tuner is open.
pub const Analysis = struct {
    analyser: pitch.Analyser,
    /// The rate the analyser was set up for: 0 before the hook has
    /// reported one, or while the rate is one the analyser can't take.
    rate: f64 = 0,
    /// The ring's rate as last seen, supported or not.
    seen_rate: f64 = 0,
    reading: pitch.Reading = .none,
    quiet_ticks: u32 = 0,
    chunk: [chunk_len]f32 = undefined,

    /// Allocated once, when the tuner opens: the analyser is about 600 KB.
    pub fn create(allocator: Allocator) Allocator.Error!*Analysis {
        const self = try allocator.create(Analysis);
        self.* = .{ .analyser = undefined };
        return self;
    }

    /// Drain what the hook has written under `tag`, analyse it, and return
    /// the reading to show. The ring's one consumer. Allocates nothing.
    pub fn tick(self: *Analysis, ring: *mono_ring.MonoRing, tag: u32, settings: pitch.Settings) pitch.Reading {
        const ring_rate = ring.sampleRate();
        if (ring_rate != self.seen_rate) {
            // A new device rate (or the first): set up for it, and drop
            // what came before, which may be at the old rate.
            self.seen_rate = ring_rate;
            ring.discard();
            self.reading = .none;
            self.quiet_ticks = 0;
            self.rate = 0;
            if (ring_rate > 0) {
                if (self.analyser.init(ring_rate)) {
                    self.rate = ring_rate;
                } else |_| {
                    logging.warn("tuner: can't analyse audio at {d} Hz", .{ring_rate});
                }
            }
            return self.reading;
        }
        if (self.rate == 0) {
            ring.discard();
            return self.reading;
        }

        var got: usize = 0;
        while (got < mono_ring.capacity) {
            const r = ring.readTagged(&self.chunk, tag);
            if (r.n == 0) break;
            self.analyser.push(self.chunk[0..r.n]);
            got += r.n;
        }
        if (got == 0) {
            self.quiet_ticks +|= 1;
            if (self.quiet_ticks == quiet_ticks_limit) {
                self.analyser.reset();
                self.reading = .none;
            }
            if (self.quiet_ticks >= quiet_ticks_limit) return self.reading;
        } else {
            self.quiet_ticks = 0;
        }
        self.reading = self.analyser.analyse(settings);
        return self.reading;
    }
};

pub const StartError = error{ OutOfMemory, ThreadFailed };

/// What a worker reads.
pub const Source = struct {
    ring: *mono_ring.MonoRing,
    /// The tag the ring's samples are written under (0 for a ring that
    /// never changes hands).
    tag: u32 = 0,
    /// For the master tuner: the hook whose outputs fill the ring, watched
    /// for a device that gives none (`outputs_reported`).
    outputs: ?*const audio_hook.Hook = null,
};

/// What the worker has found wrong with the device's outputs since it
/// started, each logged once. Only a worker watching outputs reports.
pub const OutputsReport = enum(u8) {
    ok,
    /// A mono device: the master tuner reads output 1 alone.
    only_output_1,
    /// No output 1: the master tuner hears nothing.
    none_from_device,
};

pub const Worker = struct {
    /// Null while the worker isn't running.
    analysis: ?*Analysis = null,
    thread: ?std.Thread = null,
    stop_event: std.Thread.ResetEvent = .{},
    /// Time between the worker's ticks. Tests lengthen it.
    tick_ns: u64 = default_tick_ns,
    /// What crosses between the main thread and the worker.
    lock: std.Thread.Mutex = .{},
    /// The phones' settings; written on the main thread, under `lock`.
    settings: pitch.Settings = .{},
    /// The latest reading; written by the worker, under `lock`.
    reading: pitch.Reading = .none,
    /// When the worker last published, on the monotonic clock (null before
    /// its first tick, or with no clock); written by the worker, under `lock`.
    published: ?std.time.Instant = null,
    /// Written by the worker, read by anyone.
    outputs_reported: std.atomic.Value(OutputsReport) = std.atomic.Value(OutputsReport).init(.ok),

    pub const Snapshot = struct {
        reading: pitch.Reading,
        settings: pitch.Settings,
        /// When the reading was published (Worker.published).
        published: ?std.time.Instant = null,

        /// Whether the worker published this reading more than `limit_ns`
        /// before `now`: its thread has stopped ticking. False if either
        /// time is unknown.
        pub fn olderThan(self: Snapshot, now: ?std.time.Instant, limit_ns: u64) bool {
            const at = self.published orelse return false;
            const n = now orelse return false;
            return n.order(at) == .gt and n.since(at) > limit_ns;
        }
    };

    /// Allocate the analyser and start the thread reading `source`, from
    /// `settings` and no reading. The ring must hold nothing this worker
    /// should read from before now, or be tagged. Main thread.
    pub fn start(self: *Worker, allocator: Allocator, source: Source, settings: pitch.Settings) StartError!void {
        std.debug.assert(self.thread == null);
        const analysis = try Analysis.create(allocator);
        self.* = .{ .analysis = analysis, .tick_ns = self.tick_ns, .settings = held(settings) };
        self.thread = std.Thread.spawn(.{}, run, .{ self, analysis, source }) catch |err| {
            logging.err("tuner: couldn't start a tuner's analysis thread: {s}", .{@errorName(err)});
            allocator.destroy(analysis);
            self.* = .{ .tick_ns = self.tick_ns };
            return error.ThreadFailed;
        };
    }

    /// Stop the thread and free the analyser; settings go back to the
    /// defaults. Stopping a stopped worker is a no-op. Main thread.
    pub fn stop(self: *Worker, allocator: Allocator) void {
        const thread = self.thread orelse return;
        self.stop_event.set();
        thread.join();
        if (self.analysis) |a| allocator.destroy(a);
        self.* = .{ .tick_ns = self.tick_ns };
    }

    pub fn isRunning(self: *const Worker) bool {
        return self.thread != null;
    }

    /// A4's frequency, held to the tuner's range. Main thread.
    pub fn setReference(self: *Worker, hz: f64) void {
        if (!std.math.isFinite(hz)) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.settings.reference_hz = std.math.clamp(hz, reference_min_hz, reference_max_hz);
    }

    /// The absolute silence threshold, held to the tuner's range. It takes
    /// effect at the worker's next tick. Main thread.
    pub fn setSilenceDb(self: *Worker, db: f64) void {
        if (!std.math.isFinite(db)) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.settings.silence_db = std.math.clamp(db, silence_min_db, silence_max_db);
    }

    /// The latest reading and the settings, for the phones. Main thread.
    pub fn snapshot(self: *Worker) Snapshot {
        self.lock.lock();
        defer self.lock.unlock();
        return .{ .reading = self.reading, .settings = self.settings, .published = self.published };
    }

    /// `s` with both settings held to the tuner's range (a non-finite one
    /// to its default).
    fn held(s: pitch.Settings) pitch.Settings {
        const d = pitch.Settings{};
        return .{
            .reference_hz = if (std.math.isFinite(s.reference_hz)) std.math.clamp(s.reference_hz, reference_min_hz, reference_max_hz) else d.reference_hz,
            .silence_db = if (std.math.isFinite(s.silence_db)) std.math.clamp(s.silence_db, silence_min_db, silence_max_db) else d.silence_db,
        };
    }

    /// The thread: a tick every 1/30 s until `stop_event` is set.
    fn run(self: *Worker, analysis: *Analysis, source: Source) void {
        var timer = std.time.Timer.start() catch {
            logging.err("tuner: no monotonic clock; the tuner reads nothing", .{});
            return;
        };
        const missing_1_at_open = if (source.outputs) |h| h.missing_output_1.load(.acquire) else 0;
        const missing_2_at_open = if (source.outputs) |h| h.missing_output_2.load(.acquire) else 0;
        var due: u64 = 0;
        while (true) {
            if (source.outputs) |hook| self.watchOutputs(hook, missing_1_at_open, missing_2_at_open);

            self.lock.lock();
            const settings = self.settings;
            self.lock.unlock();

            const reading = analysis.tick(source.ring, source.tag, settings);

            const published = std.time.Instant.now() catch null;
            self.lock.lock();
            self.reading = reading;
            self.published = published;
            self.lock.unlock();

            // Keep to the 30 Hz grid; after an overrun, start a new one.
            due += self.tick_ns;
            const now = timer.read();
            if (now >= due) {
                due = now;
                if (self.stop_event.isSet()) return;
                continue;
            }
            self.stop_event.timedWait(due - now) catch continue;
            return;
        }
    }

    /// Log, once each, a device that gives the master no output 1, or only
    /// output 1, since the worker started.
    fn watchOutputs(self: *Worker, hook: *const audio_hook.Hook, missing_1_at_open: u64, missing_2_at_open: u64) void {
        switch (self.outputs_reported.load(.acquire)) {
            .ok => if (hook.missing_output_1.load(.acquire) != missing_1_at_open) {
                logging.warn("tuner: REAPER gives the audio hook no output 1 (does the device have outputs?); the master tuner hears nothing", .{});
                self.outputs_reported.store(.none_from_device, .release);
            } else if (hook.missing_output_2.load(.acquire) != missing_2_at_open) {
                logging.info("tuner: the device has one output; the master tuner reads output 1 alone", .{});
                self.outputs_reported.store(.only_output_1, .release);
            },
            .only_output_1 => if (hook.missing_output_1.load(.acquire) != missing_1_at_open) {
                logging.warn("tuner: REAPER gives the audio hook no output 1 (does the device have outputs?); the master tuner hears nothing", .{});
                self.outputs_reported.store(.none_from_device, .release);
            },
            .none_from_device => {},
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the analysis tick and the worker's thread have no allocator and call none" {
    // The analysis is allocated once, when the worker starts; every tick
    // after that, on the worker at 30 Hz, must not allocate. A tripwire
    // against an allocation creeping in, not a proof (core/no_alloc.zig):
    // it reads tick's, run's and watchOutputs's bodies and the same-file
    // functions they call. The analyser's own push and analyse are
    // tuner/pitch.zig's to keep allocation-free.
    if (comptime no_alloc.reachesAllocation(Analysis)) @compileError("an allocator or a growing container is reachable from Analysis");
    if (comptime no_alloc.paramsReachAllocation(@TypeOf(Analysis.tick))) @compileError("an allocator or a growing container is reachable from @TypeOf(Analysis.tick)");
    if (comptime no_alloc.paramsReachAllocation(@TypeOf(Worker.run))) @compileError("an allocator or a growing container is reachable from @TypeOf(Worker.run)");
    const source = @embedFile("tuner_worker.zig");
    for ([_][]const u8{ "tick", "run", "watchOutputs" }) |name| {
        if (try no_alloc.allocationIn(source, name)) |word| {
            std.debug.print("{s} in fn {s}\n", .{ word, name });
            return error.AllocatesOnTheAnalysisPath;
        }
    }
}

test "settings are held to the tuner's ranges" {
    var w = Worker{};
    w.setReference(300);
    try testing.expectEqual(@as(f64, 400), w.settings.reference_hz);
    w.setReference(500);
    try testing.expectEqual(@as(f64, 480), w.settings.reference_hz);
    w.setReference(std.math.nan(f64));
    try testing.expectEqual(@as(f64, 480), w.settings.reference_hz);
    w.setSilenceDb(20);
    try testing.expectEqual(@as(f64, -30), w.settings.silence_db);
    w.setSilenceDb(-120);
    try testing.expectEqual(@as(f64, -90), w.settings.silence_db);
}

test "a worker started with settings keeps them, held to the range, and stopping resets them" {
    const ring: *mono_ring.MonoRing = try testing.allocator.create(mono_ring.MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    var w = Worker{};
    try w.start(testing.allocator, .{ .ring = ring }, .{ .reference_hz = 500, .silence_db = -50 });
    try testing.expectEqual(pitch.Settings{ .reference_hz = 480, .silence_db = -50 }, w.snapshot().settings);
    try testing.expect(w.isRunning());
    w.stop(testing.allocator);
    try testing.expect(!w.isRunning());
    try testing.expectEqual(pitch.Settings{}, w.settings);
    w.stop(testing.allocator); // a no-op
}

test "stopping wakes the worker from its wait instead of letting it finish the tick" {
    const ring: *mono_ring.MonoRing = try testing.allocator.create(mono_ring.MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    var w = Worker{ .tick_ns = 60 * std.time.ns_per_s };
    try w.start(testing.allocator, .{ .ring = ring }, .{});
    std.Thread.sleep(10 * std.time.ns_per_ms); // the worker has ticked and is waiting

    var timer = try std.time.Timer.start();
    w.stop(testing.allocator);
    // Waiting out the tick would take a minute.
    try testing.expect(timer.read() < 10 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), w.tick_ns);
}
