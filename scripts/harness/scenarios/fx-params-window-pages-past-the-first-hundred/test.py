"""trackFxParams/subscribe in indices mode pages through a plugin's parameters.

FxParamModal subscribes to a window of up to 100 parameters around the rows
on screen and re-subscribes as the list scrolls. Each re-subscribe must
replace the window: the next events carry exactly the new indices (the
client replaces its values with each event), with REAPER's values, however
far past the first 100 parameters the window is. A filtered list sends
scattered indices the same way.
"""
import time
from reamo_client import Client, oracle, reaper


def wait_guid_cache(c, guid):
    t0 = time.time()
    while c.command("trackFx/delete", trackGuid=guid, fxIndex=9999)["error"]["code"] == "NOT_FOUND":
        assert time.time() - t0 < 5, "track GUID never became resolvable"
        time.sleep(0.05)


def subscribe(c, track, fx, indices):
    """Subscribe to `indices` and return the first event carrying exactly them."""
    r = c.command("trackFxParams/subscribe", trackGuid=track, fxGuid=fx, indices=indices)
    assert r["success"], r
    deadline = time.time() + 3
    seen = []
    while time.time() < deadline:
        values = c.wait_event("trackFxParams")["payload"]["values"]
        keys = sorted(int(k) for k in values)
        if keys == sorted(indices):
            return values
        seen.append(keys[:3] + ["..."] if len(keys) > 3 else keys)
    raise AssertionError(f"no event carried exactly {indices[:3]}... ({len(indices)}); saw {seen[-5:]}")


o = oracle()
print("fixture:", o)
assert o["fx"] == "0", o
assert int(o["params"]) >= 256, o["params"]

with Client(timeout=5.0) as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    wait_guid_cache(c, g)
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    fx = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]

    top = subscribe(c, g, fx, list(range(0, 100)))
    assert top["0"][0] == float(o["value0"]), (top["0"], o["value0"])
    print("top window: params 0..99")

    # Scrolled far down: the full 100 params, centred on 180, all past the first 100
    page = subscribe(c, g, fx, list(range(131, 231)))
    v, formatted = page["180"]
    assert abs(v - float(o["value180"])) < 1e-6, (v, o["value180"])
    assert formatted == o["formatted180"], (formatted, o["formatted180"])
    print("paged window: params 131..230, param 180 =", page["180"])

    # The old window is gone. Change a parameter it held, then one the new
    # window holds: every event from then on carries the new window only,
    # and the change to param 180 arrives without param 10 beside it
    c.events.clear()
    reaper("reaper.TrackFX_SetParamNormalized(reaper.GetTrack(0, 0), 0, 10, 0.9)")
    c.drain(0.3)
    reaper("reaper.TrackFX_SetParamNormalized(reaper.GetTrack(0, 0), 0, 180, 0.7)")
    deadline = time.time() + 3
    while True:
        values = c.wait_event("trackFxParams")["payload"]["values"]
        keys = sorted(int(k) for k in values)
        assert keys == list(range(131, 231)), f"event after re-subscribe carried {keys[:5]}..."
        if abs(values["180"][0] - 0.7) < 1e-6:
            break
        assert time.time() < deadline, "the change to param 180 never arrived"
    print("after changing params 10 and 180: events carry 131..230 only, param 180 =", values["180"])

    # A filtered list: scattered indices, up to the last parameter
    scattered = subscribe(c, g, fx, [3, 77, 150, 255])
    assert scattered["255"][1] == o["formatted255"], (scattered["255"], o["formatted255"])
    print("filtered window: params", sorted(int(k) for k in scattered))
