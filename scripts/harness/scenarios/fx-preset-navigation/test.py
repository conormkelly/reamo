"""Preset next/prev/set land on the preset REAPER reports, and the chain event follows.

FxModal fires trackFx/presetNext / presetPrev with (trackIdx, fxIdx); the
handlers answer only on failure, so the steps are fired, as the UI does. After each
step REAPER's TrackFX_GetPresetIndex/GetPreset are the truth; the subscribed
trackFxChain event must show the same index and name, and stepping on an FX
without presets, or an index past the chain, must not break anything.
"""
import time
from reamo_client import Client, oracle, reaper

PRESET = """
local t = reaper.GetTrack(0, 0)
local idx, n = reaper.TrackFX_GetPresetIndex(t, 1)
local _, name = reaper.TrackFX_GetPreset(t, 1, '')
return idx, n, name
"""


def chain_shows(c, idx, name):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        fx = c.latest_event("trackFxChain")["payload"]["fx"][1]
        if (fx["presetIndex"], fx["presetName"]) == (idx, name) or time.time() > deadline:
            return fx["presetIndex"], fx["presetName"], fx["presetCount"]


o = oracle()
assert o["reaeq"] == "1" and int(o["presets"]) > 3, f"ReaEQ with factory presets expected: {o}"
with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    c.wait_event("trackFxChain")
    problems = []
    steps = [("trackFx/presetNext", {}), ("trackFx/presetNext", {}), ("trackFx/presetPrev", {}),
             ("trackFx/presetSet", {"presetIdx": 3}), ("trackFx/presetPrev", {})]
    for cmd, extra in steps:
        c.fire(cmd, trackIdx=1, fxIdx=1, **extra)
        deadline = time.time() + 2
        while True:  # the fired command lands on a later tick
            c.drain(0.1)
            idx, n, name = reaper(PRESET)
            shown = chain_shows(c, idx, name)
            if shown[:2] == (idx, name) or time.time() > deadline:
                break
        print(f"{cmd:20s} {extra}: REAPER {idx}/{n} {name!r}  client {shown}")
        if shown != (idx, name, n):
            problems.append(f"{cmd} {extra}: client shows {shown}, REAPER {(idx, name, n)}")
    want = reaper(PRESET)
    assert want[0] == 2, f"after next,next,prev,set 3,prev REAPER should be on preset 2: {want}"
    # Edges: an FX without presets, an FX index past the end, master (no FX).
    for params in ({"trackIdx": 1, "fxIdx": 0}, {"trackIdx": 1, "fxIdx": 7}, {"trackIdx": 0, "fxIdx": 0},
                   {"trackIdx": 1, "fxIdx": 1, "presetIdx": 999}):
        cmd = "trackFx/presetSet" if "presetIdx" in params else "trackFx/presetNext"
        r = c.command(cmd, **params)
        print(f"{cmd} {params}: {r.get('error') or 'ok'}")
        assert not r["success"], f"{cmd} {params} should fail: {r}"
    c.drain(0.5)
    assert reaper("return reaper.CountTracks(0)") == 1
    assert not problems, "\n".join(problems)
