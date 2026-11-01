//! In-place radix-2 FFT for the tuner's pitch analyser.
//!
//! The analyser needs one thing from an FFT: the linear autocorrelation of
//! a real window, as the inverse transform of the window's power spectrum
//! (`autocorrelate`). The complex transforms underneath are a plain
//! iterative Cooley-Tukey over f64.
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

        /// Linear autocorrelation of the real sequence `x`:
        /// r[tau] = sum over t of x[t] x[t + tau], for tau < r.len.
        ///
        /// `n` is the transform size: a power of two from 4 to `max_n`, and
        /// at least x.len + r.len - 1, so the circular product doesn't wrap
        /// into the lags asked for. `work` holds n / 2 values.
        ///
        /// A real sequence's power spectrum is real and even, so both
        /// transforms run at half size: the forward one on x's even and odd
        /// samples packed as one complex sequence, the inverse on the
        /// spectrum's even and odd parts packed the same way.
        pub fn autocorrelate(self: *const Self, x: []const f64, n: usize, work: []Complex, r: []f64) void {
            std.debug.assert(n >= 4 and n <= max_n and std.math.isPowerOfTwo(n));
            std.debug.assert(r.len >= 1 and x.len + r.len - 1 <= n and work.len >= n / 2);
            const half = n / 2;
            const z = work[0..half];
            const stride = max_n / n;

            // z[m] = x[2m] + i x[2m+1], zero past the end of x.
            for (z, 0..) |*c, m| {
                c.* = .{
                    .re = if (2 * m < x.len) x[2 * m] else 0,
                    .im = if (2 * m + 1 < x.len) x[2 * m + 1] else 0,
                };
            }
            self.forward(z);

            // Unpack the power spectrum P[k] = |X[k]|^2, k = 0 .. half, in
            // place: P[k] into z[k].re, and P[half] into z[0].im. X[k] =
            // E[k] + W^k O[k], where E and O are the transforms of the even
            // and odd samples: E[k] = (Z[k] + conj Z[half-k]) / 2 and
            // O[k] = (Z[k] - conj Z[half-k]) / 2i.
            const z0 = z[0];
            z[0] = .{ .re = square(z0.re + z0.im), .im = square(z0.re - z0.im) };
            for (1..half / 2 + 1) |k| {
                const j = half - k;
                const zk = z[k];
                const zj = z[j];
                const pk = spectrumPower(zk, zj, self.twiddle[k * stride]);
                const pj = spectrumPower(zj, zk, self.twiddle[j * stride]);
                z[k] = .{ .re = pk, .im = 0 };
                z[j] = .{ .re = pj, .im = 0 };
            }

            // Repack for the inverse: y[m] = c[2m] + i c[2m+1], c the
            // circular autocorrelation, is the half-size inverse transform
            // of (P[k] + P[k+half]) + i (P[k] - P[k+half]) e^(+2 pi i k / n),
            // and P[k+half] = P[half-k].
            const p0 = z[0].re;
            const p_half = z[0].im;
            z[0] = .{ .re = p0 + p_half, .im = p0 - p_half };
            for (1..half / 2 + 1) |k| {
                const j = half - k;
                const pk = z[k].re;
                const pj = z[j].re;
                const wk = self.twiddle[k * stride];
                const wj = self.twiddle[j * stride];
                z[k] = .{ .re = pk + pj + (pk - pj) * wk.im, .im = (pk - pj) * wk.re };
                z[j] = .{ .re = pj + pk + (pj - pk) * wj.im, .im = (pj - pk) * wj.re };
            }
            self.inverseUnscaled(z);

            const scale = 1 / @as(f64, @floatFromInt(n));
            for (r, 0..) |*v, tau| {
                const y = z[tau / 2];
                v.* = (if (tau % 2 == 0) y.re else y.im) * scale;
            }
        }

        /// |X[k]|^2 from Z[k] (`a`), Z[half-k] (`partner`) and W^k.
        fn spectrumPower(a: Complex, partner: Complex, w: Complex) f64 {
            const b = Complex{ .re = partner.re, .im = -partner.im };
            const even = Complex{ .re = (a.re + b.re) / 2, .im = (a.im + b.im) / 2 };
            // (a - b) / 2i
            const odd = Complex{ .re = (a.im - b.im) / 2, .im = -(a.re - b.re) / 2 };
            const x_re = even.re + w.re * odd.re - w.im * odd.im;
            const x_im = even.im + w.re * odd.im + w.im * odd.re;
            return x_re * x_re + x_im * x_im;
        }

        fn square(v: f64) f64 {
            return v * v;
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

fn directAutocorrelation(x: []const f64, r: []f64) void {
    for (r, 0..) |*v, tau| {
        var sum: f64 = 0;
        if (tau < x.len) {
            for (0..x.len - tau) |t| sum += x[t] * x[t + tau];
        }
        v.* = sum;
    }
}

test "autocorrelate matches the direct sum for every size and lag count it allows" {
    var fft: Fft(256) = undefined;
    fft.init();
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var x_buf: [256]f64 = undefined;
    for (&x_buf) |*v| v.* = rnd.float(f64) * 2 - 1;
    var work: [128]Complex = undefined;
    var got: [256]f64 = undefined;
    var want: [256]f64 = undefined;
    var n: usize = 4;
    while (n <= 256) : (n <<= 1) {
        for (1..n) |x_len| {
            const lags = n - x_len + 1;
            const x = x_buf[0..x_len];
            fft.autocorrelate(x, n, &work, got[0..lags]);
            directAutocorrelation(x, want[0..lags]);
            for (got[0..lags], want[0..lags]) |g, wv| try testing.expectApproxEqAbs(wv, g, 1e-10);
        }
    }
}

test "autocorrelate equals the inverse of the full complex power spectrum" {
    var fft: Fft(8192) = undefined;
    fft.init();
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    var x: [4096]f64 = undefined;
    for (&x) |*v| v.* = rnd.float(f64) * 2 - 1;
    var full: [8192]Complex = undefined;
    for (&full, 0..) |*c, i| c.* = .{ .re = if (i < x.len) x[i] else 0, .im = 0 };
    fft.forward(&full);
    for (&full) |*c| c.* = .{ .re = c.re * c.re + c.im * c.im, .im = 0 };
    fft.inverseUnscaled(&full);
    var work: [4096]Complex = undefined;
    var r: [2048]f64 = undefined;
    fft.autocorrelate(&x, 8192, &work, &r);
    for (r, 0..) |v, tau| try testing.expectApproxEqAbs(full[tau].re / 8192, v, 1e-9);
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
