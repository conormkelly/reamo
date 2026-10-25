"""trackFx/getParams answers for an FX with hundreds of long parameter names.

FxParamModal awaits getParams (5 s timeout) to build its parameter list. For
an FX whose names don't fit the response buffer the UI must still get an
answer - the full list, or at least an error - never silence.
"""
import time
from reamo_client import Client, oracle


def wait_guid_cache(c, guid):
    t0 = time.time()
    while c.command("trackFx/delete", trackGuid=guid, fxIndex=9999)["error"]["code"] == "NOT_FOUND":
        assert time.time() - t0 < 5, "track GUID never became resolvable"
        time.sleep(0.05)


o = oracle()
print("fixture:", {k: v[:60] for k, v in o.items()})
assert o["fx"] == "0", o
with Client(timeout=5.0) as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    wait_guid_cache(c, g)
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    fx_guid = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]
    try:
        r = c.command("trackFx/getParams", trackGuid=g, fxGuid=fx_guid)
    except TimeoutError:
        raise AssertionError(f"trackFx/getParams sent no response within 5 s for {o['params']} params "
                             f"of ~{len(o['name0'])} bytes each") from None
    print("response:", r["success"], r.get("error") or (r["payload"]["paramCount"], len(r["payload"]["params"])))
    assert r["success"], r
    assert r["payload"]["paramCount"] == int(o["params"]) == len(r["payload"]["params"]), r["payload"]["paramCount"]
    assert r["payload"]["params"][0] == o["name0"][:255], (r["payload"]["params"][0], o["name0"])
