"""An entry set to "Skip" (loopCount 0, which the phone's minus button reaches
from 1x) is skipped: Intro x1, Verse Skip, Outro x1 plays Intro then Outro.
"""
import time

from reamo_client import Client, reaper

REGION = {1: (0, 2), 2: (2, 4), 3: (6, 8)}


def run(c, p, label, seconds=12):
    c.fire("playlist/play", playlistIdx=p)
    samples = []
    t0 = time.time()
    while time.time() - t0 < seconds:
        c.drain(0.1)
        pos, st = reaper("return reaper.GetPlayPosition(), reaper.GetPlayState()")
        ev = c.latest_event("playlist")["payload"]
        samples.append((round(pos, 2), st, ev["currentEntryIndex"], ev["isPlaylistActive"]))
        if not ev["isPlaylistActive"] and st == 0 and time.time() - t0 > 2:
            break
    c.fire("playlist/stop")
    c.drain(0.5)
    played = []
    for pos, st, *_ in samples:
        rid = next((k for k, (a, b) in REGION.items() if a <= pos < b), None)
        if st & 1 and rid and (not played or played[-1] != rid):
            played.append(rid)
    print(f"{label}: REAPER played {played}; last sample {samples[-1]}")
    return played, samples


with Client() as c:
    c.wait_event("regions")
    p = c.command("playlist/create", name="Short set")["payload"]["playlistIdx"]
    for rid, loops in [(1, 1), (2, 0), (3, 1)]:
        assert c.command("playlist/addEntry", playlistIdx=p, regionId=rid, loopCount=loops)["success"]
    c.drain(0.5)
    played, samples = run(c, p, "Intro x1, Verse skip, Outro x1")
    assert played == [1, 3], f"want Intro then Outro, REAPER played {played} (last: {samples[-1]})"

    # Skip on the first entry: playback starts at the first entry not skipped.
    q = c.command("playlist/create", name="Skip first")["payload"]["playlistIdx"]
    for rid, loops in [(1, 0), (2, 1)]:
        assert c.command("playlist/addEntry", playlistIdx=q, regionId=rid, loopCount=loops)["success"]
    c.drain(0.5)
    played, samples = run(c, q, "Intro skip, Verse x1", seconds=8)
    assert played == [2], f"want only Verse, REAPER played {played} (last: {samples[-1]})"
