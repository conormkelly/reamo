//! A mono f32 ring from REAPER's audio thread to one reader, for the
//! tuner's analyser: the audio hook mixes a stereo pair to mono as
//! (L + R) / 2 and writes it here; the tuner's analysis thread reads it.
//!
//! Single producer, single consumer, lock-free, fixed size: nothing is
//! allocated. As the stream's ring does, a block that doesn't fit is dropped
//! whole and counted. The reader, seeing the count move, throws away what is
//! left unread, so after a stall the analyser hears the audio from then on,
//! never audio that has gone out of date while it waited.
const std = @import("std");

/// Samples held: 1.36 s at 48 kHz, 0.34 s at 192 kHz, against the 33 ms
/// between the analysis's 30 Hz reads.
pub const capacity: usize = 1 << 16;
const mask = capacity - 1;

pub const MonoRing = struct {
    samples: [capacity]f32 = [_]f32{0} ** capacity,
    /// Samples ever written. Producer-owned; the consumer reads it.
    write_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Samples ever consumed or discarded. Consumer-owned; the producer reads it.
    read_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Blocks dropped because they didn't fit. Producer-owned.
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// The sample rate of the latest block written, as f64 bits; 0 before any.
    rate_bits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// `dropped` as the consumer last saw it. Consumer-only.
    seen_dropped: u64 = 0,

    pub const Read = struct {
        /// Samples copied into the caller's buffer.
        n: usize,
        /// Blocks were dropped since the last read; what was left unread
        /// has been thrown away, and the next read starts on fresh audio.
        skipped: bool,
    };

    /// Producer (audio thread). Mixes `len` samples of `left` and `right`
    /// to mono and appends them, or drops the block whole if it doesn't fit.
    /// A block whose sample rate isn't finite and positive is ignored.
    /// Real-time safe: no allocation, no lock, no I/O.
    pub fn write(self: *MonoRing, left: [*]const f64, right: [*]const f64, len: usize, sample_rate: f64) void {
        if (!(sample_rate > 0 and sample_rate < std.math.inf(f64))) return;
        const w = self.write_count.raw;
        const r = self.read_count.load(.acquire);
        if (w - r + len > capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.rate_bits.store(@bitCast(sample_rate), .monotonic);
        for (0..len) |i| {
            const m = (left[i] + right[i]) * 0.5;
            // Beyond f32's range this is an infinity, which the analyser,
            // like any sample over +60 dBFS or NaN, takes for silence.
            self.samples[@intCast((w + i) & mask)] = @floatCast(m);
        }
        // Release: the samples (and the rate) are visible before the count.
        self.write_count.store(w + len, .release);
    }

    /// The sample rate of the latest block written, or 0 before any.
    pub fn sampleRate(self: *const MonoRing) f64 {
        return @bitCast(self.rate_bits.load(.acquire));
    }

    /// Consumer. Copies the oldest unread samples into `out`.
    pub fn read(self: *MonoRing, out: []f32) Read {
        const d = self.dropped.load(.acquire);
        if (d != self.seen_dropped) {
            self.discard();
            return .{ .n = 0, .skipped = true };
        }
        const w = self.write_count.load(.acquire);
        const r = self.read_count.raw;
        const n: usize = @intCast(@min(w - r, out.len));
        for (0..n) |i| out[i] = self.samples[@intCast((r + i) & mask)];
        self.read_count.store(r + n, .release);
        return .{ .n = n, .skipped = false };
    }

    /// Consumer. Throws away everything unread, and forgets earlier drops.
    pub fn discard(self: *MonoRing) void {
        self.seen_dropped = self.dropped.load(.acquire);
        self.read_count.store(self.write_count.load(.acquire), .release);
    }

    /// Samples written and not yet read.
    pub fn available(self: *const MonoRing) usize {
        return @intCast(self.write_count.load(.acquire) - self.read_count.load(.acquire));
    }

    /// Empties the ring and forgets its rate. Only while no producer runs:
    /// the hook isn't registered.
    pub fn reset(self: *MonoRing) void {
        self.write_count.store(0, .release);
        self.read_count.store(0, .release);
        self.dropped.store(0, .release);
        self.rate_bits.store(0, .release);
        self.seen_dropped = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn writeConst(ring: *MonoRing, l: f64, r: f64, len: usize, rate: f64) void {
    var left: [4096]f64 = undefined;
    var right: [4096]f64 = undefined;
    @memset(left[0..len], l);
    @memset(right[0..len], r);
    ring.write(&left, &right, len, rate);
}

test "a written block reads back as (L + R) / 2, in order" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    const left = [_]f64{ 1.0, 0.5, -0.25, 0 };
    const right = [_]f64{ 0.0, 0.5, -0.75, 0.5 };
    ring.write(&left, &right, 4, 48000);
    try testing.expectEqual(@as(usize, 4), ring.available());
    try testing.expectEqual(@as(f64, 48000), ring.sampleRate());

    var out: [8]f32 = undefined;
    const got = ring.read(&out);
    try testing.expectEqual(MonoRing.Read{ .n = 4, .skipped = false }, got);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, -0.5, 0.25 }, out[0..4]);
    try testing.expectEqual(@as(usize, 0), ring.available());
    try testing.expectEqual(MonoRing.Read{ .n = 0, .skipped = false }, ring.read(&out));
}

test "reads smaller than what is waiting take the oldest first and leave the rest" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    const left = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    ring.write(&left, &left, 5, 44100);
    var out: [2]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), ring.read(&out).n);
    try testing.expectEqualSlices(f32, &.{ 0.1, 0.2 }, &out);
    try testing.expectEqual(@as(usize, 2), ring.read(&out).n);
    try testing.expectEqualSlices(f32, &.{ 0.3, 0.4 }, &out);
    try testing.expectEqual(@as(usize, 1), ring.read(&out).n);
    try testing.expectEqual(@as(f32, 0.5), out[0]);
}

test "samples stay in order across the end of the buffer" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    var out: [4096]f32 = undefined;
    // Walk the positions to just short of the end.
    var written: usize = 0;
    while (written + 4096 <= capacity - 10) : (written += 4096) {
        writeConst(ring, 0, 0, 4096, 48000);
        _ = ring.read(&out);
    }
    var left: [100]f64 = undefined;
    for (&left, 0..) |*x, i| x.* = @floatFromInt(i);
    ring.write(&left, &left, 100, 48000);
    var got: [100]f32 = undefined;
    try testing.expectEqual(@as(usize, 100), ring.read(&got).n);
    for (got, 0..) |x, i| try testing.expectEqual(@as(f32, @floatFromInt(i)), x);
}

test "a block that doesn't fit is dropped whole, and the reader then skips to fresh audio" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    var written: usize = 0;
    while (written + 4096 <= capacity) : (written += 4096) writeConst(ring, 0.25, 0.25, 4096, 48000);
    try testing.expectEqual(capacity, ring.available());
    // The reader stalled: the next block has no room.
    writeConst(ring, 0.75, 0.75, 256, 48000);
    try testing.expectEqual(capacity, ring.available());
    try testing.expectEqual(@as(u64, 1), ring.dropped.load(.acquire));

    var out: [4096]f32 = undefined;
    try testing.expectEqual(MonoRing.Read{ .n = 0, .skipped = true }, ring.read(&out));
    try testing.expectEqual(@as(usize, 0), ring.available());
    // What the hook writes from now on reads normally.
    writeConst(ring, 1.0, 0.0, 3, 48000);
    try testing.expectEqual(MonoRing.Read{ .n = 3, .skipped = false }, ring.read(&out));
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5 }, out[0..3]);
}

test "absurd and non-finite samples pass through for the analyser to take as silence" {
    // The analyser counts samples beyond 1000 and non-finite ones as
    // silence (thresholds.gate.max_sample); the ring passes them on, a value
    // beyond f32's range as an infinity.
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    const nan = std.math.nan(f64);
    const left = [_]f64{ nan, 1e300, 1e10, 0.5 };
    const right = [_]f64{ 0, 1e300, 1e10, 0.5 };
    ring.write(&left, &right, 4, 48000);
    var out: [4]f32 = undefined;
    _ = ring.read(&out);
    try testing.expect(std.math.isNan(out[0]));
    try testing.expect(std.math.isPositiveInf(out[1]));
    try testing.expectEqual(@as(f32, 1e10), out[2]);
    try testing.expectEqual(@as(f32, 0.5), out[3]);
}

test "a block without a usable sample rate is not written" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    for ([_]f64{ 0, -48000, std.math.nan(f64), std.math.inf(f64) }) |rate| {
        writeConst(ring, 0.5, 0.5, 16, rate);
    }
    try testing.expectEqual(@as(usize, 0), ring.available());
    try testing.expectEqual(@as(f64, 0), ring.sampleRate());
}

test "discard drops what is unread and keeps what comes after" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    writeConst(ring, 0.1, 0.1, 100, 48000);
    ring.discard();
    try testing.expectEqual(@as(usize, 0), ring.available());
    writeConst(ring, 0.2, 0.2, 10, 96000);
    var out: [16]f32 = undefined;
    try testing.expectEqual(@as(usize, 10), ring.read(&out).n);
    try testing.expectEqual(@as(f32, 0.2), out[0]);
    try testing.expectEqual(@as(f64, 96000), ring.sampleRate());
}

test "the reader sees every sample a concurrent writer publishes, in order" {
    const ring = try testing.allocator.create(MonoRing);
    defer testing.allocator.destroy(ring);
    ring.* = .{};
    const blocks = 4000;
    const block = 128;
    const Producer = struct {
        fn run(r: *MonoRing) void {
            var left: [block]f64 = undefined;
            for (0..blocks) |b| {
                for (&left, 0..) |*x, i| x.* = @floatFromInt((b * block + i) % 1000);
                // Wait for room, so no block is dropped and every value is
                // owed to the reader.
                while (capacity - r.available() < block) std.Thread.yield() catch {};
                r.write(&left, &left, block, 48000);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{ring});
    var expect: usize = 0;
    var out: [512]f32 = undefined;
    while (expect < blocks * block) {
        const got = ring.read(&out);
        try testing.expect(!got.skipped);
        for (out[0..got.n]) |x| {
            try testing.expectEqual(@as(f32, @floatFromInt(expect % 1000)), x);
            expect += 1;
        }
    }
    t.join();
    try testing.expectEqual(@as(u64, 0), ring.dropped.load(.acquire));
}
