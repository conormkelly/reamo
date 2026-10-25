"""A region shorter than one bar (a pickup, a stinger) followed by a region
elsewhere on the timeline: the playlist plays the pickup once, then moves on.
"""
import time

from reamo_client import Client, reaper

with Client() as c:
    c.wait_event("regions")
    p = c.command("playlist/create", name="Stinger set")["payload"]["playlistIdx"]
    for rid in (1, 2):
        assert c.command("playlist/addEntry", playlistIdx=p, regionId=rid, loopCount=1)["success"]
    c.drain(0.3)
    c.fire("playlist/play", playlistIdx=p)
    seen = []
    t0 = time.time()
    while time.time() - t0 < 6:
        c.drain(0.1)
        pos = reaper("return reaper.GetPlayPosition()")
        rid = 1 if pos < 1 else 2 if 4 <= pos < 6 else None
        if rid and (not seen or seen[-1] != rid):
            seen.append(rid)
        if seen[-1:] == [2]:
            break
    entry = c.latest_event("playlist")["payload"]["currentEntryIndex"]
    reaper("reaper.OnStopButton()")
    print(f"regions played {seen}, entry shown {entry}")
    assert seen == [1, 2], f"after 6 s REAPER is still on {seen} (a 1 s region played once should take 1 s)"
