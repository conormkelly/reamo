"""Transport changes made in REAPER itself reach every connected client promptly.

Two phones are connected. The engineer presses play, pause, stop, moves the
cursor, sets a time selection, changes tempo and toggles repeat in REAPER.
Each change must show up on both clients, with REAPER's values, within a
few polling ticks (transport is polled at 30 Hz, the project event at 5 Hz).
"""
import time

from reamo_client import Client, reaper

STEPS = [
    # (what the user does in REAPER, event, predicate on payload, deadline s)
    ("reaper.OnPlayButton()", "transport", lambda p: p["playState"] == 1, 0.5),
    ("reaper.OnPauseButton()", "transport", lambda p: p["playState"] == 2, 0.5),
    ("reaper.OnStopButton()", "transport", lambda p: p["playState"] == 0, 0.5),
    ("reaper.SetEditCurPos(12.25, true, false)", "transport", lambda p: abs(p["cursorPosition"] - 12.25) < 1e-3 and p["positionBeats"] == LABEL_12_25, 0.5),
    ("reaper.GetSet_LoopTimeRange(true, false, 4, 8, false)", "transport", lambda p: p["timeSelection"] == {"start": 4, "end": 8}, 0.5),
    ("reaper.SetCurrentBPM(0, 96.5, true)", "transport", lambda p: abs(p["bpm"] - 96.5) < 0.01, 0.5),
    ("reaper.GetSetRepeat(1)", "project", lambda p: p["repeat"] is True, 1.0),
    ("reaper.Main_OnCommand(40044, 0)", "transport", lambda p: p["playState"] == 1, 0.5),  # Transport: Play/stop
    ("reaper.Main_OnCommand(40044, 0)", "transport", lambda p: p["playState"] == 0, 0.5),
    ("reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)", "transport", lambda p: p["timeSelection"] == {"start": 0, "end": 0}, 0.5),
    ("reaper.GetSetRepeat(0)", "project", lambda p: p["repeat"] is False, 1.0),
]


def latest(c, event):
    """Latest payload, counting 'tt' ticks as transport position updates."""
    ev = c.latest_event(event)
    return ev["payload"] if ev else None


LABEL_12_25 = reaper('return reaper.format_timestr_pos(12.25, "", 2)')

with Client() as a, Client() as b:
    for c in (a, b):
        c.wait_event("transport")
        c.wait_event("project")
    problems = []
    for lua, event, pred, limit in STEPS:
        t0 = time.time()
        reaper(lua)
        seen = {}
        while time.time() - t0 < 3 and len(seen) < 2:
            for name, c in (("A", a), ("B", b)):
                if name not in seen:
                    c.drain(0.02)
                    p = latest(c, event)
                    if p and pred(p):
                        seen[name] = time.time() - t0
        print(f"  {lua:55s} -> " + ", ".join(f"{n} {seen[n] * 1000:.0f} ms" if n in seen else f"{n} never" for n in "AB"))
        for n, c in (("A", a), ("B", b)):
            if n not in seen:
                problems.append(f"{lua}: client {n} never saw it; last {event}: {latest(c, event)}")
            elif seen[n] > limit:
                problems.append(f"{lua}: client {n} took {seen[n]:.2f} s (> {limit} s)")
    assert not problems, "\n".join(problems)
