"""Stretch markers move the waveform in time, as REAPER draws it.

Markers at item 0 s = file 0 s, 2 s = 4 s and 8 s = 8 s play the file's
first four seconds twice as fast, then its last four at two thirds speed.
REAPER draws the take's peaks from GetMediaItemTake_Peaks, which follows
the markers; REAmo asks the same API.
"""
from reamo_client import Client
import peaks_check as pk

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, ["stretched", "not stretched"])
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    want = pk.steps(0.1, 0.2, 0.3, 0.4, per=1) + pk.steps(0.5, 0.6, 0.7, 0.8, per=3)
    got = profiles["stretched"][1]["max"][0]
    assert pk.near(got, want), f"REAPER's peaks for the stretched take: {pk.fmt(got)}, expected {pk.fmt(want)}"
    assert not bad, "\n".join(bad)
