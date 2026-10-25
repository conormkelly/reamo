"""Repeat and time-selection commands do in REAPER what the buttons say, and events follow.

Loop a section from the phone: set a selection, jump to its start and end,
set start/end at the cursor, clear it, and turn repeat on and off. REAPER's
own state (GetSet_LoopTimeRange, GetSetRepeat, cursor) is the oracle.
"""
import time

from reamo_client import Client, reaper

SEL = "local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false); return {s, e}"
CUR = "return reaper.GetCursorPosition()"


def settle(c, lua, want, label, problems):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        got = reaper(lua)
        if got == want or time.time() > deadline:
            break
    tp = c.latest_event("transport")["payload"]
    print(f"  {label:34s} REAPER {got}; event sel {tp['timeSelection']} cursor {tp['cursorPosition']}")
    if got != want:
        problems.append(f"{label}: REAPER {got}, want {want}")
    return tp


with Client() as c:
    c.wait_event("transport")
    problems = []
    c.fire("timeSelection/set", start=4, end=12.5)
    tp = settle(c, SEL, [4, 12.5], "timeSelection/set 4..12.5", problems)
    c.fire("timeSelection/goStart")
    settle(c, CUR, 4, "timeSelection/goStart", problems)
    c.fire("timeSelection/goEnd")
    tp = settle(c, CUR, 12.5, "timeSelection/goEnd", problems)
    if tp["timeSelection"] != {"start": 4, "end": 12.5} or tp["cursorPosition"] != 12.5:
        problems.append(f"transport event after goEnd: {tp}")
    c.fire("transport/seek", position=2)
    settle(c, CUR, 2, "seek 2", problems)
    c.fire("timeSelection/setStartAtCursor")
    settle(c, SEL, [2, 12.5], "setStartAtCursor", problems)
    c.fire("transport/seek", position=20)
    settle(c, CUR, 20, "seek 20", problems)
    c.fire("timeSelection/setEndAtCursor")
    settle(c, SEL, [2, 20], "setEndAtCursor", problems)

    for bad in ({"start": 8, "end": 4}, {"start": -1, "end": 4}):
        r = c.command("timeSelection/set", **bad)
        print(f"  timeSelection/set {bad} -> {r.get('error')}")
        if r["success"]:
            problems.append(f"timeSelection/set {bad} accepted")
    settle(c, SEL, [2, 20], "selection unchanged by bad sets", problems)

    c.fire("repeat/set", enabled=1)
    settle(c, "return reaper.GetSetRepeat(-1)", 1, "repeat/set 1", problems)
    c.fire("repeat/toggle")
    settle(c, "return reaper.GetSetRepeat(-1)", 0, "repeat/toggle", problems)
    c.fire("repeat/toggle")
    settle(c, "return reaper.GetSetRepeat(-1)", 1, "repeat/toggle again", problems)
    deadline = time.time() + 2
    while c.latest_event("project")["payload"]["repeat"] is not True and time.time() < deadline:
        c.drain(0.2)
    if c.latest_event("project")["payload"]["repeat"] is not True:
        problems.append("project event never showed repeat on")

    # Loop playback inside the selection: the play position must stay in it.
    c.fire("transport/seek", position=17)
    c.drain(0.2)
    c.events.clear()
    c.fire("transport/play")
    c.drain(4.0)
    c.fire("transport/stop")
    ps = [m["payload"]["p"] for n, m in c.events if n == "tt"]
    print(f"  looped playback positions {min(ps):.2f}..{max(ps):.2f} over {len(ps)} ticks")
    if not ps or max(ps) > 20.05 or min(ps) < 1.95 or min(ps) > 3:
        problems.append(f"repeat on 2..20 from 17 s: play positions {min(ps) if ps else None}..{max(ps) if ps else None}")

    c.fire("timeSelection/clear")
    settle(c, SEL, [0, 0], "timeSelection/clear", problems)
    c.fire("repeat/set", enabled=0)
    settle(c, "return reaper.GetSetRepeat(-1)", 0, "repeat/set 0", problems)
    assert not problems, "\n".join(problems)
