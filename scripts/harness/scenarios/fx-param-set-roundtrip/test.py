"""trackFxParams/set writes the normalized value REAPER then reports, both ways.

FxParamModal subscribes to a list of indices and fires trackFxParams/set while
a slider is dragged. REAPER's TrackFX_GetParamNormalized must equal what was
sent (clamped to 0..1), the subscribed event must show it with REAPER's own
formatted string, and a change made in REAPER's plugin UI must reach the client.
"""
import time
from reamo_client import Client, reaper

GET = """
local t = reaper.GetTrack(0, 0)
local _, f = reaper.TrackFX_GetFormattedParamValue(t, 0, %d, '')
return reaper.TrackFX_GetParamNormalized(t, 0, %d), f
"""


def event_value(c, idx, want, timeout=2.0):
    deadline = time.time() + timeout
    while True:
        c.drain(0.1)
        ev = c.latest_event("trackFxParams")
        v = ev["payload"]["values"].get(str(idx)) if ev else None
        if (v and abs(v[0] - want) < 1e-5) or time.time() > deadline:
            return v


with Client() as c, Client() as other:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    fx = c.wait_event("trackFxChain")["payload"]["fx"]
    eq = fx[0]["fxGuid"]
    names = c.command("trackFx/getParams", trackGuid=g, fxGuid=eq)["payload"]["params"]
    print("params:", names)
    indices = [0, 1, 2, 3]
    for cl in (c, other):
        assert cl.command("trackFxParams/subscribe", trackGuid=g, fxGuid=eq, indices=indices)["success"]
    problems = []
    for idx, sent, want in [(0, 0.25, 0.25), (1, 0.8, 0.8), (2, 1.7, 1.0), (3, -0.4, 0.0), (0, 0.5, 0.5)]:
        c.fire("trackFxParams/set", trackGuid=g, fxGuid=eq, paramIdx=idx, value=sent)
        deadline = time.time() + 2
        while True:
            norm, fmt = reaper(GET % (idx, idx))
            if abs(norm - want) < 1e-6 or time.time() > deadline:
                break
            time.sleep(0.05)
        seen = event_value(other, idx, norm)
        print(f"set p{idx}={sent}: REAPER {norm:.6f} {fmt!r}  other client {seen}")
        if abs(norm - want) > 1e-6:
            problems.append(f"p{idx}: sent {sent}, REAPER has {norm}, want {want}")
        if not seen or abs(seen[0] - norm) > 1e-5 or seen[1] != fmt:
            problems.append(f"p{idx}: other client shows {seen}, REAPER {norm} {fmt!r}")
    # The user turns the knob in REAPER's own plugin window.
    reaper("reaper.TrackFX_SetParamNormalized(reaper.GetTrack(0, 0), 0, 2, 0.125)")
    norm, fmt = reaper(GET % (2, 2))
    seen = event_value(c, 2, norm)
    print(f"REAPER set p2=0.125: client {seen}  REAPER {fmt!r}")
    if not seen or abs(seen[0] - 0.125) > 1e-5 or seen[1] != fmt:
        problems.append(f"REAPER-side change: client shows {seen}, REAPER {norm} {fmt!r}")
    # Out-of-range index, and the second FX's GUID with the first's params.
    for params in ({"paramIdx": 999, "value": 0.5}, {"paramIdx": -1, "value": 0.5}):
        r = c.command("trackFxParams/set", trackGuid=g, fxGuid=eq, **params)
        print(f"set {params}: {r.get('error') or 'ok'}")
    assert not problems, "\n".join(problems)
