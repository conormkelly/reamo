"""Feed REAPER's JACK audio inputs from a scenario: tones, note changes,
plucks, swells and silence, each per input and changeable while it plays.

    from jack_feeder import Feeder

    with Feeder() as f:                  # one channel per REAPER input, connected
        f.tone(0, 440.0, 0.5)            # input 1: A4 at half scale
        f.tone(0, 466.16, 0.5)           # note change, phase-continuous
        f.pluck(1, 82.41, 0.8, decay=1.5)  # input 2: falls 60 dB in 1.5 s
        f.swell(2, 220.0, 0.5, seconds=3)  # input 3: rises from silence over 3 s
        f.silence(0)
        print(f.stats())                 # CPU, xruns, reconnects, ...

Channels count from 0, as REAPER's input indices (I_RECINPUT) do: channel
i feeds REAPER:in<i+1>. Only for a scenario on JACK (`jack-inputs`; README,
"Audio inputs through JACK"), whose input count is HARNESS_JACK_INPUTS.

The JACK client runs in a child process (this file run as a script), so the
test's own Python work never holds the GIL its audio callback needs. The
test talks to it over the child's stdin and stdout, one JSON object per
line; the child exits when its stdin closes, so it can't outlive the test.

Each channel plays a voice: an optional segment played once (a pluck, a
swell), then a loop (a steady tone) or silence. Voices are rendered into
float32 tables when the test asks for them, and the audio callback only
copies table slices into JACK's buffers (ctypes.memmove), so a block costs
a few calls, not a Python loop per sample. A tone's loop holds a whole
number of cycles in about a second of samples, so its frequency is the one
asked for to within about 0.02 cents; `tone()` returns the exact one.

When REAPER re-registers its input ports (closing and reopening its audio
device: Audio_Quit/Audio_Init, or "close audio device when stopped"), their
connections are gone; the child reconnects on JACK's port-registration
callback, and polls every 0.25 s as well.

Stdlib only: the harness image has no pip and no network.
"""
import array
import ctypes as C
import json
import math
import os
import resource
import signal
import subprocess
import sys
import threading
import time


class FeederError(Exception):
    """The feeder child refused a request, or isn't running."""


class Feeder:
    """A JACK client feeding `channels` outputs into REAPER's inputs, run in
    a child process. Use it as a context manager, or call close()."""

    def __init__(self, channels=None, connect="REAPER:in", timeout=10.0):
        if channels is None:
            channels = int(os.environ.get("HARNESS_JACK_INPUTS", "0"))
        if channels < 1:
            raise FeederError("no JACK inputs: the scenario needs a `jack-inputs` file "
                              "(README, \"Audio inputs through JACK\")")
        self.channels = channels
        self._proc = subprocess.Popen(
            [sys.executable, "-I", os.path.abspath(__file__), "--channels", str(channels),
             "--connect", connect],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        ready = self._read(timeout)
        if ready.get("event") != "ready":
            self.close()
            raise FeederError(f"feeder did not start: {ready}")
        self.sample_rate = ready["sampleRate"]
        self.buffer_size = ready["bufferSize"]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _read(self, timeout):
        # The child answers each request at once; a reply that never comes
        # means it died, and readline returns "" when its stdout closes.
        box = {}
        t = threading.Thread(target=lambda: box.update(line=self._proc.stdout.readline()), daemon=True)
        t.start()
        t.join(timeout)
        line = box.get("line")
        if not line:
            raise FeederError(f"feeder child gave no answer within {timeout} s "
                              f"(exit status {self._proc.poll()})")
        return json.loads(line)

    def _call(self, timeout=10.0, **request):
        if self._proc.poll() is not None:
            raise FeederError(f"feeder child has exited (status {self._proc.returncode})")
        self._proc.stdin.write(json.dumps(request) + "\n")
        self._proc.stdin.flush()
        reply = self._read(timeout)
        if not reply.get("ok"):
            raise FeederError(reply.get("error", reply))
        return reply

    def tone(self, ch, freq, amp):
        """A steady sine on channel `ch` from the next block on. From a tone
        already playing it carries on at the same phase (a note change, no
        click); otherwise it starts at phase 0. Returns the exact frequency."""
        return self._call(op="tone", ch=ch, freq=freq, amp=amp)["freq"]

    def pluck(self, ch, freq, amp, decay=1.0):
        """A sine starting at `amp` that decays exponentially, 60 dB in
        `decay` seconds, then silence. Returns the exact frequency."""
        return self._call(op="pluck", ch=ch, freq=freq, amp=amp, decay=decay)["freq"]

    def swell(self, ch, freq, amp, seconds=2.0):
        """A sine rising linearly from silence to `amp` over `seconds`, then
        held there as a tone. Returns the exact frequency."""
        return self._call(op="swell", ch=ch, freq=freq, amp=amp, seconds=seconds)["freq"]

    def silence(self, ch):
        """Silence on channel `ch` from the next block on."""
        self._call(op="silence", ch=ch)

    def stats(self):
        """What the child has done so far: sampleRate, bufferSize, callbacks,
        xruns, connects (connections made, the first ones included),
        connected (per channel), cpuSeconds and wallSeconds (the child's
        CPU time and age: difference two calls for its CPU over a span),
        callbackMeanUs and callbackMaxUs (time in the audio callback),
        errors (callbacks that raised and played silence)."""
        return self._call(op="stats")

    def wait_connected(self, timeout=10.0, connects=0):
        """Wait until every channel is connected to its REAPER input and at
        least `connects` connections have been made in all: after REAPER
        re-registers its ports, pass the previous stats()["connects"] plus
        the channel count to wait for the reconnection. Returns stats()."""
        deadline = time.time() + timeout
        while True:
            s = self.stats()
            if all(s["connected"]) and s["connects"] >= connects:
                return s
            if time.time() > deadline:
                raise FeederError(f"not connected to REAPER's inputs within {timeout} s: {s}")
            time.sleep(0.05)

    def close(self):
        """Stop the child: it closes its JACK client when its stdin closes.
        A child that doesn't exit within 5 s is killed."""
        if self._proc.poll() is None:
            try:
                self._proc.stdin.close()
            except OSError:
                pass
            try:
                self._proc.wait(5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait()
        self._proc.stdout.close()


# ---------------------------------------------------------------------------
# The child: a JACK client over ctypes.

# Silence below this, in a pluck's tail: about -80 dBFS.
_FLOOR = 1e-4
_F32 = 4  # bytes per sample


def _jack():
    jack = C.CDLL("libjack.so.0")
    nframes = C.c_uint32
    jack.jack_client_open.restype = C.c_void_p
    jack.jack_client_open.argtypes = [C.c_char_p, C.c_int, C.POINTER(C.c_int)]
    jack.jack_client_close.argtypes = [C.c_void_p]
    jack.jack_activate.argtypes = [C.c_void_p]
    jack.jack_deactivate.argtypes = [C.c_void_p]
    jack.jack_get_sample_rate.restype = nframes
    jack.jack_get_sample_rate.argtypes = [C.c_void_p]
    jack.jack_get_buffer_size.restype = nframes
    jack.jack_get_buffer_size.argtypes = [C.c_void_p]
    jack.jack_port_register.restype = C.c_void_p
    jack.jack_port_register.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_ulong, C.c_ulong]
    jack.jack_port_get_buffer.restype = C.c_void_p
    jack.jack_port_get_buffer.argtypes = [C.c_void_p, nframes]
    jack.jack_port_name.restype = C.c_char_p
    jack.jack_port_name.argtypes = [C.c_void_p]
    jack.jack_port_by_name.restype = C.c_void_p
    jack.jack_port_by_name.argtypes = [C.c_void_p, C.c_char_p]
    jack.jack_port_connected_to.argtypes = [C.c_void_p, C.c_char_p]
    jack.jack_connect.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    jack._process_t = C.CFUNCTYPE(C.c_int, nframes, C.c_void_p)
    jack._xrun_t = C.CFUNCTYPE(C.c_int, C.c_void_p)
    jack._portreg_t = C.CFUNCTYPE(None, C.c_uint32, C.c_int, C.c_void_p)
    jack._shutdown_t = C.CFUNCTYPE(None, C.c_void_p)
    jack.jack_set_process_callback.argtypes = [C.c_void_p, jack._process_t, C.c_void_p]
    jack.jack_set_xrun_callback.argtypes = [C.c_void_p, jack._xrun_t, C.c_void_p]
    jack.jack_set_port_registration_callback.argtypes = [C.c_void_p, jack._portreg_t, C.c_void_p]
    jack.jack_on_shutdown.argtypes = [C.c_void_p, jack._shutdown_t, C.c_void_p]
    message_t = C.CFUNCTYPE(None, C.c_char_p)
    jack.jack_set_error_function.argtypes = [message_t]
    # libjack's messages, marked as the feeder's in a scenario's output.
    # "Unknown destination port" can show while REAPER re-registers its
    # ports: one went away between the lookup and the connect, and the next
    # pass connects its successor. Kept on `jack` so it outlives every call.
    jack._say = message_t(lambda msg: sys.stderr.write(
        f"feeder: libjack: {msg.decode(errors='replace')}\n"))
    jack.jack_set_error_function(jack._say)
    return jack


JackNoStartServer = 0x01
JackPortIsOutput = 0x2
EEXIST = 17


class _Loop:
    """A whole number of cycles of a sine, in about a second of samples."""

    def __init__(self, freq, amp, sr):
        self.cycles = max(1, round(freq))
        self.n = max(2, round(self.cycles * sr / freq))
        self.freq = self.cycles * sr / self.n
        w = 2 * math.pi * self.cycles / self.n
        sin = math.sin
        self.table = array.array("f", [amp * sin(w * i) for i in range(self.n)])
        self.addr = self.table.buffer_info()[0]

    def pos_at(self, phase):
        """The table position at `phase` radians."""
        return round(phase / (2 * math.pi) * self.n / self.cycles) % self.n

    def phase_at(self, pos):
        return (2 * math.pi * self.cycles * pos / self.n) % (2 * math.pi)


class _Voice:
    """What one channel plays: `head` once (or nothing), then `loop`
    forever (or silence). `follow` starts the loop at the phase the
    previous voice's loop had reached."""

    def __init__(self, head=None, loop=None, loop_pos=0, follow=False):
        self.head = head
        self.head_addr = head.buffer_info()[0] if head is not None else 0
        self.head_pos = 0
        self.loop = loop
        self.loop_pos = loop_pos
        self.follow = follow

    def take_over_from(self, prev):
        if self.follow and self.loop is not None and prev is not None and prev.loop is not None \
                and prev.head is None:
            self.loop_pos = self.loop.pos_at(prev.loop.phase_at(prev.loop_pos))

    def fill(self, addr, n, memmove=C.memmove, memset=C.memset):
        done = 0
        head = self.head
        if head is not None:
            k = min(n, len(head) - self.head_pos)
            memmove(addr, self.head_addr + self.head_pos * _F32, k * _F32)
            self.head_pos += k
            done = k
            if self.head_pos >= len(head):
                self.head = None
        loop = self.loop
        if loop is None:
            if done < n:
                memset(addr + done * _F32, 0, (n - done) * _F32)
            return
        while done < n:
            k = min(n - done, loop.n - self.loop_pos)
            memmove(addr + done * _F32, loop.addr + self.loop_pos * _F32, k * _F32)
            self.loop_pos = (self.loop_pos + k) % loop.n
            done += k


class _Child:
    def __init__(self, channels, connect):
        self.jack = jack = _jack()
        status = C.c_int(0)
        self.client = jack.jack_client_open(b"feeder", JackNoStartServer, C.byref(status))
        if not self.client:
            raise SystemExit(f"jack_client_open failed, status {status.value:#x} (is jackd running?)")
        self.sr = jack.jack_get_sample_rate(self.client)
        self.bs = jack.jack_get_buffer_size(self.client)
        self.ports = []
        for i in range(channels):
            p = jack.jack_port_register(self.client, f"out_{i + 1}".encode(),
                                        b"32 bit float mono audio", JackPortIsOutput, 0)
            if not p:
                raise SystemExit(f"jack_port_register out_{i + 1} failed (port-max reached?)")
            self.ports.append(p)
        self.names = [jack.jack_port_name(p) for p in self.ports]
        self.targets = [f"{connect}{i + 1}".encode() for i in range(channels)]
        # The test's thread only ever writes `wanted`; the audio callback only
        # writes `voices`, taking up a voice it hasn't yet played. Neither
        # clears the other's slot, so no request is lost between a read and
        # a write.
        self.voices = [_Voice() for _ in range(channels)]
        self.wanted = list(self.voices)
        self.callbacks = 0
        self.xruns = 0
        self.errors = 0
        self.cb_total = 0.0
        self.cb_max = 0.0
        self.connects = 0
        self.connected = [False] * channels
        self.gone = False
        self.started = time.monotonic()
        self.wake = threading.Event()
        self.stop = threading.Event()
        # ctypes callbacks must outlive the client: keep them referenced.
        self._cbs = (jack._process_t(self._process), jack._xrun_t(self._xrun),
                     jack._portreg_t(self._portreg), jack._shutdown_t(self._shutdown))
        jack.jack_set_process_callback(self.client, self._cbs[0], None)
        jack.jack_set_xrun_callback(self.client, self._cbs[1], None)
        jack.jack_set_port_registration_callback(self.client, self._cbs[2], None)
        jack.jack_on_shutdown(self.client, self._cbs[3], None)
        if jack.jack_activate(self.client):
            raise SystemExit("jack_activate failed")
        self.reconnector = threading.Thread(target=self._reconnect_loop, daemon=True)
        self.reconnector.start()

    # JACK's threads -------------------------------------------------------

    def _process(self, n, _arg):
        t0 = time.perf_counter()
        try:
            get = self.jack.jack_port_get_buffer
            for i, port in enumerate(self.ports):
                nxt = self.wanted[i]
                if nxt is not self.voices[i]:
                    nxt.take_over_from(self.voices[i])
                    self.voices[i] = nxt
                self.voices[i].fill(get(port, n), n)
        except Exception:  # noqa: BLE001  an exception here must not reach JACK
            self.errors += 1
            for port in self.ports:
                C.memset(self.jack.jack_port_get_buffer(port, n), 0, n * _F32)
        dt = time.perf_counter() - t0
        self.callbacks += 1
        self.cb_total += dt
        if dt > self.cb_max:
            self.cb_max = dt
        return 0

    def _xrun(self, _arg):
        self.xruns += 1
        return 0

    def _portreg(self, _port, _registered, _arg):
        # No JACK calls in a notification callback: hand it to the thread.
        self.wake.set()

    def _shutdown(self, _arg):
        self.gone = True
        self.stop.set()
        self.wake.set()

    # The reconnecting thread ----------------------------------------------

    def _reconnect_loop(self):
        jack = self.jack
        while not self.stop.is_set():
            for i, (ours, target) in enumerate(zip(self.names, self.targets)):
                if not jack.jack_port_by_name(self.client, target):
                    self.connected[i] = False
                    continue
                if jack.jack_port_connected_to(self.ports[i], target):
                    self.connected[i] = True
                    continue
                rc = jack.jack_connect(self.client, ours, target)
                if rc == 0:
                    self.connects += 1
                self.connected[i] = rc in (0, EEXIST)
            self.wake.wait(0.25)
            self.wake.clear()

    # Requests from the test -------------------------------------------------

    def _channel(self, req):
        ch = req.get("ch")
        if not isinstance(ch, int) or not 0 <= ch < len(self.ports):
            raise ValueError(f"ch must be 0 to {len(self.ports) - 1}, not {ch!r}")
        return ch

    def _tone_args(self, req):
        freq, amp = float(req["freq"]), float(req["amp"])
        if not 0 < freq < self.sr / 2:
            raise ValueError(f"freq must be above 0 and below {self.sr / 2} Hz, not {freq}")
        if not 0 <= amp <= 1:
            raise ValueError(f"amp must be 0 to 1 (full scale), not {amp}")
        return freq, amp

    def handle(self, req):
        op = req.get("op")
        if op == "stats":
            ru = resource.getrusage(resource.RUSAGE_SELF)
            wall = time.monotonic() - self.started
            return {"sampleRate": self.sr, "bufferSize": self.bs, "callbacks": self.callbacks,
                    "xruns": self.xruns, "errors": self.errors, "connects": self.connects,
                    "connected": list(self.connected),
                    "cpuSeconds": round(ru.ru_utime + ru.ru_stime, 3), "wallSeconds": round(wall, 3),
                    "callbackMeanUs": round(1e6 * self.cb_total / self.callbacks, 1) if self.callbacks else 0,
                    "callbackMaxUs": round(1e6 * self.cb_max, 1)}
        ch = self._channel(req)
        if op == "silence":
            self.wanted[ch] = _Voice()
            return {}
        freq, amp = self._tone_args(req)
        loop = _Loop(freq, amp, self.sr)
        if op == "tone":
            self.wanted[ch] = _Voice(loop=loop, follow=True)
        elif op == "pluck":
            decay = float(req.get("decay", 1.0))
            if decay <= 0:
                raise ValueError(f"decay must be above 0 s, not {decay}")
            tau = decay / math.log(1000)  # 60 dB = a factor of 1000
            length = int(self.sr * tau * math.log(amp / _FLOOR)) if amp > _FLOOR else 0
            k = -1 / (tau * self.sr)
            exp, t, n = math.exp, loop.table, loop.n
            head = array.array("f", [t[i % n] * exp(k * i) for i in range(length)])
            self.wanted[ch] = _Voice(head=head)
        elif op == "swell":
            seconds = float(req.get("seconds", 2.0))
            if seconds <= 0:
                raise ValueError(f"seconds must be above 0, not {seconds}")
            length = int(self.sr * seconds)
            t, n = loop.table, loop.n
            head = array.array("f", [t[i % n] * (i / length) for i in range(length)])
            self.wanted[ch] = _Voice(head=head, loop=loop, loop_pos=length % n)
        else:
            raise ValueError(f"unknown op {op!r}")
        return {"freq": loop.freq}

    def close(self):
        self.stop.set()
        self.wake.set()
        if not self.gone:
            self.jack.jack_deactivate(self.client)
            self.jack.jack_client_close(self.client)


def _child_main():
    import argparse
    ap = argparse.ArgumentParser(description="JACK feeder child; see the module docstring")
    ap.add_argument("--channels", type=int, required=True)
    ap.add_argument("--connect", default="REAPER:in")
    args = ap.parse_args()
    # The audio callback needs the GIL; the main thread renders voices with
    # it. A short switch interval keeps the callback's wait well inside a block.
    sys.setswitchinterval(0.001)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    child = _Child(args.channels, args.connect)

    def say(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    try:
        say({"event": "ready", "sampleRate": child.sr, "bufferSize": child.bs})
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                req = json.loads(line)
                if child.gone:
                    raise RuntimeError("the JACK server shut down")
                say({"ok": True, **child.handle(req)})
            except (ValueError, KeyError, TypeError, AttributeError, RuntimeError) as e:
                say({"ok": False, "error": f"{type(e).__name__}: {e}"})
    finally:
        child.close()


if __name__ == "__main__":
    _child_main()
