"""A take's playrate squeezes or stretches its waveform in time, as REAPER does.

At rate 2 each second of the file takes half a second of the item; at 0.5,
two. Preserve pitch changes how it sounds, not the waveform. REAPER draws
the take's peaks from GetMediaItemTake_Peaks, which applies the rate; REAmo
asks the same API.
"""
from reamo_client import Client
import peaks_check as pk

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    names = ["rate 2", "rate 2, preserve pitch", "rate 0.5, preserve pitch"]
    profiles, bad = pk.compare(tiles, names)
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    want = {"rate 2": pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, per=1),
            "rate 2, preserve pitch": pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, per=1),
            "rate 0.5, preserve pitch": pk.steps(0.1, 0.2, 0.3, 0.4, per=4)}
    for name, levels in want.items():
        got = profiles[name][1]["max"][0]
        assert pk.near(got, levels), f"REAPER's peaks for {name!r}: {pk.fmt(got)}, expected {pk.fmt(levels)}"
    assert not bad, "\n".join(bad)
