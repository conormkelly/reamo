"""A track tuner leaves nothing in the project it tuned, even if the user
switches to another project tab while it is open: a plugin left behind is
saved into a project that never asked for it, and shows as a missing
plugin wherever REAmo isn't installed.

The tuner reads the track's input through the audio hook and puts nothing
in the project. Two ways it ends, both with no FX on the first tab's track
at any point and no input tap left open:
- the phone closes the tuner after the user opens a new tab;
- the phone keeps it open: its track is in a background tab now, so the
  tuner loses it, and the phone is told (tunerError TUNER_NOT_FOUND).
"""
import time

from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

# The first tab's tuned track, by project pointer: GetTrack(0, ...) is the
# current tab.
FX_IN_FIRST_TAB = ("local t = reaper.GetTrack(first_tab, 0); "
                   "return reaper.TrackFX_GetCount(t) + reaper.TrackFX_GetRecCount(t)")


def taps(c):
    return c.command("audio/status")["payload"]["inputTaps"]


def wait_taps(c, want, timeout=3.0):
    deadline = time.time() + timeout
    while taps(c) != want and time.time() < deadline:
        c.drain(0.1)
    return taps(c)


for how in ("phone closes the tuner", "tuner loses its track"):
    with Client() as c:
        bass = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
        time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
        reaper("first_tab = reaper.EnumProjects(-1)")
        r = c.command("tuner/subscribe", trackGuid=bass)
        assert r["success"], r
        assert taps(c) == 1
        assert reaper(FX_IN_FIRST_TAB) == 0, "the tuner put an FX on the track"

        reaper("reaper.Main_OnCommand(40859, 0)")  # New project tab
        if how == "phone closes the tuner":
            c.command("tuner/unsubscribe")
        else:
            e = c.wait_event("tunerError", timeout=3.0)
            assert e["payload"]["error"] == "TUNER_NOT_FOUND", e
            # Names its source, for a phone that has moved on to ignore.
            assert e["payload"].get("trackGuid") == bass, e
        n = wait_taps(c, 0)
        fx = reaper(FX_IN_FIRST_TAB)
        print(f"{how}: {fx} FX left in the first tab, {n} input taps open")
        assert fx == 0, f"{how}: an FX was left in the first project tab"
        assert n == 0, f"{how}: the tuner's input tap was left open"

        # Back to the first tab for the next round.
        reaper("reaper.Main_OnCommand(40860, 0); reaper.SelectProjectInstance(first_tab)")
        assert reaper("return reaper.EnumProjects(-1) == first_tab") is True
print("ok: the tuner leaves nothing in the project it tuned")
