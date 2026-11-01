//! `extension/effects/REAmo/PitchDetect.jsfx` (version 1.2) ported to Zig,
//! step for step, as the baseline the tuner's own analyser is measured
//! against.
//!
//! It keeps the JSFX's behaviour exactly, quirks included: a 4096-sample
//! window whatever the sample rate, an analysis every 512 samples, YIN's
//! first dip under the threshold or else the global minimum (so it reports
//! a pitch for anything above the silence threshold, noise included), and
//! note and cents left at their last values when a frequency falls out of
//! range. Parity with the JSFX running in REAPER is pinned by the tests
//! below, whose expected values were read from REAPER.
const std = @import("std");
const fft_mod = @import("fft.zig");

pub const win_size = 4096;
pub const fft_size = win_size * 2;
pub const hop_size = 512;
pub const half_win = win_size / 2;

pub const Outputs = struct {
    freq: f64,
    note: f64,
    cents: f64,
    confidence: f64,
};

pub const JsfxPort = struct {
    srate: f64,
    /// slider5
    reference_hz: f64 = 440,
    /// slider10
    yin_threshold: f64 = 0.15,
    /// slider11
    silence_db: f64 = -60,

    input_buf: [win_size]f64 = [_]f64{0} ** win_size,
    write_pos: usize = 0,
    samples_since_analysis: usize = 0,

    current_freq: f64 = 0,
    current_note: f64 = 0,
    current_cents: f64 = 0,
    current_confidence: f64 = 0,

    fft: fft_mod.Fft(fft_size) = undefined,
    fft_buf: [fft_size]fft_mod.Complex = undefined,
    autocorr_buf: [win_size]f64 = undefined,
    sqr_cumsum: [win_size]f64 = undefined,
    yin_buf: [half_win]f64 = undefined,
    yin_cmnd: [half_win]f64 = undefined,

    /// Initialises in place: the struct is about 230 KB, too big to return
    /// by value comfortably.
    pub fn init(self: *JsfxPort, srate: f64) void {
        self.* = .{ .srate = srate };
        self.fft.init();
    }

    /// The JSFX's @sample block for one mono sample ((spl0 + spl1) / 2).
    /// Returns true when the sample completed a hop and the outputs (the
    /// JSFX's sliders 1-4) were updated.
    pub fn pushSample(self: *JsfxPort, x: f64) bool {
        self.input_buf[self.write_pos] = x;
        self.write_pos = (self.write_pos + 1) % win_size;
        self.samples_since_analysis += 1;
        if (self.samples_since_analysis < hop_size) return false;
        self.samples_since_analysis = 0;
        if (self.isSilent()) {
            self.current_freq = 0;
            self.current_note = 0;
            self.current_cents = 0;
            self.current_confidence = 0;
        } else {
            self.computeAutocorrelation();
            self.computeCumsumSquares();
            self.computeYinDifference();
            self.findPitch();
            self.calcNoteCents();
        }
        return true;
    }

    pub fn outputs(self: *const JsfxPort) Outputs {
        return .{
            .freq = self.current_freq,
            .note = self.current_note,
            .cents = self.current_cents,
            .confidence = self.current_confidence,
        };
    }

    /// Window sample i, oldest first.
    fn windowSample(self: *const JsfxPort, i: usize) f64 {
        return self.input_buf[(self.write_pos + i) % win_size];
    }

    fn computeAutocorrelation(self: *JsfxPort) void {
        for (0..win_size) |i| self.fft_buf[i] = .{ .re = self.windowSample(i), .im = 0 };
        for (win_size..fft_size) |i| self.fft_buf[i] = .{ .re = 0, .im = 0 };
        self.fft.forward(&self.fft_buf);
        for (&self.fft_buf) |*c| c.* = .{ .re = c.re * c.re + c.im * c.im, .im = 0 };
        self.fft.inverseUnscaled(&self.fft_buf);
        for (0..win_size) |i| self.autocorr_buf[i] = self.fft_buf[i].re / fft_size;
    }

    fn computeCumsumSquares(self: *JsfxPort) void {
        var sum: f64 = 0;
        for (0..win_size) |i| {
            const s = self.windowSample(i);
            sum += s * s;
            self.sqr_cumsum[i] = sum;
        }
    }

    fn computeYinDifference(self: *JsfxPort) void {
        self.yin_buf[0] = 0;
        self.yin_cmnd[0] = 1;
        var running_sum: f64 = 0;
        for (1..half_win) |tau| {
            const r_t_0 = self.sqr_cumsum[win_size - tau - 1];
            const r_t_tau_0 = self.sqr_cumsum[win_size - 1] - self.sqr_cumsum[tau - 1];
            const diff = @max(0, r_t_0 + r_t_tau_0 - 2 * self.autocorr_buf[tau]);
            self.yin_buf[tau] = diff;
            running_sum += diff;
            self.yin_cmnd[tau] = if (running_sum > 0) diff * @as(f64, @floatFromInt(tau)) / running_sum else 1;
        }
    }

    fn findPitch(self: *JsfxPort) void {
        const min_tau: usize = @max(@as(usize, @intFromFloat(@floor(self.srate / 2000))), 2);
        var found = false;
        var best_tau = min_tau;
        var tau = min_tau;
        while (tau < half_win - 2 and !found) : (tau += 1) {
            const c = self.yin_cmnd[tau];
            if (c < self.yin_threshold and c < self.yin_cmnd[tau - 1] and c <= self.yin_cmnd[tau + 1]) {
                found = true;
                best_tau = tau;
            }
        }
        if (!found) {
            best_tau = min_tau;
            tau = min_tau + 1;
            while (tau < half_win - 1) : (tau += 1) {
                if (self.yin_cmnd[tau] < self.yin_cmnd[best_tau]) best_tau = tau;
            }
        }

        var period: f64 = @floatFromInt(best_tau);
        if (best_tau > 1 and best_tau < half_win - 2) {
            const s0 = self.yin_buf[best_tau - 1];
            const s1 = self.yin_buf[best_tau];
            const s2 = self.yin_buf[best_tau + 1];
            const denom = s0 - 2 * s1 + s2;
            if (denom != 0) {
                const delta = std.math.clamp((s0 - s2) / (2 * denom), -1, 1);
                period += delta;
            }
        }

        if (period > 0) {
            const freq = self.srate / period;
            if (freq >= 20 and freq <= 5000) {
                self.current_freq = freq;
                self.current_confidence = std.math.clamp(1 - self.yin_cmnd[best_tau], 0, 1);
            } else {
                self.current_freq = 0;
                self.current_confidence = 0;
            }
        }
    }

    fn calcNoteCents(self: *JsfxPort) void {
        if (self.current_freq > 20) {
            const midi_float = 69 + 12 * @log(self.current_freq / self.reference_hz) / @log(2.0);
            const midi_int = @floor(midi_float + 0.5);
            self.current_note = midi_int;
            self.current_cents = (midi_float - midi_int) * 100;
        }
    }

    fn isSilent(self: *const JsfxPort) bool {
        var sum: f64 = 0;
        for (self.input_buf) |s| sum += s * s;
        const r = @sqrt(sum / win_size);
        const db = 20 * std.math.log10(@max(r, 0.0000001));
        return db < self.silence_db;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn runPort(port: *JsfxPort, samples: []const f32) void {
    for (samples) |s| _ = port.pushSample(s);
}

test "updates its outputs once every 512 samples" {
    const port = try testing.allocator.create(JsfxPort);
    defer testing.allocator.destroy(port);
    port.init(44100);
    var updates: usize = 0;
    for (0..512 * 10) |i| {
        if (port.pushSample(@sin(@as(f64, @floatFromInt(i)) * 0.03))) updates += 1;
    }
    try testing.expectEqual(@as(usize, 10), updates);
}

test "reads a steady 220 Hz sine as A3 within a cent" {
    const port = try testing.allocator.create(JsfxPort);
    defer testing.allocator.destroy(port);
    port.init(44100);
    var buf: [44100 / 2]f32 = undefined;
    @import("signals.zig").sine(&buf, 44100, 220, 0.5, 0);
    runPort(port, &buf);
    const o = port.outputs();
    try testing.expectApproxEqAbs(@as(f64, 220), o.freq, 0.1);
    try testing.expectEqual(@as(f64, 57), o.note);
    try testing.expect(@abs(o.cents) < 1);
    try testing.expect(o.confidence > 0.99);
}

test "clears every output on input below the silence threshold" {
    const port = try testing.allocator.create(JsfxPort);
    defer testing.allocator.destroy(port);
    port.init(48000);
    var buf: [48000 / 2]f32 = undefined;
    @import("signals.zig").sine(&buf, 48000, 330, 0.5, 0);
    runPort(port, &buf);
    try testing.expect(port.outputs().freq > 0);
    // -70 dBFS RMS sine, under the default -60 dB threshold.
    @import("signals.zig").sine(&buf, 48000, 330, 0.000447, 0);
    runPort(port, &buf);
    try testing.expectEqual(Outputs{ .freq = 0, .note = 0, .cents = 0, .confidence = 0 }, port.outputs());
}

/// One signal the JSFX analysed in REAPER, and what its sliders read after
/// exactly `stop` samples (a whole number of hops).
const ParityCase = struct {
    wave: enum { sine, sawtooth, missing_fundamental, pluck, sine_plus_noise, noise },
    sample_rate: f64,
    freq: f64,
    amp: f64,
    stop: usize,
    t60_s: f64,
    lowpass: f64,
    seed: u64,
    noise: f64,
    noise_seed: u64,
    want: Outputs,
};

/// Read from PitchDetect.jsfx 1.2 in REAPER 7.83 (Linux, dummy audio
/// device, at each project sample rate). REAPER ran a copy of the JSFX whose
/// algorithm text was unchanged, with a generator in front of the @sample
/// body that computes the same doubles as `parityInput`, and a stop after
/// `stop` samples. Each case starts from the JSFX's zeroed state.
const parity_cases = [_]ParityCase{
    .{ .wave = .sine, .sample_rate = 44100, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406871870787597, .note = 40, .cents = -0.00036465126953544313, .confidence = 0.99999853876362543 } },
    .{ .wave = .sine, .sample_rate = 44100, .freq = 440.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 440.00010099559103, .note = 69, .cents = 0.00039737951311735742, .confidence = 0.99989955928927643 } },
    .{ .wave = .sine, .sample_rate = 44100, .freq = 1318.51, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1318.5193489967137, .note = 88, .cents = 0.011976493235010821, .confidence = 0.99653926763322476 } },
    .{ .wave = .sine, .sample_rate = 44100, .freq = 41.2034, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 41.203393630914661, .note = 28, .cents = -0.0021421484774464261, .confidence = 0.99999874716101733 } },
    .{ .wave = .sine, .sample_rate = 44100, .freq = 30.8677, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 30.867698504155843, .note = 23, .cents = -0.00043883358316065824, .confidence = 0.9999991613238931 } },
    .{ .wave = .sawtooth, .sample_rate = 44100, .freq = 110.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 109.99420088067686, .note = 45, .cents = -0.091271795247394039, .confidence = 0.99988440939846435 } },
    .{ .wave = .missing_fundamental, .sample_rate = 44100, .freq = 98.0, .amp = 0.2, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 97.999990813908482, .note = 43, .cents = 0.019994430340375402, .confidence = 1 } },
    .{ .wave = .pluck, .sample_rate = 44100, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.405724056018911, .note = 40, .cents = -0.024478536479222157, .confidence = 0.9971652473200352 } },
    .{ .wave = .pluck, .sample_rate = 44100, .freq = 82.4069, .amp = 0.5, .stop = 40960, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406655638865146, .note = 40, .cents = -0.0049073374469799091, .confidence = 0.99928268606755577 } },
    .{ .wave = .pluck, .sample_rate = 44100, .freq = 41.2034, .amp = 0.5, .stop = 20480, .t60_s = 4.0, .lowpass = 0.9, .seed = 4242, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 41.203352085604529, .note = 28, .cents = -0.0038877496379541299, .confidence = 0.9980697629688714 } },
    .{ .wave = .pluck, .sample_rate = 44100, .freq = 329.628, .amp = 0.5, .stop = 10240, .t60_s = 2.0, .lowpass = 0.0, .seed = 999, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 329.64084855815264, .note = 64, .cents = 0.069807528143428499, .confidence = 0.99906234045337461 } },
    .{ .wave = .sine_plus_noise, .sample_rate = 44100, .freq = 220.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.3, .noise_seed = 777, .want = .{ .freq = 31.391645617216685, .note = 23, .cents = 29.138849710476222, .confidence = 0.85170955448446828 } },
    .{ .wave = .noise, .sample_rate = 44100, .freq = 220.0, .amp = 0.0, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.1, .noise_seed = 31337, .want = .{ .freq = 21.639006922601052, .note = 17, .cents = -14.956792944555986, .confidence = 0.36798587182752995 } },
    .{ .wave = .sine, .sample_rate = 44100, .freq = 196.0, .amp = 0.0005, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 0, .note = 0, .cents = 0, .confidence = 0 } },
    .{ .wave = .sine, .sample_rate = 44100, .freq = 1900.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1900.0828771823531, .note = 94, .cents = 32.58430166964672, .confidence = 0.99839549243455694 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406889189380209, .note = 40, .cents = -8.1590769696049392e-07, .confidence = 0.99998779402844484 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 440.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 439.99981200641224, .note = 69, .cents = -0.00073968402176660675, .confidence = 0.99998649951787022 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 1318.51, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1318.5225328743102, .note = 88, .cents = 0.016156963283719961, .confidence = 0.99759952779040617 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 41.2034, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 41.203397597816569, .note = 28, .cents = -0.0019754720291587091, .confidence = 0.99999997266432827 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 30.8677, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 30.867697874171537, .note = 23, .cents = -0.00047416664443744594, .confidence = 0.99999999678530016 } },
    .{ .wave = .sawtooth, .sample_rate = 48000, .freq = 110.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 110.01150777091217, .note = 45, .cents = 0.18110547990914938, .confidence = 0.99841134774215679 } },
    .{ .wave = .missing_fundamental, .sample_rate = 48000, .freq = 98.0, .amp = 0.2, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 97.999940218772679, .note = 43, .cents = 0.019100633885216212, .confidence = 0.99994257080550064 } },
    .{ .wave = .pluck, .sample_rate = 48000, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406887045922616, .note = 40, .cents = -4.5846449125974686e-05, .confidence = 0.98370360392996781 } },
    .{ .wave = .pluck, .sample_rate = 48000, .freq = 82.4069, .amp = 0.5, .stop = 40960, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406935792487815, .note = 40, .cents = 0.00097823893412396501, .confidence = 0.99689255561285817 } },
    .{ .wave = .pluck, .sample_rate = 48000, .freq = 41.2034, .amp = 0.5, .stop = 20480, .t60_s = 4.0, .lowpass = 0.9, .seed = 4242, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 41.2040715884119, .note = 28, .cents = 0.026343210220147739, .confidence = 0.99905724712504929 } },
    .{ .wave = .pluck, .sample_rate = 48000, .freq = 329.628, .amp = 0.5, .stop = 10240, .t60_s = 2.0, .lowpass = 0.0, .seed = 999, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 329.63030582854896, .note = 64, .cents = 0.014437496132302385, .confidence = 0.99743989677791467 } },
    .{ .wave = .sine_plus_noise, .sample_rate = 48000, .freq = 220.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.3, .noise_seed = 777, .want = .{ .freq = 31.430221975399416, .note = 23, .cents = 31.265011052962421, .confidence = 0.85153061119294238 } },
    .{ .wave = .noise, .sample_rate = 48000, .freq = 220.0, .amp = 0.0, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.1, .noise_seed = 31337, .want = .{ .freq = 23.552660596028357, .note = 18, .cents = 31.750107116641857, .confidence = 0.36798587182752995 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 196.0, .amp = 0.0005, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 0, .note = 0, .cents = 0, .confidence = 0 } },
    .{ .wave = .sine, .sample_rate = 48000, .freq = 1900.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1900.07119644151, .note = 94, .cents = 32.57365889260484, .confidence = 0.99789003790757247 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406892382426292, .note = 40, .cents = 6.6264770737234358e-05, .confidence = 0.99999866095059109 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 440.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 439.999894285989, .note = 69, .cents = -0.00041594481245965653, .confidence = 0.99990132556941624 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 1318.51, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1318.5059189817646, .note = 88, .cents = -0.0056573910072188482, .confidence = 0.9999503142649413 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 41.2034, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 43.10850439882698, .note = 29, .cents = -21.750929525292406, .confidence = 0.97347099546102689 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 30.8677, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 43.10850439882698, .note = 29, .cents = -21.750929525292406, .confidence = 0.20998175268220665 } },
    .{ .wave = .sawtooth, .sample_rate = 88200, .freq = 110.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 109.9947137108656, .note = 45, .cents = -0.083200215042467107, .confidence = 0.99978623187629245 } },
    .{ .wave = .missing_fundamental, .sample_rate = 88200, .freq = 98.0, .amp = 0.2, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 97.999997308574351, .note = 43, .cents = 0.020109162864656582, .confidence = 0.99999999999999967 } },
    .{ .wave = .pluck, .sample_rate = 88200, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406471335448586, .note = 40, .cents = -0.0087792662910146646, .confidence = 0.9856284605352259 } },
    .{ .wave = .pluck, .sample_rate = 88200, .freq = 82.4069, .amp = 0.5, .stop = 40960, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406790730936152, .note = 40, .cents = -0.0020692681239609101, .confidence = 0.99766743804364155 } },
    .{ .wave = .pluck, .sample_rate = 88200, .freq = 41.2034, .amp = 0.5, .stop = 20480, .t60_s = 4.0, .lowpass = 0.9, .seed = 4242, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 43.95820586432167, .note = 29, .cents = 12.041063032396693, .confidence = 0.43479945552006261 } },
    .{ .wave = .pluck, .sample_rate = 88200, .freq = 329.628, .amp = 0.5, .stop = 10240, .t60_s = 2.0, .lowpass = 0.0, .seed = 999, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 329.6287850092819, .note = 64, .cents = 0.0064500625597929684, .confidence = 0.99464188237537154 } },
    .{ .wave = .sine_plus_noise, .sample_rate = 88200, .freq = 220.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.3, .noise_seed = 777, .want = .{ .freq = 55.323553641408317, .note = 33, .cents = 10.15465271364846, .confidence = 0.85131483718084489 } },
    .{ .wave = .noise, .sample_rate = 88200, .freq = 220.0, .amp = 0.0, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.1, .noise_seed = 31337, .want = .{ .freq = 43.278013845202103, .note = 29, .cents = -14.956792944555275, .confidence = 0.36798587182752995 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 196.0, .amp = 0.0005, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 0, .note = 0, .cents = 0, .confidence = 0 } },
    .{ .wave = .sine, .sample_rate = 88200, .freq = 1900.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1900.0051858361319, .note = 94, .cents = 32.513512834397318, .confidence = 0.99839635505991364 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.406898996426605, .note = 40, .cents = 0.00020521409496154774, .confidence = 0.99999997109918159 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 440.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 439.99975576236193, .note = 69, .cents = -0.00096098325599314194, .confidence = 0.99998682604077904 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 1318.51, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1318.5062178819433, .note = 88, .cents = -0.0052649270060101117, .confidence = 0.99986510765882364 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 41.2034, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 46.920821114369502, .note = 30, .cents = 24.955970535906147, .confidence = 0.79626515423268551 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 30.8677, .amp = 0.5, .stop = 15360, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 46.920821114369502, .note = 30, .cents = 24.955970535906147, .confidence = 0 } },
    .{ .wave = .sawtooth, .sample_rate = 96000, .freq = 110.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 109.99387791015886, .note = 45, .cents = -0.096355139405090995, .confidence = 0.99963002799200273 } },
    .{ .wave = .missing_fundamental, .sample_rate = 96000, .freq = 98.0, .amp = 0.2, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 97.999996838431798, .note = 43, .cents = 0.02010085748835877, .confidence = 0.99994823880217976 } },
    .{ .wave = .pluck, .sample_rate = 96000, .freq = 82.4069, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.412159975754903, .note = 40, .cents = 0.11072624976264933, .confidence = 0.99444493092460151 } },
    .{ .wave = .pluck, .sample_rate = 96000, .freq = 82.4069, .amp = 0.5, .stop = 40960, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 82.408387941432352, .note = 40, .cents = 0.0314852286997791, .confidence = 0.99930998263167392 } },
    .{ .wave = .pluck, .sample_rate = 96000, .freq = 41.2034, .amp = 0.5, .stop = 20480, .t60_s = 4.0, .lowpass = 0.9, .seed = 4242, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 48.300939939437193, .note = 31, .cents = -24.856425236335156, .confidence = 0.42435235326323861 } },
    .{ .wave = .pluck, .sample_rate = 96000, .freq = 329.628, .amp = 0.5, .stop = 10240, .t60_s = 2.0, .lowpass = 0.0, .seed = 999, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 329.62470577579063, .note = 64, .cents = -0.014974497228337214, .confidence = 0.99780523907390184 } },
    .{ .wave = .sine_plus_noise, .sample_rate = 96000, .freq = 220.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.3, .noise_seed = 777, .want = .{ .freq = 55.329150026840637, .note = 33, .cents = 10.329770947531358, .confidence = 0.85299608812728134 } },
    .{ .wave = .noise, .sample_rate = 96000, .freq = 220.0, .amp = 0.0, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.1, .noise_seed = 31337, .want = .{ .freq = 47.105321192056714, .note = 30, .cents = 31.750107116641857, .confidence = 0.36798587182752995 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 196.0, .amp = 0.0005, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 0, .note = 0, .cents = 0, .confidence = 0 } },
    .{ .wave = .sine, .sample_rate = 96000, .freq = 1900.0, .amp = 0.5, .stop = 10240, .t60_s = 3.0, .lowpass = 0.0, .seed = 12345, .noise = 0.0, .noise_seed = 777, .want = .{ .freq = 1899.9960922118964, .note = 94, .cents = 32.505226946707921, .confidence = 0.9982604407727822 } },
};

/// The JSFX-side generator's signal, in doubles: the `signals` generators
/// plus, for the noise cases, MinStd uniform noise in (-noise, noise).
fn parityInput(c: ParityCase, out: []f64) void {
    const signals = @import("signals.zig");
    switch (c.wave) {
        .sine, .sine_plus_noise => signals.sine(out, c.sample_rate, c.freq, c.amp, 0),
        .sawtooth => signals.sawtooth(out, c.sample_rate, c.freq, c.amp),
        .missing_fundamental => signals.harmonics(out, c.sample_rate, c.freq, &.{ 0, c.amp, c.amp, c.amp, c.amp, c.amp }),
        .pluck => signals.pluck(out, c.sample_rate, c.freq, .{
            .amp = c.amp,
            .t60_s = c.t60_s,
            .excitation_lowpass = c.lowpass,
            .seed = c.seed,
        }),
        .noise => @memset(out, 0),
    }
    if (c.wave == .sine_plus_noise or c.wave == .noise) {
        var rng = signals.MinStd.init(c.noise_seed);
        for (out) |*s| s.* += c.noise * rng.next();
    }
}

test "matches PitchDetect.jsfx as REAPER runs it, at 44.1, 48, 88.2 and 96 kHz" {
    const port = try testing.allocator.create(JsfxPort);
    defer testing.allocator.destroy(port);
    var buf: [40960]f64 = undefined;
    for (parity_cases) |c| {
        const input = buf[0..c.stop];
        parityInput(c, input);
        port.init(c.sample_rate);
        for (input) |s| _ = port.pushSample(s);
        const got = port.outputs();
        errdefer std.debug.print("case {s} {d} Hz at {d}: got {any}, want {any}\n", .{ @tagName(c.wave), c.freq, c.sample_rate, got, c.want });
        try testing.expectApproxEqRel(c.want.freq, got.freq, 1e-12);
        try testing.expectEqual(c.want.note, got.note);
        try testing.expectApproxEqAbs(c.want.cents, got.cents, 1e-9);
        try testing.expectApproxEqAbs(c.want.confidence, got.confidence, 1e-12);
    }
}
