const std = @import("std");

/// Lock-free Single-Producer Single-Consumer ring buffer for audio streaming.
///
/// Producer: REAPER audio thread (writes deinterleaved f64, stored as interleaved i16)
/// Consumer: Network thread (reads interleaved i16 chunks for WebSocket sending)
///
/// Fixed-size comptime buffer — no allocator needed.
/// Overflow policy: drop newest (producer discards when full, never touches read_pos).
pub const CAPACITY: usize = 24000; // ~500ms at 48kHz in stereo sample pairs

pub const AudioRingBuffer = struct {
    /// Interleaved stereo i16 samples: [L0, R0, L1, R1, ...]
    /// Length = CAPACITY * 2 (left + right for each pair)
    buffer: [CAPACITY * 2]i16 = [_]i16{0} ** (CAPACITY * 2),

    /// Write position in stereo sample pairs (0..CAPACITY), wraps around.
    /// Only written by producer (audio thread).
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Read position in stereo sample pairs (0..CAPACITY), wraps around.
    /// Only written by consumer (network thread).
    read_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Current sample rate from audio thread (updated every callback).
    sample_rate: std.atomic.Value(u32) = std.atomic.Value(u32).init(48000),

    /// Number of samples dropped due to overflow (diagnostic).
    overflow_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Convert deinterleaved f64 left/right channels to interleaved i16 and write to ring buffer.
    /// Called from REAPER audio thread — MUST be real-time safe (no alloc, no lock, no I/O).
    /// On overflow (buffer full), drops the new samples (never advances read_pos).
    pub fn writeFromF64(self: *AudioRingBuffer, left: [*]const f64, right: [*]const f64, len: usize) void {
        const wp = self.write_pos.load(.acquire);
        const rp = self.read_pos.load(.acquire);
        // Reserve one slot to distinguish full from empty (wp == rp means empty).
        const avail_space = (CAPACITY - 1) - occupancy(wp, rp);

        if (len > avail_space) {
            // Drop newest: discard the entire write if it doesn't fit.
            // Partial writes would create torn frames.
            _ = self.overflow_count.fetchAdd(1, .monotonic);
            return;
        }

        var w = wp;
        for (0..len) |i| {
            const idx = w * 2;
            self.buffer[idx] = f64ToI16(left[i]);
            self.buffer[idx + 1] = f64ToI16(right[i]);
            w = (w + 1) % CAPACITY;
        }

        // Release ensures the buffer writes above are visible before the position update.
        self.write_pos.store(w, .release);
    }

    /// Read up to `max_pairs` stereo sample pairs into `out`.
    /// Returns the number of pairs actually read.
    /// Called from network thread.
    pub fn read(self: *AudioRingBuffer, out: []i16, max_pairs: usize) usize {
        const wp = self.write_pos.load(.acquire);
        const rp = self.read_pos.load(.acquire);
        const avail = occupancy(wp, rp);

        const to_read = @min(avail, @min(max_pairs, out.len / 2));
        if (to_read == 0) return 0;

        var r = rp;
        for (0..to_read) |i| {
            const idx = r * 2;
            out[i * 2] = self.buffer[idx];
            out[i * 2 + 1] = self.buffer[idx + 1];
            r = (r + 1) % CAPACITY;
        }

        self.read_pos.store(r, .release);
        return to_read;
    }

    /// Number of stereo sample pairs available for reading.
    pub fn available(self: *const AudioRingBuffer) usize {
        const wp = self.write_pos.load(.acquire);
        const rp = self.read_pos.load(.acquire);
        return occupancy(wp, rp);
    }

    /// Reset buffer to empty state. NOT thread-safe — only call when no producer/consumer active.
    pub fn reset(self: *AudioRingBuffer) void {
        self.write_pos.store(0, .release);
        self.read_pos.store(0, .release);
        self.overflow_count.store(0, .release);
    }

    /// Calculate occupancy from write and read positions.
    fn occupancy(wp: usize, rp: usize) usize {
        if (wp >= rp) {
            return wp - rp;
        } else {
            return CAPACITY - rp + wp;
        }
    }

    /// Convert f64 audio sample to i16, with clamping.
    fn f64ToI16(sample: f64) i16 {
        const clamped = @max(-1.0, @min(1.0, sample));
        return @intFromFloat(clamped * 32767.0);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "init state: available is zero" {
    var rb = AudioRingBuffer{};
    try std.testing.expectEqual(@as(usize, 0), rb.available());
}

test "write and read roundtrip" {
    var rb = AudioRingBuffer{};

    // Write 4 stereo pairs from f64 channels
    const left = [_]f64{ 0.5, -0.5, 0.25, -0.25 };
    const right = [_]f64{ 0.75, -0.75, 0.125, -0.125 };
    rb.writeFromF64(&left, &right, 4);

    try std.testing.expectEqual(@as(usize, 4), rb.available());

    // Read back
    var out: [8]i16 = undefined;
    const pairs_read = rb.read(&out, 4);
    try std.testing.expectEqual(@as(usize, 4), pairs_read);
    try std.testing.expectEqual(@as(usize, 0), rb.available());

    // Verify values (L0, R0, L1, R1, ...)
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(0.5), out[0]); // L0
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(0.75), out[1]); // R0
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(-0.5), out[2]); // L1
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(-0.75), out[3]); // R1
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(0.25), out[4]); // L2
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(0.125), out[5]); // R2
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(-0.25), out[6]); // L3
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(-0.125), out[7]); // R3
}

test "f64 to i16 conversion" {
    // Full scale positive
    try std.testing.expectEqual(@as(i16, 32767), AudioRingBuffer.f64ToI16(1.0));
    // Full scale negative: -1.0 * 32767 = -32767
    try std.testing.expectEqual(@as(i16, -32767), AudioRingBuffer.f64ToI16(-1.0));
    // Zero
    try std.testing.expectEqual(@as(i16, 0), AudioRingBuffer.f64ToI16(0.0));
    // Clipping above +1.0
    try std.testing.expectEqual(@as(i16, 32767), AudioRingBuffer.f64ToI16(1.5));
    // Clipping below -1.0
    try std.testing.expectEqual(@as(i16, -32767), AudioRingBuffer.f64ToI16(-1.5));
    // Half scale
    try std.testing.expectEqual(@as(i16, 16383), AudioRingBuffer.f64ToI16(0.5));
}

test "read returns 0 when empty" {
    var rb = AudioRingBuffer{};
    var out: [8]i16 = undefined;
    const pairs_read = rb.read(&out, 4);
    try std.testing.expectEqual(@as(usize, 0), pairs_read);
}

test "available tracks writes and reads" {
    var rb = AudioRingBuffer{};

    const left = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    const right = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    rb.writeFromF64(&left, &right, 5);
    try std.testing.expectEqual(@as(usize, 5), rb.available());

    var out: [4]i16 = undefined;
    _ = rb.read(&out, 2);
    try std.testing.expectEqual(@as(usize, 3), rb.available());

    _ = rb.read(&out, 2);
    try std.testing.expectEqual(@as(usize, 1), rb.available());

    _ = rb.read(&out, 2);
    try std.testing.expectEqual(@as(usize, 0), rb.available());
}

test "wraparound: write past capacity, data integrity" {
    var rb = AudioRingBuffer{};

    // Fill most of the buffer
    const fill_len = CAPACITY - 10;
    var left_fill: [CAPACITY]f64 = undefined;
    var right_fill: [CAPACITY]f64 = undefined;
    for (0..fill_len) |i| {
        left_fill[i] = 0.1;
        right_fill[i] = 0.2;
    }
    rb.writeFromF64(&left_fill, &right_fill, fill_len);
    try std.testing.expectEqual(fill_len, rb.available());

    // Read it all to advance read_pos near end of buffer
    var drain: [CAPACITY * 2]i16 = undefined;
    _ = rb.read(&drain, fill_len);
    try std.testing.expectEqual(@as(usize, 0), rb.available());

    // Now write 20 pairs — this wraps around the end of the buffer
    for (0..20) |i| {
        left_fill[i] = @as(f64, @floatFromInt(i)) / 20.0;
        right_fill[i] = @as(f64, @floatFromInt(i)) / 20.0 * -1.0;
    }
    rb.writeFromF64(&left_fill, &right_fill, 20);
    try std.testing.expectEqual(@as(usize, 20), rb.available());

    // Read back and verify wraparound data integrity
    var out: [40]i16 = undefined;
    const read_count = rb.read(&out, 20);
    try std.testing.expectEqual(@as(usize, 20), read_count);

    // Spot check first and last pair
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(0.0), out[0]); // L0
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(0.0), out[1]); // R0
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(19.0 / 20.0), out[38]); // L19
    try std.testing.expectEqual(AudioRingBuffer.f64ToI16(-19.0 / 20.0), out[39]); // R19
}

test "overflow drops newest: buffer full, write discarded" {
    var rb = AudioRingBuffer{};

    // Fill the buffer completely (CAPACITY - 1 pairs to leave 1 slot)
    // Actually, we can fill CAPACITY-1 because occupancy == CAPACITY means
    // write_pos == read_pos which looks empty. So max usable is CAPACITY-1.
    const fill_len = CAPACITY - 1;
    var left_fill: [CAPACITY]f64 = undefined;
    var right_fill: [CAPACITY]f64 = undefined;
    for (0..fill_len) |i| {
        left_fill[i] = 0.5;
        right_fill[i] = 0.5;
    }
    rb.writeFromF64(&left_fill, &right_fill, fill_len);
    try std.testing.expectEqual(fill_len, rb.available());

    // Now try to write more — should be dropped
    const new_left = [_]f64{0.99};
    const new_right = [_]f64{0.99};
    rb.writeFromF64(&new_left, &new_right, 1);

    // Available should NOT increase — data was dropped
    try std.testing.expectEqual(fill_len, rb.available());
    // Overflow counter should be 1
    try std.testing.expectEqual(@as(u64, 1), rb.overflow_count.load(.acquire));
}

test "sample_rate atomic store and load" {
    var rb = AudioRingBuffer{};
    try std.testing.expectEqual(@as(u32, 48000), rb.sample_rate.load(.acquire));

    rb.sample_rate.store(44100, .release);
    try std.testing.expectEqual(@as(u32, 44100), rb.sample_rate.load(.acquire));

    rb.sample_rate.store(96000, .release);
    try std.testing.expectEqual(@as(u32, 96000), rb.sample_rate.load(.acquire));
}

test "multiple write-read cycles" {
    var rb = AudioRingBuffer{};

    // Simulate audio callback pattern: write small chunks, read them
    var left: [256]f64 = undefined;
    var right: [256]f64 = undefined;
    for (0..256) |i| {
        left[i] = @as(f64, @floatFromInt(i)) / 256.0;
        right[i] = @as(f64, @floatFromInt(i)) / 256.0 * -1.0;
    }

    // Write 256 pairs
    rb.writeFromF64(&left, &right, 256);
    try std.testing.expectEqual(@as(usize, 256), rb.available());

    // Read 128 pairs
    var out: [512]i16 = undefined;
    const r1 = rb.read(&out, 128);
    try std.testing.expectEqual(@as(usize, 128), r1);
    try std.testing.expectEqual(@as(usize, 128), rb.available());

    // Write another 256
    rb.writeFromF64(&left, &right, 256);
    try std.testing.expectEqual(@as(usize, 384), rb.available());

    // Read all 384
    var big_out: [768]i16 = undefined;
    const r2 = rb.read(&big_out, 384);
    try std.testing.expectEqual(@as(usize, 384), r2);
    try std.testing.expectEqual(@as(usize, 0), rb.available());
}

test "read limited by output buffer size" {
    var rb = AudioRingBuffer{};

    const left = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    const right = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    rb.writeFromF64(&left, &right, 4);

    // Output buffer can only hold 2 pairs (4 i16s)
    var small_out: [4]i16 = undefined;
    const pairs_read = rb.read(&small_out, 10); // request 10 but buffer only holds 2 pairs
    try std.testing.expectEqual(@as(usize, 2), pairs_read);
    try std.testing.expectEqual(@as(usize, 2), rb.available());
}

test "reset clears buffer" {
    var rb = AudioRingBuffer{};

    const left = [_]f64{ 0.5, 0.5 };
    const right = [_]f64{ 0.5, 0.5 };
    rb.writeFromF64(&left, &right, 2);
    try std.testing.expectEqual(@as(usize, 2), rb.available());

    rb.reset();
    try std.testing.expectEqual(@as(usize, 0), rb.available());
}
