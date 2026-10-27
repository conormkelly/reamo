"""trackFxParams/subscribe in range mode, as WebSocketCommands builds it, sends that range.

The frontend builder trackFxParams.subscribe(trackGuid, fxGuid, {range: {start, end}})
flattens to "range": {"start": 2, "end": 5}. The events must carry params 2..5.
"""
import time
from reamo_client import Client, oracle

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
