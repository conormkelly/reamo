"""An item that loops its source shows the file's waveform again after its end, as REAPER does.

A 12 s item on an 8 s file starts the file over at 8 s; one slipped 6 s in
plays the file's last two seconds, then its start. REAPER draws the take's
peaks from GetMediaItemTake_Peaks, which loops the source; REAmo asks the
same API. (An item past its file's end with looping off is
peaks-item-past-its-source-end-known-gap.)
"""
from reamo_client import Client
import peaks_check as pk

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, ["looped, 12 s", "looped, offset 6 s"])
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    want = {"looped, 12 s": pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.1, 0.2, 0.3, 0.4),
            "looped, offset 6 s": pk.steps(0.7, 0.8, 0.1, 0.2, 0.3, 0.4)}
    for name, levels in want.items():
        got = profiles[name][1]["max"][0]
        assert pk.near(got, levels), f"REAPER's peaks for {name!r}: {pk.fmt(got)}, expected {pk.fmt(levels)}"
    assert not bad, "\n".join(bad)
