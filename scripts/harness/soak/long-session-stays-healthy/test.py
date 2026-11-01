"""A long session stays healthy: REAPER doesn't crash or hang, its memory
is flat after warm-up, and its CPU doesn't creep upward.

A crashed REAPER session is the worst failure REAmo can cause, and slow
leaks and rare crashes only show over time. The band session plays on
repeat while phones do what phones do, for SOAK_MINUTES:

- one phone (the desk) stays connected the whole run with the mixer,
  timeline peaks, project notes and toggle states subscribed;
- SOAK_PHONES more connect, churn subscriptions (tracks, peaks viewports,
  FX chains, FX params, routing, audio stream, notes, toggle states),
  send read-only commands, pings and clock syncs, then leave: dropping
  the socket, closing it properly, or going quiet first (a phone put to
  sleep), and connect again;
- page loads (GET / and an asset) arrive alongside.

The tuner is left out unless SOAK_OPS has "+tuner": opening and closing it
leaves undo points in REAPER (RV1-165), so with it in the run fails.

Nothing a phone does here is an edit, so the run must leave REAPER's undo
history as it found it: an undo point would be an edit the user never
made, and undo history grows by design, which would hide a leak.

REAPER's RSS, CPU (process and main thread), threads and open files are
sampled from /proc every SOAK_SAMPLE_SECS, and each thread's CPU with its
name: REAPER names its threads, REAmo doesn't name its own. RSS by mapping
(libraries, [heap], anonymous) is read at the end of warm-up and at the
end. Two probes tell a slow REAPER from a hung one, each failing after
HANG_SECS without an answer: the desk sends a main-thread command every
2 s (a stall shows within about 12 s), and the sampler makes a ReaScript
call when RPC_SECS have passed (a stall seen only by ReaScript shows
within RPC_SECS + SOAK_SAMPLE_SECS + HANG_SECS, 25 s by default). The
series goes to out/<scenario>/soak-series.csv and soak-threads.csv as it
is taken (so a crash leaves it), and the verdict with its numbers to
soak-summary.json, which every run writes, failed or not.

long-session-baseline runs this script as the control: REAPER without
REAmo, the same session, no phones; only the ReaScript probe. It reports
what the checks find and fails only on a broken setup. When run.sh
runs both (make soak), the soak waits up to BASELINE_WAIT_SECS after its
end for the control's summary and reports both runs' numbers and the
difference. The limits judge the soak's own numbers, not the difference.

Settings (env, all optional): SOAK_MINUTES (3, at least 2),
SOAK_WARMUP_MINUTES (a third of the run, 1 to 20), SOAK_PHONES (5),
SOAK_SAMPLE_SECS (5), SOAK_SEED (random, printed, and kept in replay.env
for a failure's replay line; it seeds the phones' choices, but timing
still makes two runs differ), SOAK_OPS (see phone_ops) and the limits
below as SOAK_<NAME>. A setting that doesn't parse fails the run.
"""
import csv
import json
import os
import random
import re
import statistics
import struct
import subprocess
import sys
import threading
import time
import traceback
import urllib.request

from reamo_client import (HOST, PORT, Client, Closed, InvalidFrame, ReaperError, open_project,
                          reaper, skip_unless_linux)

skip_unless_linux("samples REAPER's memory and CPU from Linux's /proc")


# The control (soak/long-session-baseline, whose `no-extension` file has
# boot.sh start REAPER without REAmo) runs this script too: the same
# session on repeat, no phones. It reports its numbers and fails only when
# its setup is wrong (see main).
BASELINE = "long-session-baseline"
CONTROL = os.environ.get("HARNESS_SCENARIO") == BASELINE

# Settings that don't parse, reported as the run's failure (with its summary).
SETTING_ERRORS = []


def setting(name, default, kind=float, minimum=0):
    """SOAK_<name> from the environment as `kind`, at least `minimum`; a
    value that isn't is recorded in SETTING_ERRORS and the default used."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = kind(raw)
    except ValueError:
        SETTING_ERRORS.append(f"{name}={raw!r} is not {'an integer' if kind is int else 'a number'}")
        return default
    if value < minimum:
        SETTING_ERRORS.append(f"{name}={raw!r} is below {minimum}")
        return default
    return value


MINUTES = setting("SOAK_MINUTES", 3.0)
# Under this load REAPER's heap climbs for about 20 minutes, flattening as it
# goes, then holds: a third of the run, at most 20 minutes, is warm-up.
WARMUP_MINUTES = setting("SOAK_WARMUP_MINUTES", min(20.0, max(1.0, MINUTES / 3)))
SAMPLE_SECS = setting("SOAK_SAMPLE_SECS", 5.0, minimum=1)
# The phones' settings: the control has no phones, so it neither reads
# nor records them.
PHONES = 0 if CONTROL else setting("SOAK_PHONES", 5, int)
SEED = None if CONTROL else setting("SOAK_SEED", random.randrange(1 << 31), int)
HANG_SECS = 10.0
RPC_SECS = 10.0
# The shortest run that leaves samples after a minute of warm-up to judge.
MIN_MINUTES = 2.0

# Limits, from measured runs (the README's "Soak tests" has the numbers).
# Each can be overridden as SOAK_<NAME>.
LIMITS = {
    # RSS after warm-up: the end (median of the last tenth of samples)
    # against the start (median of the first tenth). A short run ends inside
    # the warm-up climb, whose steps reach 12 MB, so this catches gross
    # growth only; the slope below is the leak check.
    "RSS_GROWTH_MB": setting("SOAK_RSS_GROWTH_MB", 24),
    # Least-squares slope of RSS after warm-up (0.06 MB/h measured over the
    # 40 minutes after a 20-minute warm-up), and the rise in mean process
    # CPU from the first third of that span to the last, in points of one
    # core (within 1.1 measured, on a mean of 18). Both are checked only
    # when warm-up is at least SLOPE_MIN_WARMUP_MINUTES and at least
    # SLOPE_MIN_MINUTES follow it: with the default warm-up, runs of 60
    # minutes or more. Before that the heap is still climbing.
    "RSS_SLOPE_MB_PER_HOUR": setting("SOAK_RSS_SLOPE_MB_PER_HOUR", 6),
    "CPU_DRIFT_POINTS": setting("SOAK_CPU_DRIFT_POINTS", 3),
    "SLOPE_MIN_WARMUP_MINUTES": setting("SOAK_SLOPE_MIN_WARMUP_MINUTES", 20),
    "SLOPE_MIN_MINUTES": setting("SOAK_SLOPE_MIN_MINUTES", 30),
    # Threads and open files after warm-up, median of the last tenth of
    # samples minus the first (measured: 1 at most; threads come and go
    # between 40 and 41): a connection that leaves one behind grows these
    # with every reconnect.
    "THREAD_GROWTH": setting("SOAK_THREAD_GROWTH", 3),
    "FD_GROWTH": setting("SOAK_FD_GROWTH", 4),
    # Allowed refusals (ALLOWED_REFUSALS) as a share of commands, in percent
    # (measured: 0.003).
    **({} if CONTROL else {"REFUSAL_PCT": setting("SOAK_REFUSAL_PCT", 0.5)}),
}

# Refusals a healthy run can get. Any other refusal fails the run.
ALLOWED_REFUSALS = {
    # Only while the listener slots are full by the phones' own count (see
    # Stats.stream_slots_full); any other STREAM_FAILED fails the run.
    ("audio/startStream", "STREAM_FAILED"),
}
# The server takes four listeners. The phones keep to three at once, but a
# phone that has just stopped or left can hold its slot a moment longer.
SERVER_LISTENERS = 4
MAX_STREAMING = 3
SLOT_RELEASE_SECS = 5.0

OUT = os.environ.get("HARNESS_OUT", "/tmp")
CLK_TCK = os.sysconf("SC_CLK_TCK")

# The soak and its control find each other through marker files in their
# out dirs under the shared out/, matched by run.sh's run id: an older
# run's files are never read. A scenario named twice in a run gets
# out/<scenario>.<i>, so each looks in every out dir of the other's name.
SOAK = "long-session-stays-healthy"
OUT_ROOT = os.path.dirname(OUT)
RUN_ID = os.environ.get("HARNESS_RUN_ID", "")
RUN_SCENARIOS = os.environ.get("HARNESS_RUN_SCENARIOS", "").split()
WITH_BASELINE = not CONTROL and BASELINE in RUN_SCENARIOS
WITH_SOAK = CONTROL and SOAK in RUN_SCENARIOS
CONTROL_STARTED = "control-started.json"  # the control writes it as it starts
SOAK_DONE = "soak-done.json"  # the soak writes it as it ends: the control then stops
# How long after its end the soak waits for the control's summary.
BASELINE_WAIT_SECS = 120.0



def write_json(path, data):
    """Written whole or not at all: the other container reads it."""
    with open(path + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
    os.replace(path + ".tmp", path)


def mark(name, **extra):
    write_json(os.path.join(OUT, name), {"run_id": RUN_ID, "time": time.time(), **extra})


def this_run(scenario, name):
    """[(out dir name, contents)] of the file `name` in each out dir of
    `scenario` that this run wrote, in out dir order."""
    try:
        dirs = sorted(d for d in os.listdir(OUT_ROOT) if re.fullmatch(re.escape(scenario) + r"(\.\d+)?", d))
    except OSError:
        return []
    found = []
    for d in dirs:
        try:
            with open(os.path.join(OUT_ROOT, d, name)) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if data.get("run_id") == RUN_ID:
            found.append((d, data))
    return found


# Toggle states the web UI watches: play, repeat, metronome, count-in.
TOGGLES = [1007, 1068, 40364, 41745]


class Hang(Exception):
    """REAPER stopped answering."""


class Stats:
    """What every thread reports: counters (the sampler reads and resets
    the per-sample ones), refusals, problems, and the desk's last
    debug/memoryStats."""

    def __init__(self):
        self.lock = threading.Lock()
        self.total = {}
        self.window = {}
        self.refusals = {}
        self.problems = []
        self.setup_problems = []
        self.hung = False
        self.memory = {}
        self.streaming = 0
        self.released = []  # when a listener slot was last given back
        self.stop = threading.Event()

    def add(self, key, n=1):
        with self.lock:
            self.total[key] = self.total.get(key, 0) + n
            self.window[key] = self.window.get(key, 0) + n

    def peak(self, key, value):
        with self.lock:
            self.window[key] = max(self.window.get(key, 0), value)
            self.total[key] = max(self.total.get(key, 0), value)

    def refused(self, command, code):
        with self.lock:
            k = f"{command}: {code}"
            self.refusals[k] = self.refusals.get(k, 0) + 1

    def take_window(self):
        with self.lock:
            w, self.window = self.window, {}
            return w

    def set_memory(self, payload):
        with self.lock:
            self.memory = dict(payload)

    def get_memory(self):
        with self.lock:
            return dict(self.memory)

    def take_stream_slot(self):
        with self.lock:
            if self.streaming >= MAX_STREAMING:
                return False
            self.streaming += 1
            return True

    def give_stream_slot(self, used=True):
        """`used`: the server had the slot, and may hold it a moment longer."""
        with self.lock:
            self.streaming -= 1
            if used:
                self.released.append(time.monotonic())

    def stream_slots_full(self):
        """Whether a startStream refusal is expected: the other phones
        streaming, plus slots given back within SLOT_RELEASE_SECS, fill
        the server's listeners. The caller holds one of `streaming`."""
        with self.lock:
            now = time.monotonic()
            self.released = [t for t in self.released if now - t < SLOT_RELEASE_SECS]
            return (self.streaming - 1) + len(self.released) >= SERVER_LISTENERS

    def problem(self, text, hang=False, setup=False):
        """`setup`: the run itself is set up wrong, which fails the control too."""
        print(f"PROBLEM: {text}", flush=True)
        with self.lock:
            self.problems.append(text)
            if setup:
                self.setup_problems.append(text)
            self.hung = self.hung or hang
        self.stop.set()


stats = Stats()


def run_command(c, command, **params):
    """A command that must be answered within HANG_SECS. A refusal outside
    ALLOWED_REFUSALS fails the run."""
    t0 = time.monotonic()
    try:
        r = c.command(command, timeout=HANG_SECS, **params)
    except TimeoutError:
        raise Hang(f"{command} unanswered after {HANG_SECS:.0f} s") from None
    ms = (time.monotonic() - t0) * 1000
    stats.add("commands")
    stats.peak("cmd_ms_max", ms)
    if not r.get("success"):
        code = (r.get("error") or {}).get("code", "?")
        stats.add("cmd_refused")
        stats.refused(command, code)
        allowed = (command, code) in ALLOWED_REFUSALS and (
            command != "audio/startStream" or stats.stream_slots_full())
        if not allowed:
            stats.problem(f"{command} refused: {r.get('error')}")
    return r, ms


def absorb(c):
    """Count what a client has read and let it go, so a long run doesn't
    keep every event in memory."""
    stats.add("events", len(c.events))
    for frame in c.binary:
        stats.add("peaks_frames" if frame[:1] == b"\x02" else "audio_frames")
    c.events.clear()
    c.binary.clear()


def read_for(c, seconds):
    c.drain(seconds)
    absorb(c)


def close_properly(c, n):
    """A close frame (1000), as a browser closing the page sends. The
    server reads every open connection, so failing to send 8 bytes means it
    stopped reading or dropped the connection."""
    payload = struct.pack(">H", 1000)
    mask = os.urandom(4)
    try:
        c.sock.sendall(bytes([0x88, 0x80 | len(payload)]) + mask +
                       bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
    except OSError as e:
        stats.add("close_frame_failed")
        stats.problem(f"phone {n}: couldn't send its close frame: {type(e).__name__}: {e}",
                      hang=isinstance(e, TimeoutError))
    c.close()


class World:
    """What the phones pick from: the session's tracks, FX and length."""

    def __init__(self):
        self.fx = reaper(FX_LUA) or []  # [[trackGuid, fxGuid, paramCount], ...]
        self.length = reaper("return reaper.GetProjectLength(0)")
        with Client(timeout=HANG_SECS) as c:
            self.tracks = c.wait_event("trackSkeleton", timeout=HANG_SECS)["payload"]["tracks"]
        self.guids = [t["g"] for t in self.tracks]
        self.with_items = [t["g"] for t in self.tracks if t.get("ic")]
        self.item_tracks = [i for i, t in enumerate(self.tracks) if t.get("ic")]
        html = urllib.request.urlopen(f"http://{HOST}:{PORT}/", timeout=HANG_SECS).read().decode()
        self.assets = re.findall(r'(?:src|href)="(/assets/[^"]+)"', html)


FX_LUA = """
local out = {}
local function add(t, g)
  for f = 0, reaper.TrackFX_GetCount(t) - 1 do
    out[#out + 1] = {g, reaper.TrackFX_GetFXGUID(t, f), reaper.TrackFX_GetNumParams(t, f)}
  end
end
add(reaper.GetMasterTrack(0), "master")
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i)
  add(t, reaper.GetTrackGUID(t))
end
return out
"""


def viewport(rng, world):
    span = rng.choice([4, 15, 60, 240, 900, 3600])
    start = rng.uniform(-span / 4, max(0.0, world.length - span / 2))
    return {"start": start, "end": start + span, "widthPx": rng.randint(320, 1600)}


def track_range(rng, world):
    start = rng.randrange(len(world.guids))
    return {"start": start, "end": min(len(world.guids) - 1, start + rng.randint(0, 63))}


def fx_params(rng, world):
    track, fx, count = rng.choice(world.fx)
    first = rng.randrange(max(1, count))
    return {"trackGuid": track, "fxGuid": fx, "range": {"start": first, "end": first + rng.randint(0, 99)}}


class Phone:
    """One connection's view of what it has subscribed, so it asks only
    what the web UI would: a viewport change needs a peaks subscription."""

    def __init__(self, c):
        self.c = c
        self.peaks = False
        self.streaming = False

    def peaks_subscribe(self, r, world):
        res, _ = run_command(self.c, "peaks/subscribe", range=track_range(r, world), viewport=viewport(r, world))
        self.peaks = bool(res.get("success"))

    def peaks_viewport(self, r, world):
        if not self.peaks:
            return self.peaks_subscribe(r, world)
        run_command(self.c, "peaks/updateViewport", viewport=viewport(r, world))

    def peaks_unsubscribe(self):
        run_command(self.c, "peaks/unsubscribe")
        self.peaks = False

    def stream_start(self):
        if self.streaming or not stats.take_stream_slot():
            return
        res, _ = run_command(self.c, "audio/startStream")
        self.streaming = bool(res.get("success"))
        if not self.streaming:
            stats.give_stream_slot(used=False)

    def stream_stop(self):
        run_command(self.c, "audio/stopStream")
        self.left()

    def left(self):
        if self.streaming:
            self.streaming = False
            stats.give_stream_slot()


# Ops a run leaves out unless SOAK_OPS opts them in with "+<word>", and why.
OPT_IN = {"tuner": "opening and closing the tuner leaves undo points in REAPER (RV1-165)"}


# What a phone does while connected: (relative weight, name, op). Each op
# picks its own parameters; all are reads or subscriptions. SOAK_OPS
# narrows down what a leak or a drift follows, in space-separated words
# matched against op names:
#   (none)   every op but the OPT_IN ones
#   +word    also the OPT_IN ops matching word ("+tuner": every op and the tuner)
#   word     only the ops matching a plain word, plus the +word ones
#            ("peaks +tuner": the peaks ops and the tuner)
#   -word    not the ops matching word, whatever else matched ("-audio")
def phone_ops(world):
    words = os.environ.get("SOAK_OPS", "").split()
    add = [w[1:] for w in words if w.startswith("+")]
    drop = [w[1:] for w in words if w.startswith("-")]
    keep = [w for w in words if w[:1] not in "+-"]

    def opt_in(name):
        return any(name.startswith(prefix) for prefix in OPT_IN)

    def wanted(name):
        if any(w in name for w in drop):
            return False
        if opt_in(name):
            return any(w in name for w in add)
        return not keep or any(w in name for w in keep)

    ops = [op for op in all_phone_ops(world) if wanted(op[1])]
    assert ops, f"SOAK_OPS={words} matches no op (opt-in ops need +: {', '.join(OPT_IN)})"
    return ops


def opted_in(ops):
    """The OPT_IN reasons for the ops this run has."""
    return [why for prefix, why in OPT_IN.items() if any(op[1].startswith(prefix) for op in ops)]


def all_phone_ops(world):
    fx_tracks = sorted({f[0] for f in world.fx})

    def cmd(command, params=lambda r: {}):
        return lambda p, r: run_command(p.c, command, **params(r))

    return [
        (8, "track/subscribe", cmd("track/subscribe", lambda r: {"range": track_range(r, world),
                                                                 "includeMaster": r.random() < 0.5})),
        (3, "track/subscribe", cmd("track/subscribe", lambda r: {
            "guids": r.sample(world.guids, r.randint(1, len(world.guids)))})),
        (2, "track/unsubscribe", cmd("track/unsubscribe")),
        (6, "peaks/subscribe", lambda p, r: p.peaks_subscribe(r, world)),
        (8, "peaks/updateViewport", lambda p, r: p.peaks_viewport(r, world)),
        (1, "peaks/unsubscribe", lambda p, r: p.peaks_unsubscribe()),
        (3, "trackFx/subscribe", cmd("trackFx/subscribe", lambda r: {"trackGuid": r.choice(fx_tracks)})),
        (1, "trackFx/unsubscribe", cmd("trackFx/unsubscribe")),
        (5, "trackFxParams/subscribe", cmd("trackFxParams/subscribe", lambda r: fx_params(r, world))),
        (2, "trackFxParams/unsubscribe", cmd("trackFxParams/unsubscribe")),
        (2, "trackFx/getParams", cmd("trackFx/getParams", lambda r: dict(zip(("trackGuid", "fxGuid"),
                                                                             r.choice(world.fx)[:2])))),
        (2, "track/getFx", cmd("track/getFx", lambda r: {"trackIdx": r.randrange(len(world.guids))})),
        (3, "routing/subscribe", cmd("routing/subscribe", lambda r: {"trackGuid": r.choice(world.guids)})),
        (1, "routing/unsubscribe", cmd("routing/unsubscribe")),
        (2, "tuner/subscribe", cmd("tuner/subscribe", lambda r: {"trackGuid": r.choice(world.with_items)})),
        (2, "tuner/unsubscribe", cmd("tuner/unsubscribe")),
        (1, "audio/startStream", lambda p, r: p.stream_start()),
        (1, "audio/stopStream", lambda p, r: p.stream_stop()),
        (1, "projectNotes/subscribe", cmd("projectNotes/subscribe")),
        (1, "projectNotes/unsubscribe", cmd("projectNotes/unsubscribe")),
        (1, "actionToggleState/subscribe", cmd("actionToggleState/subscribe",
                                               lambda r: {"commandIds": r.sample(TOGGLES, 2)})),
        (1, "actionToggleState/unsubscribe", cmd("actionToggleState/unsubscribe",
                                                 lambda r: {"commandIds": r.sample(TOGGLES, 2)})),
        (2, "item/getTakes", cmd("item/getTakes", lambda r: {"trackIdx": r.choice(world.item_tracks),
                                                             "itemIdx": 0})),
        (1, "lanes/getState", cmd("lanes/getState", lambda r: {"trackGuid": r.choice(world.guids)})),
        (1, "tempo/barsToTime", cmd("tempo/barsToTime", lambda r: {"bar": r.randint(-4, 12)})),
        (1, "transport/seek", cmd("transport/seek", lambda r: {"position": r.uniform(0, world.length)})),
        (1, "fxPlugin/getList", cmd("fxPlugin/getList")),
        (1, "action/getActions", cmd("action/getActions")),  # the largest response (~700 KB)
        (1, "input/enumerateAudio", cmd("input/enumerateAudio")),
        (2, "ping", lambda p, r: p.c.send({"type": "ping", "timestamp": time.time() * 1000})),
        (2, "clockSync", lambda p, r: p.c.send({"type": "clockSync", "t0": time.time() * 1000})),
    ]


def page_load(rng, world):
    """The browser loading the web UI: the page (which carries the token) and an asset."""
    urllib.request.urlopen(f"http://{HOST}:{PORT}/", timeout=HANG_SECS).read()
    if world.assets:
        urllib.request.urlopen(f"http://{HOST}:{PORT}{rng.choice(world.assets)}", timeout=HANG_SECS).read()
    stats.add("page_loads")


def phone(n, world, ops):
    rng = random.Random(SEED * 1000 + n)
    weights = [w for w, _, _ in ops]
    while not stats.stop.is_set():
        c = p = None
        stage = "loading the page"
        try:
            if rng.random() < 0.3:
                page_load(rng, world)
            stage = "connecting"
            c = Client(timeout=HANG_SECS)
            stats.add("connects")
            stage = "waiting for the hello and first state"
            c.wait_event("trackSkeleton", timeout=HANG_SECS)
            stage = "connected"
            p = Phone(c)
            end = time.monotonic() + rng.uniform(2, 20)
            while time.monotonic() < end and not stats.stop.is_set():
                rng.choices(ops, weights)[0][2](p, rng)
                read_for(c, rng.uniform(0.05, 0.8))
            leave = rng.random()
            if leave < 0.4:
                c.close()
                stats.add("left_dropped")
            elif leave < 0.8:
                close_properly(c, n)
                stats.add("left_closed")
            else:
                # A phone put to sleep: the socket stays open, nothing is read.
                stats.stop.wait(rng.uniform(3, 12))
                c.close()
                stats.add("left_quiet")
        except (Hang, TimeoutError) as e:
            stats.problem(f"phone {n}, {stage}: {e}", hang=True)
        except (Closed, ConnectionError, InvalidFrame) as e:
            # A healthy server closes no phone that reads: a close here is a
            # refused or dropped connection (a full slot table, a dead accept
            # loop, a frame it couldn't send).
            stats.add("closed_by_server")
            stats.problem(f"phone {n}, {stage}: the server closed the connection: {type(e).__name__}: {e}")
        except Exception:
            stats.problem(f"phone {n}, {stage}: {traceback.format_exc()}")
        finally:
            if p:
                p.left()
            if c:
                c.close()
        stats.stop.wait(rng.uniform(0, 3))


def desk(world):
    """The phone that stays connected: mixer, timeline and notes open, and
    a main-thread command every 2 s to tell a slow REAPER from a hung one."""
    try:
        with Client(timeout=HANG_SECS) as c:
            c.wait_event("trackSkeleton", timeout=HANG_SECS)
            n = len(world.guids)
            for command, params in [
                ("track/subscribe", {"range": {"start": 0, "end": min(63, n - 1)}, "includeMaster": True}),
                ("peaks/subscribe", {"range": {"start": 0, "end": n - 1},
                                     "viewport": {"start": 0, "end": world.length, "widthPx": 1200}}),
                ("projectNotes/subscribe", {}),
                ("actionToggleState/subscribe", {"commandIds": TOGGLES}),
            ]:
                r, _ = run_command(c, command, **params)
                if not r.get("success"):
                    return  # run_command has reported it
            next_probe = next_ping = time.monotonic()
            while not stats.stop.is_set():
                now = time.monotonic()
                if now >= next_probe:
                    r, ms = run_command(c, "debug/memoryStats")
                    stats.peak("probe_ms_max", ms)
                    if r.get("success"):
                        stats.set_memory(r["payload"])
                    next_probe = now + 2
                if now >= next_ping:
                    c.send({"type": "ping", "timestamp": time.time() * 1000})
                    next_ping = now + 10
                read_for(c, 0.25)
    except (Hang, TimeoutError) as e:
        stats.problem(f"desk: {e}", hang=True)
    except Exception:
        stats.problem(f"desk lost its connection: {traceback.format_exc()}")


def project_changes():
    """What Edit > Undo would undo now, as REAPER names it, and REAPER's
    count of project state changes, which also moves for a change that
    adds no undo point or one named like the last."""
    top, count = reaper("return reaper.Undo_CanUndo2(0) or '', reaper.GetProjectStateChangeCount(0)",
                        timeout=HANG_SECS)
    return {"undo": top, "changes": int(count)}


def reaper_pid():
    r = subprocess.run(["pgrep", "-x", "reaper"], capture_output=True, text=True)
    pids = r.stdout.split()
    return int(pids[0]) if pids else None


class Gone(Exception):
    """The REAPER process has exited (or is a zombie)."""


def proc_state(pid):
    try:
        return open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return "X"


def cpu_ticks(path):
    # Fields after the ")" that ends the command name: utime, stime are 14, 15.
    rest = open(path).read().rsplit(")", 1)[1].split()
    return int(rest[11]) + int(rest[12])


def proc_sample(pid):
    """REAPER's /proc numbers, or Gone once it has exited: a zombie has
    no memory lines and its fd folder can't be listed."""
    if proc_state(pid) in "ZX":
        raise Gone
    try:
        status = {}
        for line in open(f"/proc/{pid}/status"):
            k, _, v = line.partition(":")
            status[k] = v.split()
        return {
            "cpu": cpu_ticks(f"/proc/{pid}/stat"),
            "main_cpu": cpu_ticks(f"/proc/{pid}/task/{pid}/stat"),
            "rss_mb": int(status["VmRSS"][0]) / 1024,
            "rss_anon_mb": int(status["RssAnon"][0]) / 1024,
            "hwm_mb": int(status["VmHWM"][0]) / 1024,
            "threads": int(status["Threads"][0]),
            "fds": len(os.listdir(f"/proc/{pid}/fd")),
        }
    except (OSError, KeyError, IndexError, ValueError):
        raise Gone from None


def mapping_rss(pid):
    """RSS in MB by what backs it: a file (a library), [heap] (the main
    malloc arena), [stack], or "anonymous" (other malloc arenas, mmapped
    allocations, thread stacks). Where growth lands says whose memory it is."""
    out, name = {}, None
    for line in open(f"/proc/{pid}/smaps"):
        parts = line.split()
        if re.match(r"^[0-9a-f]+-[0-9a-f]+ ", line):
            name = os.path.basename(parts[5]) if len(parts) > 5 else "anonymous"
        elif parts[0] == "Rss:":
            out[name] = out.get(name, 0) + int(parts[1]) / 1024
    return out


def try_mapping_rss(pid):
    try:
        return mapping_rss(pid)
    except (OSError, ValueError, IndexError):
        return None


def mapping_growth(before, after):
    """MB grown by mapping, largest change first, changes under 0.1 MB left out."""
    grown = {k: after.get(k, 0) - before.get(k, 0) for k in set(before) | set(after)}
    return {k: round(v, 2) for k, v in sorted(grown.items(), key=lambda kv: -abs(kv[1])) if abs(v) >= 0.1}


def thread_ticks(pid):
    """{tid: (name, CPU ticks)} for REAPER's threads now, or Gone once
    REAPER has exited. A thread that exits between the listing and the read
    is left out."""
    out = {}
    try:
        tids = os.listdir(f"/proc/{pid}/task")
    except OSError:
        raise Gone from None
    for tid in tids:
        try:
            stat = open(f"/proc/{pid}/task/{tid}/stat").read()
            name = stat[stat.index("(") + 1:stat.rindex(")")]
            rest = stat.rsplit(")", 1)[1].split()
            out[int(tid)] = (name, int(rest[11]) + int(rest[12]))
        except (OSError, ValueError, IndexError):
            continue
    return out


def thread_group(pid, tid, name):
    """REAPER names its own threads ("reaper/audio_dm", "reaper/mediaafx",
    ...). A thread nobody names keeps the name of the thread that created
    it, which for REAmo's threads (its HTTP and WebSocket server threads,
    the audio stream's network thread) is "reaper", the main thread's
    name. So a non-main thread named "reaper" is "unnamed". That these are
    REAmo's is what the harness runs show, not a guarantee: REAPER 7.83
    without REAmo ran none. A thread REAmo starts from a named thread
    would carry that thread's name instead."""
    if tid == pid:
        return "main"
    return "unnamed" if name == "reaper" else name


def thread_cpu(pid, before, after, dt):
    """[(tid, name, group, CPU %)] over dt for the threads alive at the end
    that used CPU. A thread born in the window counts all its ticks."""
    out = []
    for tid, (name, ticks) in after.items():
        used = ticks - before.get(tid, (name, 0))[1]
        if used > 0:
            out.append((tid, name, thread_group(pid, tid, name), round(used / CLK_TCK / dt * 100, 2)))
    return out


THREAD_COLUMNS = ["t_s", "tid", "name", "group", "cpu_pct"]
# CPU that the process used in a sample but no thread alive at its end
# did: threads that exited during the sample (the process keeps their
# time). Its row has no tid. The two reads are moments apart, so it can be
# a tick off either way, even slightly negative.
EXITED = "exited during sample"


def group_threads(pid, threads):
    """{group: thread count} of a thread_ticks() result."""
    out = {}
    for tid, (name, _) in threads.items():
        g = thread_group(pid, tid, name)
        out[g] = out.get(g, 0) + 1
    return out


COLUMNS = ["t_s", "rss_mb", "rss_anon_mb", "hwm_mb", "threads", "fds", "cpu_pct", "main_cpu_pct",
           "ext_frames", "probe_ms_max", "rpc_ms", "cmd_ms_max", "connects", "commands", "cmd_refused",
           "events", "peaks_frames", "audio_frames", "page_loads", "closed_by_server", "playing"]


def fit_slope(xs, ys):
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0


def analyse_threads(run):
    """CPU by thread group and the busiest threads, after warm-up: mean,
    and the last third's mean minus the first's (as cpu_drift_points)."""
    post = [(t, cpu) for t, cpu in run.thread_rows if t >= WARMUP_MINUTES * 60]
    if len(post) < 6:
        return {}
    third = len(post) // 3

    def series(key):
        return [sum(pct for k, pct in cpu if key(k)) for _, cpu in post]

    def summary(vals):
        return {"mean": round(statistics.fmean(vals), 2),
                "drift_points": round(statistics.fmean(vals[-third:]) - statistics.fmean(vals[:third]), 2)}

    groups = sorted({k[2] for _, cpu in post for k, _ in cpu})
    by_group = {g: summary(series(lambda k, g=g: k[2] == g)) for g in groups}
    threads = {k for _, cpu in post for k, _ in cpu if k[2] != EXITED}
    busiest = sorted(((k, summary(series(lambda x, k=k: x == k))) for k in threads),
                     key=lambda kv: -kv[1]["mean"])[:6]
    return {"cpu_pct_by_thread_group": by_group,
            "busiest_threads": [{"tid": k[0], "name": k[1], "group": k[2], **v} for k, v in busiest]}


def analyse(rows):
    post = [r for r in rows if r["t_s"] >= WARMUP_MINUTES * 60]
    out = {"samples": len(rows), "post_warmup_samples": len(post)}
    if rows:
        out["rss_mb_first"] = rows[0]["rss_mb"]
        out["rss_mb_last"] = rows[-1]["rss_mb"]
        out["rss_mb_max"] = max(r["rss_mb"] for r in rows)
        out["probe_ms_max"] = max(r["probe_ms_max"] for r in rows)
        out["rpc_ms_max"] = max(r["rpc_ms"] for r in rows)
    if len(post) < 6:
        return out
    k = max(3, len(post) // 10)

    def growth(key):
        vals = [r[key] for r in post]
        return statistics.median(vals[-k:]) - statistics.median(vals[:k])

    hours = [r["t_s"] / 3600 for r in post]
    rss = [r["rss_mb"] for r in post]
    cpu = [r["cpu_pct"] for r in post]
    third = len(post) // 3
    out.update({
        "post_warmup_minutes": (post[-1]["t_s"] - post[0]["t_s"]) / 60,
        "rss_mb_post_warmup_start": statistics.median(rss[:k]),
        "rss_mb_end": statistics.median(rss[-k:]),
        "rss_growth_mb": growth("rss_mb"),
        "rss_slope_mb_per_hour": fit_slope(hours, rss),
        "rss_anon_slope_mb_per_hour": fit_slope(hours, [r["rss_anon_mb"] for r in post]),
        "cpu_pct_mean": statistics.fmean(cpu),
        "cpu_pct_max": max(cpu),
        "cpu_slope_points_per_hour": fit_slope(hours, cpu),
        "cpu_drift_points": statistics.fmean(cpu[-third:]) - statistics.fmean(cpu[:third]),
        "main_cpu_pct_mean": statistics.fmean(r["main_cpu_pct"] for r in post),
        "thread_growth": growth("threads"),
        "fd_growth": growth("fds"),
        "threads_range": [min(r["threads"] for r in post), max(r["threads"] for r in post)],
        "fds_range": [min(r["fds"] for r in post), max(r["fds"] for r in post)],
    })
    return out


def slope_checked():
    """Whether this run is long enough for the slope and drift checks: set
    by its settings, not by how many samples it got."""
    return (WARMUP_MINUTES >= LIMITS["SLOPE_MIN_WARMUP_MINUTES"]
            and MINUTES - WARMUP_MINUTES >= LIMITS["SLOPE_MIN_MINUTES"])


def verdict(m, totals):
    """The limits this run broke."""
    broken = []
    if "rss_growth_mb" not in m:
        broken.append(f"too few samples after warm-up ({m.get('post_warmup_samples', 0)}) to judge memory")
        return broken
    L = LIMITS
    if m["rss_growth_mb"] > L["RSS_GROWTH_MB"]:
        broken.append(f"RSS grew {m['rss_growth_mb']:.1f} MB after warm-up (limit {L['RSS_GROWTH_MB']:g})")
    if m["thread_growth"] > L["THREAD_GROWTH"]:
        broken.append(f"threads grew by {m['thread_growth']:g} (limit {L['THREAD_GROWTH']:g})")
    if m["fd_growth"] > L["FD_GROWTH"]:
        broken.append(f"open files grew by {m['fd_growth']:g} (limit {L['FD_GROWTH']:g})")
    if not CONTROL:
        commands = totals.get("commands", 0)
        refused_pct = 100 * totals.get("cmd_refused", 0) / commands if commands else 0.0
        m["refused_pct"] = refused_pct
        if refused_pct > L["REFUSAL_PCT"]:
            broken.append(f"{refused_pct:.2f} % of commands refused (limit {L['REFUSAL_PCT']:g} %)")
        if not totals.get("connects") and PHONES:
            broken.append("no phone connected")
    m["slope_checked"] = slope_checked()
    if m["slope_checked"]:
        if m["rss_slope_mb_per_hour"] > L["RSS_SLOPE_MB_PER_HOUR"]:
            broken.append(f"RSS rising {m['rss_slope_mb_per_hour']:.1f} MB/h after warm-up "
                          f"(limit {L['RSS_SLOPE_MB_PER_HOUR']:g})")
        if m["cpu_drift_points"] > L["CPU_DRIFT_POINTS"]:
            broken.append(f"CPU drifted up {m['cpu_drift_points']:.1f} points (limit {L['CPU_DRIFT_POINTS']:g})")
    return broken


class Run:
    """What the run has gathered, for the summary whatever way it ends."""

    def __init__(self):
        self.rows = []
        self.pid = None
        self.undo_before = None
        self.maps_warm = None
        self.maps_end = None
        self.threads = []
        self.ops = []
        self.thread_rows = []  # (t_s, [((tid, name, group), CPU %), ...]) per sample
        self.thread_groups = {}  # {group: threads} at the start of sampling
        self.started = time.time()
        self.stopped_early = None  # why the control stopped before SOAK_MINUTES


def soak(run):
    # Which REAPER this is comes first, before a phone connects: REAmo must
    # be loaded in the soak and not in the control.
    run.pid = pid = reaper_pid()
    if not pid:
        raise RuntimeError("no REAPER process")
    maps = try_mapping_rss(pid)
    if maps is None:
        stats.problem("couldn't read REAPER's mappings (/proc/<pid>/smaps)", setup=True)
        return
    loaded = "reaper_reamo.so" in maps
    if loaded == CONTROL:
        stats.problem(f"REAmo is {'loaded' if loaded else 'not loaded'} in REAPER, "
                      f"and this is {'the control' if CONTROL else 'the soak'}", setup=True)
        return
    print("dialogs:", open_project("/tmp/corpus/band-session/band-session.RPP"), flush=True)
    time.sleep(1.5)  # the extension's GUID cache settles after a project load
    if not CONTROL:
        world = World()
        run.ops = phone_ops(world)
        print(f"session: {len(world.guids)} tracks, {len(world.fx)} FX, {world.length:.1f} s; "
              f"assets {world.assets}; {len(run.ops)} ops", flush=True)
    reaper("""
      reaper.GetSet_LoopTimeRange(true, true, 0, reaper.GetProjectLength(0), false)
      reaper.GetSetRepeat(1)
      reaper.OnPlayButton()
    """)
    # The baseline follows the test's own setup (the loop range, repeat, play).
    time.sleep(0.5)
    run.undo_before = project_changes()

    if not CONTROL:
        run.threads = [threading.Thread(target=desk, args=(world,), name="desk", daemon=True)]
        run.threads += [threading.Thread(target=phone, args=(n, world, run.ops), name=f"phone {n}",
                                         daemon=True) for n in range(PHONES)]
    for t in run.threads:
        t.start()

    with open(os.path.join(OUT, "soak-series.csv"), "w", newline="") as csv_file, \
            open(os.path.join(OUT, "soak-threads.csv"), "w", newline="") as threads_file:
        writer = csv.DictWriter(csv_file, COLUMNS)
        writer.writeheader()
        thread_writer = csv.writer(threads_file)
        thread_writer.writerow(THREAD_COLUMNS)
        start = time.monotonic()
        try:
            prev, prev_t = proc_sample(pid), start
            prev_threads = thread_ticks(pid)
        except Gone:
            stats.problem("REAPER exited before the first sample")
            return
        run.thread_groups = group_threads(pid, prev_threads)
        playing, rpc_ms = 1, 0.0
        next_rpc = start + RPC_SECS
        while not stats.stop.wait(max(0.0, prev_t + SAMPLE_SECS - time.monotonic())):
            if WITH_SOAK and this_run(SOAK, SOAK_DONE):
                run.stopped_early = f"the soak ended {(time.monotonic() - start) / 60:.1f} min in"
                print(f"control: {run.stopped_early}, so it stops too", flush=True)
                return
            now = time.monotonic()
            try:
                cur = proc_sample(pid)
                cur_threads = thread_ticks(pid)
            except Gone:
                stats.problem(f"REAPER exited {(now - start) / 60:.1f} min in")
                return
            if now >= next_rpc:
                # The Lua side of the harness runs on REAPER's main thread too.
                t0 = time.monotonic()
                try:
                    state = reaper("return reaper.GetPlayState()", timeout=HANG_SECS)
                except TimeoutError as e:
                    stats.problem(f"REAPER's main thread didn't run a script: {e}", hang=True)
                    return
                except ReaperError as e:
                    stats.problem(f"reaper.GetPlayState() raised: {e}")
                    return
                rpc_ms = (time.monotonic() - t0) * 1000
                playing = int(state) & 1
                if not playing:
                    stats.problem(f"the transport stopped playing (play state {state})")
                next_rpc = now + RPC_SECS
            dt = now - prev_t
            w = stats.take_window()
            per_thread = thread_cpu(pid, prev_threads, cur_threads, dt)
            row = {
                "t_s": round(now - start, 1),
                "rss_mb": round(cur["rss_mb"], 2), "rss_anon_mb": round(cur["rss_anon_mb"], 2),
                "hwm_mb": round(cur["hwm_mb"], 2), "threads": cur["threads"], "fds": cur["fds"],
                "cpu_pct": round((cur["cpu"] - prev["cpu"]) / CLK_TCK / dt * 100, 2),
                "main_cpu_pct": round((cur["main_cpu"] - prev["main_cpu"]) / CLK_TCK / dt * 100, 2),
                "ext_frames": stats.get_memory().get("frameCount", 0),
                "rpc_ms": round(rpc_ms, 1), "playing": playing,
            }
            for k in ["probe_ms_max", "cmd_ms_max", "connects", "commands", "cmd_refused", "events",
                      "peaks_frames", "audio_frames", "page_loads", "closed_by_server"]:
                row[k] = round(w.get(k, 0), 1)
            if run.maps_warm is None and row["t_s"] >= WARMUP_MINUTES * 60:
                run.maps_warm = try_mapping_rss(pid)
            run.rows.append(row)
            writer.writerow(row)
            csv_file.flush()
            rest = round(row["cpu_pct"] - sum(t[3] for t in per_thread), 2)
            if rest:
                per_thread.append(("", EXITED, EXITED, rest))
            run.thread_rows.append((row["t_s"], [((tid, name, group), pct) for tid, name, group, pct in per_thread]))
            thread_writer.writerows([row["t_s"], *t] for t in per_thread)
            threads_file.flush()
            prev, prev_t, prev_threads = cur, now, cur_threads
            if now - start >= MINUTES * 60:
                return
            if len(run.rows) % max(1, int(60 / SAMPLE_SECS)) == 0:
                print(f"{row['t_s'] / 60:5.1f} min: rss {row['rss_mb']:.1f} MB, cpu {row['cpu_pct']:.1f}%, "
                      f"main {row['main_cpu_pct']:.1f}%, threads {row['threads']}, fds {row['fds']}, "
                      f"connects {stats.total.get('connects', 0)}, commands {stats.total.get('commands', 0)}",
                      flush=True)


def finish(run):
    """Stop the phones, check what can still be checked, write the summary
    and return the failures."""
    if not CONTROL:
        mark(SOAK_DONE)  # the control stops when it sees this
    if run.pid:
        run.maps_end = try_mapping_rss(run.pid)
    stats.stop.set()
    deadline = time.monotonic() + HANG_SECS + 5
    for t in run.threads:
        t.join(timeout=max(0.0, deadline - time.monotonic()))
    stuck = [t.name for t in run.threads if t.is_alive()]
    if stuck:
        stats.problems.append(f"still running {HANG_SECS + 5:.0f} s after the run ended: {', '.join(stuck)}")

    alive = bool(run.pid) and proc_state(run.pid) not in "ZX"
    if run.pid and not alive and not any("exited" in p for p in stats.problems):
        stats.problems.append("REAPER exited")
    # undo_top() runs on REAPER's main thread: after a hang it would only
    # wait out its timeout.
    if alive and not stats.hung and run.undo_before is not None:
        try:
            before, after = run.undo_before, project_changes()
            why = "; ".join(opted_in(run.ops))
            why = f"; expected: {why}" if why else ""
            who = "the run" if CONTROL else "the phones"
            if after["undo"] != before["undo"]:
                stats.problems.append(f"{who} left undo points in REAPER: the last is now "
                                      f"{after['undo']!r} (was {before['undo']!r}){why}")
            elif after["changes"] != before["changes"]:
                stats.problems.append(f"{who} changed the project: REAPER counted "
                                      f"{after['changes'] - before['changes']} state changes{why}")
        except (TimeoutError, ReaperError) as e:
            stats.problems.append(f"couldn't read REAPER's undo history after the run: {e}")

    metrics = analyse(run.rows)
    broken = verdict(metrics, stats.total) if alive and not stats.problems else []
    if run.maps_warm and run.maps_end:
        metrics["rss_growth_mb_by_mapping"] = mapping_growth(run.maps_warm, run.maps_end)
    metrics.update(analyse_threads(run))
    metrics["threads_by_group_at_start"] = run.thread_groups
    summary = {"role": "control" if CONTROL else "soak", "run_id": RUN_ID,
               "config": {"minutes": MINUTES, "warmup_minutes": WARMUP_MINUTES,
                          "sample_secs": SAMPLE_SECS, "cpus": os.cpu_count(),
                          **({} if CONTROL else {"phones": PHONES, "seed": SEED,
                                                 "ops": os.environ.get("SOAK_OPS", ""),
                                                 "opted_in": opted_in(run.ops)})},
               "limits": LIMITS, "metrics": metrics, "totals": stats.total,
               "refusals": stats.refusals, "extension_memory": stats.get_memory(),
               "problems": stats.problems, "limits_broken": broken,
               "started": run.started, "ended": time.time()}
    if CONTROL:
        summary["stopped_early"] = run.stopped_early
    path = os.path.join(OUT, "soak-summary.json")
    failed = stats.problems + broken
    if not CONTROL:
        # The summary is written before any wait for the control, so a
        # crash during the wait still leaves it.
        summary["baseline"] = {"status": "waiting for the control" if WITH_BASELINE and not failed
                               else "not compared"}
        write_json(path, summary)
        summary["baseline"] = against_baseline(metrics, run, failed)
        if WITH_BASELINE:
            # A failure's replay line (results.sh) runs the control too, and
            # the control's out dirs from this run are kept with the failure.
            with open(os.path.join(OUT, "replay-with"), "w") as f:
                f.write("".join(f"{BASELINE} {d}\n" for d, _ in this_run(BASELINE, CONTROL_STARTED))
                        or f"{BASELINE}\n")
    write_json(path, summary)
    print(json.dumps({"metrics": metrics, "totals": stats.total}, indent=2))
    print("refusals:", json.dumps(stats.refusals, indent=2, sort_keys=True))
    if not CONTROL:
        print_baseline(summary["baseline"])
    return failed


# What the soak compares with the control.
COMPARED = ["rss_mb_post_warmup_start", "rss_growth_mb", "rss_slope_mb_per_hour", "rss_anon_slope_mb_per_hour",
            "cpu_pct_mean", "cpu_drift_points", "main_cpu_pct_mean", "thread_growth", "fd_growth"]


def read_baseline(run):
    """(out dir, summary) of the control that ran beside this soak,
    waiting up to BASELINE_WAIT_SECS for its summary, or (None, why there
    is none). With more than one, the first that overlapped this soak."""
    if not WITH_BASELINE:
        return None, f"not in this run (make soak runs {BASELINE} beside it)"
    started = [d for d, _ in this_run(BASELINE, CONTROL_STARTED)]
    if not started:
        return None, (f"{BASELINE} hadn't started by the end of this soak: run.sh starts scenarios in the "
                      f"order named, HARNESS_JOBS at a time, so it runs alongside only if named first or "
                      f"with HARNESS_JOBS of 2 or more (make soak does both)")
    deadline = time.monotonic() + BASELINE_WAIT_SECS
    while True:
        done = this_run(BASELINE, "soak-summary.json")
        if len(done) == len(started) or time.monotonic() > deadline:
            break
        time.sleep(1)
    if not done:
        return None, f"{BASELINE} wrote no summary within {BASELINE_WAIT_SECS:.0f} s of this soak's end"
    beside = [(d, b) for d, b in done if b.get("ended", 0) > run.started]
    if not beside:
        return None, (f"{BASELINE} ended before this soak started, so it ran before it, not beside it "
                      f"(HARNESS_JOBS=1?)")
    return beside, None


def against_baseline(m, run, failed):
    """This run's numbers beside the control's, and the difference: what
    the phones and REAmo add to REAPER alone. Reported, not judged: the
    limits apply to this run's own numbers. A soak that failed isn't
    compared: its numbers stop wherever it failed."""
    if failed:
        return {"status": "not compared: this soak failed"}
    beside, why = read_baseline(run)
    if beside is None:
        return {"status": why}
    out_dir, b = beside[0]
    if len(beside) > 1:
        print(f"against {out_dir}, the first of {', '.join(d for d, _ in beside)}", flush=True)
    bm = b["metrics"]

    def pair(x, y):
        out = {"soak": x, "baseline": y}
        if isinstance(x, (int, float)) and isinstance(y, (int, float)):
            out["difference"] = round(x - y, 3)
        return out

    mine, theirs = m.get("rss_growth_mb_by_mapping"), bm.get("rss_growth_mb_by_mapping")
    by_mapping = {}
    if mine is not None and theirs is not None:
        by_mapping = {k: pair(mine.get(k, 0.0), theirs.get(k, 0.0))
                      for k in sorted(set(mine) | set(theirs),
                                      key=lambda k: -abs(mine.get(k, 0.0) - theirs.get(k, 0.0)))}
    groups_m, groups_b = m.get("cpu_pct_by_thread_group", {}), bm.get("cpu_pct_by_thread_group", {})
    status = (f"compared with {out_dir}" if not b["problems"] and not b["limits_broken"]
              else f"compared with {out_dir}, but it reported problems: its numbers may not be a fair baseline")
    if b.get("stopped_early"):
        status += f"; it stopped early ({b['stopped_early']})"
    return {
        "status": status,
        "control_out_dirs": [d for d, _ in beside],
        "problems": b["problems"] + b["limits_broken"],
        "metrics": {k: pair(m.get(k), bm.get(k)) for k in COMPARED if k in m or k in bm},
        "rss_growth_mb_by_mapping": by_mapping,
        "cpu_pct_by_thread_group": {g: {"soak": groups_m.get(g), "baseline": groups_b.get(g)}
                                    for g in sorted(set(groups_m) | set(groups_b))},
        "threads_by_group_at_start": pair(m.get("threads_by_group_at_start"), bm.get("threads_by_group_at_start")),
    }


def print_baseline(cmp):
    print(f"against the control (REAPER without REAmo): {cmp['status']}")
    if "metrics" not in cmp:
        return
    for p in cmp["problems"]:
        print(f"  control: {p}")
    print(f"  {'':28} {'soak':>10} {'control':>10} {'difference':>10}")

    def num(v):
        return f"{v:10.2f}" if isinstance(v, (int, float)) else f"{'-':>10}"

    for k, v in cmp["metrics"].items():
        print(f"  {k:28} {num(v['soak'])} {num(v['baseline'])} {num(v.get('difference'))}")
    for k, v in list(cmp["rss_growth_mb_by_mapping"].items())[:6]:
        print(f"  {'MB grown, ' + k:28} {num(v['soak'])} {num(v['baseline'])} {num(v.get('difference'))}")
    for g, v in cmp["cpu_pct_by_thread_group"].items():
        s_, b_ = v["soak"] or {}, v["baseline"] or {}
        print(f"  {'CPU %, ' + g:28} {num(s_.get('mean'))} {num(b_.get('mean'))}   "
              f"drift {num(s_.get('drift_points')).strip()} / {num(b_.get('drift_points')).strip()}")


def main():
    load = ("REAPER without REAmo, no phones (the control)" if CONTROL else
            f"{PHONES} phones + the desk, seed {SEED}, ops {os.environ.get('SOAK_OPS') or 'default'}")
    print(f"soak: {MINUTES:g} min, warm-up {WARMUP_MINUTES:g} min, {load}, sample every {SAMPLE_SECS:g} s, "
          f"slope and drift {'checked' if slope_checked() else 'not checked (run too short)'}", flush=True)
    run = Run()
    if CONTROL:
        mark(CONTROL_STARTED)
    if not CONTROL:
        # A failure's replay line (results.sh) sets the seed this run used.
        with open(os.path.join(OUT, "replay.env"), "w") as f:
            f.write(f"SOAK_SEED={SEED}\n")
    if SETTING_ERRORS:
        for e in SETTING_ERRORS:
            stats.problem(f"bad setting: {e}", setup=True)
    elif MINUTES < MIN_MINUTES:
        stats.problem(f"SOAK_MINUTES={MINUTES:g}: a soak needs at least {MIN_MINUTES:g} minutes, "
                      f"to leave samples after warm-up", setup=True)
    else:
        try:
            soak(run)
        except Exception:
            stats.problem(f"the soak stopped: {traceback.format_exc()}", setup=True)
    failures = finish(run)
    if CONTROL:
        # The control gives numbers to compare with; what it finds is
        # reported in its summary, and only a broken setup fails it.
        if failures:
            print("control reported (not judged):\n  " + "\n  ".join(failures), flush=True)
        if stats.setup_problems:
            print("FAIL (the control's setup):\n  " + "\n  ".join(stats.setup_problems), flush=True)
            sys.exit(1)
        print("control done", flush=True)
        return
    if failures:
        print("FAIL:\n  " + "\n  ".join(failures), flush=True)
        sys.exit(1)
    print("soak passed", flush=True)


main()
