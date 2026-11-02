"""A phone on the tuner, for the tuner scenarios: what its `tuner` events
say, read as they arrive.

The extension sends a tuner event only when it differs from the last one
sent to that phone, so a state that holds is sent once. `Phone` keeps the
latest payload (`last`) and every payload since `mark()` (`since`), so a
wait for a state already reached returns at once.
"""
import math
import time

A4 = 440.0


def midi_note(freq, ref=A4):
    return round(69 + 12 * math.log2(freq / ref))


def cents_off(freq, want):
    return 1200 * math.log2(freq / want)


class Phone:
    def __init__(self, client, name):
        self.c = client
        self.name = name
        self.last = None
        self.since = []
        self.all = []

    def subscribe(self, guid):
        r = self.c.command("tuner/subscribe", trackGuid=guid)
        if r.get("success"):
            self.last = None
        return r

    def pump(self, seconds=0.05):
        """Read for `seconds`, keeping the tuner events."""
        self.c.drain(seconds)
        for name, msg in self.c.events:
            if name == "tuner":
                self.last = msg["payload"]
                self.since.append(self.last)
                self.all.append(self.last)
        # Other events aren't kept, so a long run doesn't hold them all;
        # tunerError is, for the scenario to wait on.
        self.c.events[:] = [(n, m) for n, m in self.c.events if n == "tunerError"]

    def mark(self):
        """Start a new `since`."""
        self.pump(0)
        self.since = []

    def wait(self, ok, timeout, what):
        """The first payload, the latest included, for which ok(payload) is true."""
        deadline = time.time() + timeout
        if self.last is not None and ok(self.last):
            return self.last
        while time.time() < deadline:
            before = len(self.since)
            self.pump(0.05)
            for p in self.since[before:]:
                if ok(p):
                    return p
        raise AssertionError(f"{self.name}: no {what} within {timeout} s; last event: {self.last}")

    def wait_state(self, state, timeout=5.0, code=None):
        return self.wait(lambda p: p.get("state") == state and (code is None or p.get("code") == code),
                         timeout, f"state {state}" + (f" ({code})" if code else ""))

    def pitched(self):
        """The payloads since mark() that show a pitch."""
        return [p for p in self.since if p["freq"] > 0]


def watch(phones, seconds):
    """Read every phone for `seconds`, in turn."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        for p in phones:
            p.pump(0.02)


def check_note(phone, freq, problems, min_readings=5, max_cents=1.0, never=(), alone=False):
    """Since mark(): every stable reading (the reading to tune by) names the
    note of `freq` within `max_cents`, and no reading at all names a note in
    `never` (another input's, for crosstalk); with `alone`, no reading is
    flagged `multiple` (the analyser hearing several notes). An unstable reading of some
    other note is reported, not failed: jackd runs here without realtime
    scheduling, and a 256-sample block it drops (an xrun) is a gap in the
    input that the analyser can briefly read as another note, as it does on
    a plucked E1 (F1, or around 22 Hz; never stable). On clean input it
    doesn't. Problems are appended."""
    got = phone.pitched()
    want = midi_note(freq)
    stable = [p for p in got if p.get("stable")]
    wrong = [p for p in stable if p["note"] != want]
    stray = [(p["note"], p["freq"]) for p in got if p["note"] != want and not p.get("stable")]
    heard = [(p["note"], p["freq"]) for p in got if p["note"] in never]
    several = [(p["note"], p["freq"]) for p in phone.since if p.get("multiple")] if alone else []
    off = [round(cents_off(p["freq"], freq), 2) for p in stable if abs(cents_off(p["freq"], freq)) > max_cents]
    print(f"{phone.name}: {len(got)} pitched readings, {len(stable)} stable, notes "
          f"{sorted({p['note'] for p in got})} (want {want}), stable cents off "
          f"{[round(cents_off(p['freq'], freq), 2) for p in stable][:8]}")
    if len(got) < min_readings:
        problems.append(f"{phone.name}: {len(got)} pitched readings of {freq:.2f} Hz, want at least {min_readings}")
    if stray:
        print(f"{phone.name}: unstable readings of another note (not failed): {stray[:5]}")
    if wrong:
        problems.append(f"{phone.name}: {len(wrong)} stable readings of another note than {want}: "
                        f"{[(p['note'], p['freq']) for p in wrong[:5]]}")
    if heard:
        problems.append(f"{phone.name}: readings of another input's note {list(never)}: {heard[:5]}")
    if several:
        problems.append(f"{phone.name}: {len(several)} readings flagged multiple, hearing more than its own: {several[:5]}")
    if not stable:
        problems.append(f"{phone.name}: no stable reading of {freq:.2f} Hz")
    if off:
        problems.append(f"{phone.name}: stable readings more than {max_cents} cent off {freq:.2f} Hz: {off[:5]}")
