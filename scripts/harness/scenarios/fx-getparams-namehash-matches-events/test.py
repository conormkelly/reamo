"""trackFx/getParams returns the nameHash that trackFxParams events carry.

FxParamModal stores the skeleton with getParams' nameHash and refetches it
whenever an event's nameHash differs, so the two must agree while the names
are unchanged, including while values move. The hash must also be an exact
JavaScript number (at most 2^53 - 1), or the browser compares rounded values.
"""
import time
from reamo_client import Client, oracle

MAX_SAFE_INTEGER = 2**53 - 1

with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    eq = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]
    params = int(oracle()["params"])

    r = c.command("trackFx/getParams", trackGuid=g, fxGuid=eq)
    assert r["success"], r
    skeleton_hash = r["payload"].get("nameHash")
    print("getParams: paramCount", r["payload"]["paramCount"], "nameHash", skeleton_hash)
    assert isinstance(skeleton_hash, int), f"getParams returned no integer nameHash: {r['payload'].keys()}"
    assert 0 <= skeleton_hash <= MAX_SAFE_INTEGER, f"nameHash {skeleton_hash} is not exact as a JavaScript number"

    r = c.command("trackFxParams/subscribe", trackGuid=g, fxGuid=eq, range={"start": 0, "end": params - 1})
    assert r["success"], r
    first = c.wait_event("trackFxParams")["payload"]
    print("event: paramCount", first["paramCount"], "nameHash", first["nameHash"])
    assert first["paramCount"] == params, (first["paramCount"], params)
    assert first["nameHash"] == skeleton_hash, f"event nameHash {first['nameHash']} != getParams {skeleton_hash}"

    # A value change sends another event; the names, and so the hash, stay.
    before = first["values"]["0"][0]
    c.fire("trackFxParams/set", trackGuid=g, fxGuid=eq, paramIdx=0, value=0.9 if before < 0.5 else 0.1)
    deadline = time.time() + 3
    while True:
        c.drain(0.1)
        latest = c.latest_event("trackFxParams")
        ev = latest["payload"] if latest else first
        if abs(ev["values"]["0"][0] - before) > 1e-3:
            break
        assert time.time() < deadline, f"no event reported a new value for param 0 (still {before})"
    print("after set: nameHash", ev["nameHash"])
    assert ev["nameHash"] == skeleton_hash, f"nameHash changed with a value: {ev['nameHash']} != {skeleton_hash}"
