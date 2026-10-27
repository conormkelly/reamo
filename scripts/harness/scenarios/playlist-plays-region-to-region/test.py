"""A gig playlist: Intro x1, Verse x2, Outro x1, stop after the last.

Pressing play on the phone must play REAPER region to region in that order,
loop the Verse twice, jump to the non-adjacent Outro, and stop the transport
after it. What the phone shows (playlist event) must match where REAPER is.
"""
import time

from reamo_client import Client, reaper

REGION = {1: (0, 2), 2: (2, 4), 3: (6, 8)}
ENTRIES = [(1, 1), (2, 2), (3, 1)]  # (regionId, loopCount)

with Client() as c:
    c.wait_event("regions")
    r = c.command("playlist/create", name="Friday gig")
    assert r["success"], r
    p = r["payload"]["playlistIdx"]
    for rid, loops in ENTRIES:
        assert c.command("playlist/addEntry", playlistIdx=p, regionId=rid, loopCount=loops)["success"]
    c.drain(0.5)
    c.fire("playlist/play", playlistIdx=p)

    samples = []  # (t, reaper pos, play state, entry shown, loop shown, active)
    t0 = time.time()
    while time.time() - t0 < 16:
        c.drain(0.1)
        pos, st = reaper("return reaper.GetPlayPosition(), reaper.GetPlayState()")
        ev = c.latest_event("playlist")["payload"]
        samples.append((round(time.time() - t0, 1), round(pos, 2), st, ev["currentEntryIndex"],
                        ev["currentLoopIteration"], ev["isPlaylistActive"]))
        if not ev["isPlaylistActive"] and st == 0 and time.time() - t0 > 2:
            break
    for s in samples[::3]:
        print(s)

    # Which region REAPER was actually in, in order (collapsing repeats).
    def region_at(pos):
        return next((rid for rid, (a, b) in REGION.items() if a <= pos < b), None)
    played = []
    for _, pos, st, *_ in samples:
        rid = region_at(pos)
        if st & 1 and rid and (not played or played[-1] != rid):
            played.append(rid)
    shown = []
    for *_, entry, _, active in samples:
        if active and (not shown or shown[-1] != entry):
            shown.append(entry)
    verse_loops = {it for *_, entry, it, active in samples if active and entry == 1}

    problems = []
    if played != [1, 2, 3]:
        problems.append(f"REAPER played regions {played}, want [1, 2, 3]")
    if shown != [0, 1, 2]:
        problems.append(f"phone showed entries {shown}, want [0, 1, 2]")
    if verse_loops != {1, 2}:
        problems.append(f"Verse loop iterations shown {sorted(verse_loops)}, want [1, 2]")
    last = samples[-1]
    if last[2] != 0 or last[5]:
        problems.append(f"after the Outro: play state {last[2]}, playlist active {last[5]} (want stopped)")
    rep = reaper("return reaper.GetToggleCommandState(1068)")
    if rep != 0:
        problems.append("repeat left on after the playlist finished")
    assert not problems, "\n".join(problems)
print("playlist played region to region and stopped")
