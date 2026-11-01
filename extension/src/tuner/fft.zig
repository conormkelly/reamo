//! In-place radix-2 complex FFT for the tuner's pitch analyser.
//!
//! The analyser needs only one thing from an FFT: the linear autocorrelation
//! of a real window, as the inverse transform of the window's power
//! spectrum. A plain iterative Cooley-Tukey transform over f64 does that
//! well inside the analyser's time budget, so there is no real-input
//! packing or split-radix here.
//!
//! `Fft(max_n)` holds the twiddle table for `max_n` points and transforms
//! any power-of-two size up to it, reading the table at a stride. It
//! allocates nothing; the caller owns the struct and the data.
const std = @import("std");

pub const Complex = struct {
    re: f64,
    im: f64,
};

pub fn Fft(comptime max_n: usize) type {
    comptime {
        if (max_n < 2 or !std.math.isPowerOfTwo(max_n)) @compileError("Fft size must be a power of two >= 2");
    }
    return struct {
        const Self = @This();

        /// twiddle[k] = e^(-2*pi*i*k/max_n), k < max_n/2.
        twiddle: [max_n / 2]Complex,

        pub fn init(self: *Self) void {
            for (&self.twiddle, 0..) |*w, k| {
                const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(max_n));
                w.* = .{ .re = @cos(angle), .im = @sin(angle) };
            }
        }

        /// Forward transform, X[k] = sum x[n] e^(-2*pi*i*k*n/N), unscaled.
        /// `data.len` must be a power of two no larger than `max_n`.
        pub fn forward(self: *const Self, data: []Complex) void {
            self.transform(data, false);
        }

        /// Inverse transform without the 1/N scale: inverse(forward(x)) = N * x.
        pub fn inverseUnscaled(self: *const Self, data: []Complex) void {
            self.transform(data, true);
        }

        fn transform(self: *const Self, data: []Complex, inverse: bool) void {
            const n = data.len;
            std.debug.assert(n >= 2 and n <= max_n and std.math.isPowerOfTwo(n));

            // Bit-reversal permutation.
            const bits: std.math.Log2Int(usize) = @intCast(std.math.log2_int(usize, n));
            const shift: std.math.Log2Int(usize) = @intCast(@bitSizeOf(usize) - @as(usize, bits));
            for (0..n) |i| {
                const j = @bitReverse(i) >> shift;
                if (j > i) std.mem.swap(Complex, &data[i], &data[j]);
            }

            // Butterflies. The inverse uses the conjugate twiddles.
            var len: usize = 2;
            while (len <= n) : (len <<= 1) {
                const half = len / 2;
                const stride = max_n / len;
                var start: usize = 0;
                while (start < n) : (start += len) {
                    for (0..half) |k| {
                        const w = self.twiddle[k * stride];
                        const w_im = if (inverse) -w.im else w.im;
                        const b = data[start + k + half];
                        const t_re = b.re * w.re - b.im * w_im;
                        const t_im = b.re * w_im + b.im * w.re;
                        const a = data[start + k];
                        data[start + k] = .{ .re = a.re + t_re, .im = a.im + t_im };
                        data[start + k + half] = .{ .re = a.re - t_re, .im = a.im - t_im };
                    }
                }
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn naiveDft(input: []const Complex, out: []Complex) void {
    const n: f64 = @floatFromInt(input.len);
    for (out, 0..) |*o, k| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (input, 0..) |x, t| {
            const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k * t % input.len)) / n;
            re += x.re * @cos(angle) - x.im * @sin(angle);
            im += x.re * @sin(angle) + x.im * @cos(angle);
        }
        o.* = .{ .re = re, .im = im };
    }
}

fn pseudoRandomSignal(out: []Complex, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (out) |*x| x.* = .{ .re = r.float(f64) * 2 - 1, .im = r.float(f64) * 2 - 1 };
}

test "forward matches a naive DFT at every size up to the table size" {
    var fft: Fft(64) = undefined;
    fft.init();
    var n: usize = 2;
    while (n <= 64) : (n <<= 1) {
        var input: [64]Complex = undefined;
        pseudoRandomSignal(input[0..n], n);
        var expected: [64]Complex = undefined;
        naiveDft(input[0..n], expected[0..n]);
        var data = input;
        fft.forward(data[0..n]);
        for (data[0..n], expected[0..n]) |got, want| {
            try testing.expectApproxEqAbs(want.re, got.re, 1e-9);
            try testing.expectApproxEqAbs(want.im, got.im, 1e-9);
        }
    }
}

test "inverseUnscaled of forward returns the input times N" {
    var fft: Fft(1024) = undefined;
    fft.init();
    var input: [1024]Complex = undefined;
    pseudoRandomSignal(&input, 7);
    var data = input;
    fft.forward(&data);
    fft.inverseUnscaled(&data);
    for (data, input) |got, want| {
        try testing.expectApproxEqAbs(want.re * 1024, got.re, 1e-9);
        try testing.expectApproxEqAbs(want.im * 1024, got.im, 1e-9);
    }
}

test "a cosine at bin k puts N/2 into bins k and N-k and nothing elsewhere" {
    var fft: Fft(256) = undefined;
    fft.init();
    var data: [256]Complex = undefined;
    for (&data, 0..) |*x, t| {
        x.* = .{ .re = @cos(2.0 * std.math.pi * 5.0 * @as(f64, @floatFromInt(t)) / 256.0), .im = 0 };
    }
    fft.forward(&data);
    for (data, 0..) |x, k| {
        const want: f64 = if (k == 5 or k == 251) 128 else 0;
        try testing.expectApproxEqAbs(want, x.re, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0), x.im, 1e-9);
    }
}
