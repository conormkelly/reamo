"""Four phones view different parts of a 12-track session: A a range, B a
disjoint range, C two tracks by GUID plus master, D nothing. Each phone's
tracks and meters events carry exactly the tracks it subscribed to, never
another phone's, and D gets no track data at all. Fader moves in REAPER
reach every phone that shows the track."""
import time

from reamo_client import Client, reaper

WANT = {"A": [1, 2, 3, 4], "B": [7, 8, 9, 10], "C": [0, 2, 9]}
VOLUMES = {3: 0.5, 8: 0.25, 9: 0.125}  # only A shows 3; only B shows 8; B and C show 9

with Client() as a, Client() as b, Client() as c, Client() as d:
    phones = {"A": a, "B": b, "C": c, "D": d}
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    for p in (b, c, d):
        p.wait_event("trackSkeleton")
    assert len(skel) == 13, len(skel)
    guids = [t["g"] for t in skel]

    assert a.command("track/subscribe", range={"start": 1, "end": 4})["success"]
    assert b.command("track/subscribe", range={"start": 7, "end": 10})["success"]
    assert c.command("track/subscribe", guids=[guids[2], guids[9]], includeMaster=True)["success"]
    time.sleep(0.3)
    for p in phones.values():
        p.drain(0.2)
        p.events.clear()

    reaper("\n".join(
        f'reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, {idx - 1}), "D_VOL", {vol})'
        for idx, vol in VOLUMES.items()))
    deadline = time.time() + 1.5
    while time.time() < deadline:
        for p in phones.values():
            p.drain(0.1)

    problems = []
    for name, p in phones.items():
        tracks = [m["payload"]["tracks"] for n, m in p.events if n == "tracks"]
        meters = [m["m"] for n, m in p.events if n == "meters"]
        seen = sorted({t["idx"] for ev in tracks for t in ev})
        metered = sorted({v["i"] for ev in meters for v in ev.values()})
        print(f"{name}: {len(tracks)} tracks events with idx {seen}, {len(meters)} meters events with idx {metered}")
        want = WANT.get(name)
        if want is None:
            if seen or metered:
                problems.append(f"{name} (not subscribed) got tracks {seen}, meters {metered}")
            continue
        for ev in tracks:
            got = [t["idx"] for t in ev]
            if got != want:
                problems.append(f"{name}: a tracks event carries {got}, want {want}")
                break
        for ev in meters:
            got = sorted(v["i"] for v in ev.values())
            if got != want:
                problems.append(f"{name}: a meters event carries {got}, want {want}")
                break
        if not tracks or not meters:
            problems.append(f"{name}: {len(tracks)} tracks and {len(meters)} meters events, want both")
            continue
        last = {t["idx"]: t["volume"] for t in tracks[-1]}
        for idx, vol in VOLUMES.items():
            if idx in want and abs(last.get(idx, -1) - vol) > 1e-3:
                problems.append(f"{name}: track {idx} volume {last.get(idx)}, REAPER has {vol}")
    assert not problems, "\n".join(problems)
