"""A take playing a section of its file shows that section's waveform, as REAPER does.

The take's source is a SECTION wrapping the WAVE file (RV1-151 asked
whether REAmo, which never unwraps it, gets this right). REAPER draws the
take's peaks from GetMediaItemTake_Peaks, which plays the take through the
section; REAmo asks the same API for the take, so its tiles show seconds
2-5 of the file (levels 0.3 to 0.5), and a start offset counts from the
section's start.
"""
from reamo_client import Client
import peaks_check as pk

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, ["section 2-5 s", "section 2-5 s, offset 1 s", "whole file"])
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    # REAPER's rule, so a change in a REAPER release shows up here.
    want = {"section 2-5 s": pk.steps(0.3, 0.4, 0.5),
            "section 2-5 s, offset 1 s": pk.steps(0.4, 0.5),
            "whole file": pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)}
    for name, levels in want.items():
        got = profiles[name][1]["max"][0]
        assert pk.near(got, levels), f"REAPER's peaks for {name!r}: {pk.fmt(got)}, expected {pk.fmt(levels)}"
    assert not bad, "\n".join(bad)
