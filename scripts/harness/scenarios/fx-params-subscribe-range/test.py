"""trackFxParams/subscribe in range mode, as WebSocketCommands builds it, sends that range,
and the 100-parameter limit and non-negative indices hold in both modes.

The frontend builder trackFxParams.subscribe(trackGuid, fxGuid, {range: {start, end}})
flattens to "range": {"start": 2, "end": 5}. The events must carry params 2..5.
A request over the limit, or with a negative or non-integer index, is
rejected with its error code, and the subscription in place keeps sending
its own params.
"""
import time
from reamo_client import Client, oracle, reaper


def error_code(r):
    assert not r["success"], f"expected a rejection, got {r}"
    return r["error"]["code"]


def wait_values(c, keys, check=lambda values: True):
    """The first trackFxParams event carrying exactly `keys` that passes `check`."""
    deadline = time.time() + 3
    seen = []
    while time.time() < deadline:
        values = c.wait_event("trackFxParams")["payload"]["values"]
        got = sorted(int(k) for k in values)
        if got == keys and check(values):
            return values
        seen.append(got[:6])
    raise AssertionError(f"no event carried params {keys}; saw {seen[-5:]}")


with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    eq = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]
    print("param count:", oracle()["params"])
    r = c.command("trackFxParams/subscribe", trackGuid=g, fxGuid=eq, range={"start": 2, "end": 5})
    assert r["success"], r
    keys = sorted(int(k) for k in c.wait_event("trackFxParams")["payload"]["values"])
    print("event carries params", keys)
    assert keys == [2, 3, 4, 5], f"asked for range 2..5, got params {keys}"

    def subscribe(**mode):
        return c.command("trackFxParams/subscribe", trackGuid=g, fxGuid=eq, **mode)

    # The limit is on the range's width: 0..99 is accepted, 0..100 is not
    assert subscribe(range={"start": 0, "end": 99})["success"]
    assert error_code(subscribe(range={"start": 0, "end": 100})) == "TOO_MANY_PARAMS"
    assert error_code(subscribe(rangeStart=0, rangeEnd=100000)) == "TOO_MANY_PARAMS"
    assert error_code(subscribe(range={"start": -1, "end": 5})) == "INVALID_RANGE"
    assert error_code(subscribe(rangeStart=-1, rangeEnd=5)) == "INVALID_RANGE"

    # Indices: 100 accepted, 101 rejected rather than cut to the first 100
    assert subscribe(indices=list(range(100)))["success"]
    assert error_code(subscribe(indices=list(range(101)))) == "TOO_MANY_PARAMS"
    assert error_code(subscribe(indices=[1, -1])) == "INVALID_INDEX"
    assert error_code(subscribe(indices=[1.5])) == "INVALID_PARAMS"
    print("limits: range 0..99 and 100 indices accepted; 0..100, 101 indices, negatives, 1.5 rejected")

    # A repeated index is subscribed once
    assert subscribe(indices=[3, 1, 3])["success"]
    wait_values(c, [1, 3])

    # A rejected subscribe keeps that subscription: a change to param 3
    # arrives in an event carrying params 1 and 3 only
    assert error_code(subscribe(indices=list(range(101)))) == "TOO_MANY_PARAMS"
    c.events.clear()
    before = reaper("return reaper.TrackFX_GetParamNormalized(reaper.GetTrack(0, 0), 0, 3)")
    target = 0.25 if abs(before - 0.25) > 0.1 else 0.75
    # REAPER's own reading of the value it stored, which a stepped slider may round
    after = reaper(f"reaper.TrackFX_SetParamNormalized(reaper.GetTrack(0, 0), 0, 3, {target}) "
                   "return reaper.TrackFX_GetParamNormalized(reaper.GetTrack(0, 0), 0, 3)")
    assert abs(after - before) > 1e-6, f"param 3 did not change from {before}"
    values = wait_values(c, [1, 3], lambda v: abs(v["3"][0] - after) < 1e-5)
    print("kept subscription after a rejection, param 3 =", values["3"])
