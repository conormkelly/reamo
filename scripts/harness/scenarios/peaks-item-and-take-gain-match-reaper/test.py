"""Item volume, take volume, take pan and take envelopes scale the waveform, as REAPER draws it.

REAPER draws a take's waveform from GetMediaItemTake_Peaks, which applies
the item's and the take's volume (multiplied), the take's pan and its
volume envelope. A flipped take polarity draws the same as unflipped, and
the track's volume isn't applied at all. REAmo asks the same API, so a
phone matches in each case.
"""
from reamo_client import Client
import peaks_check as pk

FILE = pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    mono = ["item volume -6 dB", "take volume -6 dB", "item and take -6 dB", "take polarity flipped",
            "track volume -6 dB", "take volume envelope"]
    profiles, bad = pk.compare(tiles, mono)
    stereo, bad2 = pk.compare(tiles, ["stereo, take pan hard left", "stereo"], channels=2)
    profiles.update(stereo)
    bad += bad2
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    def reaper_max(name, ch=0):
        return profiles[name][1]["max"][ch]

    for name, scale in (("item volume -6 dB", 0.5), ("take volume -6 dB", 0.5), ("item and take -6 dB", 0.25),
                        ("take polarity flipped", 1), ("track volume -6 dB", 1)):
        want = [v * scale for v in FILE]
        assert pk.near(reaper_max(name), want), f"REAPER's peaks for {name!r}: {pk.fmt(reaper_max(name))}, expected {pk.fmt(want)}"
    env = reaper_max("take volume envelope")
    assert env[0] < 0.01 and env[-1] > 0.7 and env == sorted(env), f"REAPER's peaks under the envelope: {pk.fmt(env)}"
    assert pk.near(reaper_max("stereo, take pan hard left"), FILE), pk.fmt(reaper_max("stereo, take pan hard left"))
    assert max(reaper_max("stereo, take pan hard left", 1)) < 0.01, \
        f"REAPER's right channel panned hard left: {pk.fmt(reaper_max('stereo, take pan hard left', 1))}"
    assert pk.near(reaper_max("stereo", 1), [0.25] * 16), pk.fmt(reaper_max("stereo", 1))
    assert not bad, "\n".join(bad)
