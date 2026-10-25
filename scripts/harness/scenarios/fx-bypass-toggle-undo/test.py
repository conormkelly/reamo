"""Bypassing an FX from the phone matches REAPER, shows on every phone, and undoes.

FxModal sends trackFx/setEnabled(trackIdx, fxIndex, undefined, trackGuid): a
toggle by GUID. REAPER's TrackFX_GetEnabled, both clients' trackFxChain and the
global fx_state must agree after each toggle, and REAPER's undo must restore it.
"""
import time
from reamo_client import Client, reaper

EN = "local t = reaper.GetTrack(0, 0); return reaper.TrackFX_GetEnabled(t, 0), reaper.TrackFX_GetEnabled(t, 1)"


def shown(c, want):
    deadline = time.time() + 2
    while True:
        c.drain(0.1)
        chain = c.latest_event("trackFxChain")
        glob = c.latest_event("fx_state")
        got = (tuple(f["enabled"] for f in chain["payload"]["fx"]) if chain else None,
               tuple(f["enabled"] for f in glob["payload"]["fx"] if f["trackIdx"] == 1) if glob else None)
        if got == (want, want) or time.time() > deadline:
            return got


with Client() as a, Client() as b:
    g = a.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    for cl in (a, b):
        assert cl.command("trackFx/subscribe", trackGuid=g)["success"]
        cl.events.append(("trackFxChain", cl.wait_event("trackFxChain")))
    problems = []
    for step, params in [("toggle EQ", {"fxIdx": 0}), ("toggle Volume", {"fxIdx": 1}),
                         ("toggle EQ back", {"fxIdx": 0}), ("explicit off", {"fxIdx": 1, "enabled": 0}),
                         ("explicit off again", {"fxIdx": 1, "enabled": 0})]:
        r = a.command("trackFx/setEnabled", trackGuid=g, **params)
        assert r["success"], r
        want = tuple(reaper(EN))
        got = shown(b, want)
        print(f"{step:18s} REAPER {want} other phone {got} undo={reaper('return reaper.Undo_CanUndo2(0)')!r}")
        if got != (want, want):
            problems.append(f"{step}: other phone shows {got}, REAPER {want}")
    reaper("reaper.Undo_DoUndo2(0)")
    want = tuple(reaper(EN))
    print("after undo: REAPER", want, "phone", shown(b, want))
    # Setting an FX to the state it already has adds no undo point, so this
    # undoes "toggle EQ back".
    if want != (False, False) or shown(b, want) != (want, want):
        problems.append(f"undo should re-bypass the EQ: REAPER {want}, phone {shown(b, want)}")
    r = a.command("trackFx/setEnabled", trackGuid=g, fxIdx=2)
    assert not r["success"], r
    assert not problems, "\n".join(problems)
