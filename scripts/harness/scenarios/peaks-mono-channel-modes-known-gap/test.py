"""A take's channel mode picks the channels its waveform shows; mono modes are a known gap (RV1-151).

GetMediaItemTake_Peaks applies the take's channel mode: reverse stereo
swaps the channels, and the mono modes (downmix, left, right) return the
same peaks on both channels. REAmo's levels match REAPER's in every mode.

Known gap: REAPER draws a mono-mode take as one waveform, the item's full
height. REAmo counts channels from the take's source (stereo), so it sends
two identical channels and a phone draws the same waveform twice, each
half height. When REAmo sends one channel for a mono mode, the pinned
channel count fails: make it assert one channel instead.
"""
from reamo_client import Client
import peaks_check as pk

STAIRS = pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)
RIGHT = [0.25] * 16
DOWNMIX = [(v + 0.25) / 2 for v in STAIRS]

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    names = ["normal", "reverse stereo", "mono (downmix)", "mono (left)", "mono (right)"]
    profiles, bad = pk.compare(tiles, names, channels=2)
    pk.save("profiles", profiles)
    pk.save("reamo-tiles", tiles)
    pk.screenshot_arrange("reaper-arrange")

    want = {"normal": (STAIRS, RIGHT), "reverse stereo": (RIGHT, STAIRS), "mono (downmix)": (DOWNMIX, DOWNMIX),
            "mono (left)": (STAIRS, STAIRS), "mono (right)": (RIGHT, RIGHT)}
    for name, (left, right) in want.items():
        r = profiles[name][1]["max"]
        assert pk.near(r[0], left) and pk.near(r[1], right), \
            f"REAPER's peaks for {name!r}:\n  L {pk.fmt(r[0])}\n  R {pk.fmt(r[1])}"
    assert not bad, "\n".join(bad)

    for name in ("normal", "reverse stereo"):
        assert profiles[name][0]["channels"] == [2], f"{name}: REAmo sent {profiles[name][0]['channels']} channels"
    for name in ("mono (downmix)", "mono (left)", "mono (right)"):
        # Known gap: REAPER draws one waveform; REAmo sends two.
        assert profiles[name][0]["channels"] == [2], \
            f"{name}: REAmo now sends {profiles[name][0]['channels']} channel(s). If that's one, the known " \
            "gap is fixed: assert one channel here."
