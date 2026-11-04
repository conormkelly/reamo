"""A take's channel mode picks the channels its waveform shows, and how many.

GetMediaItemTake_Peaks applies the take's channel mode: reverse stereo
swaps the channels, a stereo-pair mode picks two of the source's channels,
and a mono mode (downmix, left, right, or channel N) returns the same peaks
on both channels it is asked for. REAPER draws a mono mode as one waveform,
the item's full height (seen in this scenario's screenshot), so REAmo sends
one channel for it, and two for the others.

I_CHANMODE, measured on REAPER 7.83 and 6.0: 0 normal, 1 reverse stereo,
2 mono downmix, 3..66 mono channel 1..64 (3 left, 4 right), 67..130 stereo
channels 1/2..64/65. REAPER 7.83 also has 131..194 mono channel 65..128
and 195..257 stereo channels 65/66..127/128, and draws 258 and above like
normal; 6.0 gives no peaks for a source past 64 channels, so this scenario
stays within four.

A mono source draws one waveform in every mode, but not always from the
first of the two channels GetMediaItemTake_Peaks returns: reverse stereo
puts the audio on the second and leaves the first silent. A mode picking a
channel the source doesn't have (mono channel 3) returns silence on both,
and REAPER draws it flat. REAmo's one channel carries what REAPER draws.
"""
from reamo_client import Client
import peaks_check as pk

STAIRS = pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)
RIGHT = [0.25] * 16
DOWNMIX = [(v + 0.25) / 2 for v in STAIRS]
CH3, CH4 = [0.3] * 16, [0.4] * 16

# REAPER's peaks per mode, both channels asked for.
STEREO = {"normal": (STAIRS, RIGHT), "reverse stereo": (RIGHT, STAIRS), "stereo (channels 3/4)": (CH3, CH4)}
MONO = {"mono (downmix)": DOWNMIX, "mono (left)": STAIRS, "mono (right)": RIGHT,
        "mono (channel 3)": CH3, "mono (channel 4)": CH4}
SILENT = [0.0] * 16
# A mono source's takes: REAPER's peaks on both channels asked for, and the
# one waveform it draws.
MONO_SOURCE = {"mono source (normal)": ((STAIRS, SILENT), STAIRS),
               "mono source (reverse stereo)": ((SILENT, STAIRS), STAIRS),
               "mono source (mono channel 3)": ((SILENT, SILENT), SILENT)}

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    stereo, bad = pk.compare(tiles, list(STEREO), channels=2)
    mono, b = pk.compare(tiles, list(MONO), channels=1)
    bad += b
    # Checked below against the waveform REAPER draws, which for these isn't
    # always on the first channel of its peaks.
    mono_source, _ = pk.compare(tiles, list(MONO_SOURCE), channels=0)
    profiles = {**stereo, **mono, **mono_source}
    pk.save("profiles", profiles)
    pk.save("reamo-tiles", tiles)
    pk.screenshot_arrange("reaper-arrange")

    want = {**STEREO, **{name: (level, level) for name, level in MONO.items()},
            **{name: peaks for name, (peaks, _) in MONO_SOURCE.items()}}
    for name, (left, right) in want.items():
        r = profiles[name][1]["max"]
        assert pk.near(r[0], left) and pk.near(r[1], right), \
            f"REAPER's peaks for {name!r}:\n  L {pk.fmt(r[0])}\n  R {pk.fmt(r[1])}"
    assert not bad, "\n".join(bad)

    for name in STEREO:
        assert profiles[name][0]["channels"] == [2], f"{name}: REAmo sent {profiles[name][0]['channels']} channels"
    for name in MONO:
        assert profiles[name][0]["channels"] == [1], \
            f"{name}: REAmo sent {profiles[name][0]['channels']} channels; REAPER draws one waveform"
    for name, (_, drawn) in MONO_SOURCE.items():
        mine = profiles[name][0]
        assert mine is not None, f"{name}: REAmo sent no tiles for its take"
        assert mine["channels"] == [1], f"{name}: REAmo sent {mine['channels']} channels; REAPER draws one waveform"
        assert pk.near(mine["max"][0], drawn) and pk.near(mine["min"][0], [-v for v in drawn]), \
            f"{name}: REAPER draws {pk.fmt(drawn)}\n  REAmo max {pk.fmt(mine['max'][0])}\n  REAmo min {pk.fmt(mine['min'][0])}"
