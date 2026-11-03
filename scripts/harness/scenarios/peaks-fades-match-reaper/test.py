"""An item's fades shape its waveform, as REAPER draws it.

REAPER draws a faded item's waveform with the fade applied (not only the
fade line over it), from GetMediaItemTake_Peaks, which applies the item's
fades and their shapes. REAmo asks the same API, so a phone shows the fade
too. Only the faded ends change: the middle of the item keeps the file's
levels.
"""
from reamo_client import Client
import peaks_check as pk

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, ["linear fades", "curved fades"])
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    for name in ("linear fades", "curved fades"):
        got = profiles[name][1]["max"][0]
        # 3-5 s into the item is outside both fades: the file's 0.4 and 0.5.
        assert pk.near(got[6:10], pk.steps(0.4, 0.5)), f"REAPER's peaks for {name!r} mid-item: {pk.fmt(got)}"
        # The file is 0.1 at the start and 0.8 at the end.
        assert got[0] < 0.05 and got[-1] < 0.6, f"REAPER's peaks for {name!r} aren't faded: {pk.fmt(got)}"
    assert not pk.near(profiles["linear fades"][1]["max"][0], profiles["curved fades"][1]["max"][0], 0.01), \
        "REAPER's peaks don't follow the fade shape"
    assert not bad, "\n".join(bad)
