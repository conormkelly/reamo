"""A take edit made and undone while a phone scrolls leaves the phone the
take's waveform as it is, not as it was in between.

While a phone keeps scrolling, every tick sends it fresh tiles for its new
view, and REAmo's change check waits for the scrolling to stop. Here the
phone scrolls on to a zoom level it has never shown while the take is in
mono, so those tiles are read from the take in mono. The take then goes
back to normal before the scrolling stops. When it stops, the phone's tiles
at that zoom level must be REAPER's peaks for the take as it is now: two
channels, the staircase on the left and 0.25 on the right. Tiles read in
mono must not be kept and sent as the take's current waveform.
"""
import time

from reamo_client import Client, reaper, submit
import peaks_check as pk

STAIRS = pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)
RIGHT = [0.25] * 16
NEAR = ({"start": 0, "end": 14, "widthPx": 1400}, {"start": 0, "end": 13.9, "widthPx": 1400})  # LOD 6
FAR = ({"start": 0, "end": 60, "widthPx": 1400}, {"start": 0, "end": 59.9, "widthPx": 1400})  # LOD 5
FAR_LOD = 5
SET_MODE = """local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0))
reaper.SetMediaItemTakeInfo_Value(tk, "I_CHANMODE", %d); reaper.UpdateArrange()"""


def scroll(c, views, seconds):
    """Keep changing the phone's view between `views`, every few ms, so every
    tick has a viewport change to send."""
    deadline = time.time() + seconds
    i = 0
    while time.time() < deadline:
        c.fire("peaks/updateViewport", viewport=views[i % 2])
        i += 1
        c.drain(0.005)


with Client() as c:
    c.wait_event("items")
    r = c.command("peaks/subscribe", range={"start": 1, "end": 1}, viewport=NEAR[0])
    assert r["success"], r
    pk.wait_tiles(c)
    pk.drain_until_quiet(c)

    scroll(c, NEAR, 0.5)
    mono = submit(SET_MODE % 3)
    scroll(c, NEAR, 0.2)
    assert mono.done(), "REAPER did not switch the take to mono while the phone scrolled"
    # On to a zoom level the phone has not shown, with the take in mono.
    scroll(c, FAR, 0.5)
    normal = submit(SET_MODE % 0)
    scroll(c, FAR, 0.5)
    assert normal.done(), "REAPER did not switch the take back while the phone scrolled"
    r = c.command("peaks/updateViewport", viewport=FAR[0])
    assert r["success"], r
    pk.drain_until_quiet(c)

    tiles = [t for t in pk.tiles_since(c) if t["lod"] == FAR_LOD]
    want = pk.reaper_profile(0)
    latest = pk.take_tiles(tiles, want["guid"])
    assert latest, "the phone got no tiles at the zoom level it scrolled to"
    channels = sorted({t["ch"] for t in latest})
    assert pk.near(want["max"][0], STAIRS) and pk.near(want["max"][1], RIGHT), \
        f"REAPER's peaks: {pk.fmt(want['max'][0])} / {pk.fmt(want['max'][1])}"
    assert channels == [2], (f"the phone's latest tiles at the zoom level it scrolled to have {channels} "
                             "channel(s), not 2: they were read while the take was in mono")
    profiles, bad = pk.compare(tiles, ["stairs"], 2)
    pk.save("profiles", profiles)
    assert not bad, "\n".join(bad)
