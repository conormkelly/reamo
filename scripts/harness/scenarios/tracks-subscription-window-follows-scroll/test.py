"""A 120-track session: the mixer's subscription window (range mode, then GUID
mode, then range again as the user scrolls) decides exactly which tracks the
tracks and meters events carry, and unsubscribe stops both."""
import time

from reamo_client import Client


def window(c, seconds=0.6):
    c.events.clear()
    c.drain(seconds)
    tr = [m for n, m in c.events if n == "tracks"]
    me = [m for n, m in c.events if n == "meters"]
    return tr, me


with Client(timeout=10) as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    assert len(skel) == 121, len(skel)
    guids = [t["g"] for t in skel]
    problems = []

    def check(label, want_idx):
        deadline = time.time() + 2
        while True:
            tr, me = window(c, 0.4)
            got = [t["idx"] for t in tr[-1]["payload"]["tracks"]] if tr else None
            meter_idx = sorted(v["i"] for v in me[-1]["m"].values()) if me else None
            if (got == want_idx and meter_idx == want_idx) or time.time() > deadline:
                break
        print(f"{label:>28}: tracks idx {got[:3] if got else got}..{got[-1:] if got else ''} ({len(got or [])}),"
              f" meters {len(meter_idx or [])}, total={tr[-1]['payload'].get('total') if tr else None}")
        if got != want_idx:
            problems.append(f"{label}: tracks event has {got}, want {want_idx}")
        if meter_idx != want_idx:
            problems.append(f"{label}: meters event has {meter_idx}, want {want_idx}")
        names = {t["idx"]: t["name"] for t in tr[-1]["payload"]["tracks"]} if tr else {}
        for i in want_idx:
            if i and names.get(i) != f"Track {i:03d}":
                problems.append(f"{label}: idx {i} named {names.get(i)!r}")
                break

    assert c.command("track/subscribe", range={"start": 0, "end": 31})["success"]
    check("range 0..31 (top of mixer)", list(range(0, 32)))
    assert c.command("track/subscribe", range={"start": 40, "end": 71})["success"]
    check("range 40..71 (scrolled)", list(range(40, 72)))
    assert c.command("track/subscribe", range={"start": 100, "end": 131}, includeMaster=True)["success"]
    check("range 100..131 + master", [0] + list(range(100, 121)))
    sel = [guids[i] for i in (5, 50, 99, 120)]
    assert c.command("track/subscribe", guids=sel)["success"]
    check("GUID mode (filtered view)", [5, 50, 99, 120])

    assert c.command("track/unsubscribe")["success"]
    c.drain(0.2)
    tr, me = window(c, 1.0)
    print(f"after unsubscribe: {len(tr)} tracks events, {len(me)} meters events in 1 s")
    if tr or me:
        problems.append(f"after unsubscribe still got {len(tr)} tracks and {len(me)} meters events")
    assert not problems, "\n".join(problems)
