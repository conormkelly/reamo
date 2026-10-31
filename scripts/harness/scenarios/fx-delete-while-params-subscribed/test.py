"""Moving or deleting an FX another client is editing keeps that client on the right FX.

Phone B has the 4-Band EQ's parameters open (subscribed by FX GUID); phone A
reorders the chain, then deletes the EQ, then the user deletes another FX in
REAPER. B must keep getting the EQ's own values after the move (not whatever
now sits at its old index), then be told the FX is gone; both chain views must
match REAPER.
"""
import time
from reamo_client import Client, reaper

CHAIN = """
local t = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.TrackFX_GetCount(t) - 1 do out[#out + 1] = reaper.TrackFX_GetFXGUID(t, i) end
return out
"""


def chain_guids(c, want, timeout=2.0):
    deadline = time.time() + timeout
    while True:
        c.drain(0.1)
        ev = c.latest_event("trackFxChain")  # only re-sent on a change: none yet after wait_event
        got = [f["fxGuid"] for f in ev["payload"]["fx"]] if ev else None
        if got == want or time.time() > deadline:
            return got


with Client() as a, Client() as b:
    g = a.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    for cl in (a, b):
        assert cl.command("trackFx/subscribe", trackGuid=g)["success"]
        cl.wait_event("trackFxChain")
    eq, vol, dly = reaper(CHAIN)
    reaper("reaper.TrackFX_SetParamNormalized(reaper.GetTrack(0, 0), 0, 0, 0.25)")
    assert b.command("trackFxParams/subscribe", trackGuid=g, fxGuid=eq, indices=[0])["success"]
    v = b.wait_event("trackFxParams")["payload"]
    assert v["fxGuid"] == eq and abs(v["values"]["0"][0] - 0.25) < 1e-5, v

    # A drags the EQ to the end of the chain.
    r = a.command("trackFx/move", trackGuid=g, fxGuid=eq, toIndex=2)
    assert r["success"], r
    want = reaper(CHAIN)
    for cl in (a, b):
        got = chain_guids(cl, want)
        assert got == want, f"chain after move: client {got}, REAPER {want}"
    reaper("reaper.TrackFX_SetParamNormalized(reaper.GetTrack(0, 0), 2, 0, 0.75)")  # the EQ, now at 2
    deadline = time.time() + 2
    while True:
        b.drain(0.1)
        ev = b.latest_event("trackFxParams")  # only re-sent on a change; until then the last values stand
        v = ev["payload"] if ev else v
        if abs(v["values"]["0"][0] - 0.75) < 1e-5 or time.time() > deadline:
            break
    print("B after move:", v["fxGuid"] == eq, v["values"])
    assert abs(v["values"]["0"][0] - 0.75) < 1e-5, f"B shows {v['values']} for the moved EQ, REAPER has 0.75"

    # A deletes the EQ B is editing.
    r = a.command("trackFx/delete", trackGuid=g, fxGuid=eq)
    assert r["success"], r
    err = b.wait_event("trackFxParamsError", timeout=2)
    print("B told:", err)
    b.drain(0.5)
    b.events.clear()
    b.drain(0.5)
    assert not [m for n, m in b.events if n == "trackFxParams"], "param events kept coming after the FX was deleted"

    # The user deletes the delay in REAPER; a stale GUID from A is refused.
    reaper(f"local t = reaper.GetTrack(0, 0); for i = 0, reaper.TrackFX_GetCount(t) - 1 do "
           f"if reaper.TrackFX_GetFXGUID(t, i) == '{dly}' then reaper.TrackFX_Delete(t, i) end end")
    want = reaper(CHAIN)
    assert want == [vol], want
    for cl in (a, b):
        got = chain_guids(cl, want)
        assert got == want, f"chain after REAPER delete: client {got}, REAPER {want}"
    for cmd, extra in [("trackFx/delete", {"fxGuid": dly}), ("trackFx/move", {"fxGuid": eq, "toIndex": 0}),
                       ("trackFxParams/set", {"fxGuid": eq, "paramIdx": 0, "value": 0.5}),
                       ("trackFx/getParams", {"fxGuid": dly})]:
        r = a.command(cmd, trackGuid=g, **extra)
        print(f"{cmd} with a stale GUID: {r.get('error')}")
        assert not r["success"], f"{cmd} accepted a deleted FX's GUID: {r}"
    assert reaper(CHAIN) == [vol]
