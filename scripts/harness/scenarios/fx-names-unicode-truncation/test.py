"""Long Unicode FX and parameter names arrive as valid UTF-8 prefixes.

The extension copies names into fixed buffers (128 bytes for FX names, 256 for
parameter names). A cut that lands inside a multi-byte character makes the
frame invalid UTF-8, which a browser treats as a protocol error and closes the
WebSocket. The client decodes every frame strictly, as the browser does.
"""
import json
import time
import reamo_client
from reamo_client import Client, oracle

_loads = json.loads


def strict_loads(payload, **kw):
    """json.loads that names the frame which is not valid UTF-8."""
    if not isinstance(payload, bytes):
        return _loads(payload, **kw)
    try:
        payload.decode("utf-8")
    except UnicodeDecodeError as e:
        head = payload[:80].decode("utf-8", "replace")
        raise AssertionError(f"invalid UTF-8 at byte {e.start} of a {len(payload)}-byte frame: "
                             f"{head}... around: {payload[max(0, e.start - 12):e.start + 4]!r}") from None
    return _loads(payload, **kw)


reamo_client.json.loads = strict_loads


def wait_guid_cache(c, guid):
    t0 = time.time()
    while c.command("trackFx/delete", trackGuid=guid, fxIndex=9999)["error"]["code"] == "NOT_FOUND":
        assert time.time() - t0 < 5, "track GUID never became resolvable"
        time.sleep(0.05)


def is_prefix(got, full, what):
    assert got and full.startswith(got), f"{what}: {got!r} is not a prefix of REAPER's {full!r}"


o = oracle()
print("REAPER byte lengths:", {k: len(v.encode()) for k, v in o.items()})
with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    wait_guid_cache(c, g)
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    chain = c.wait_event("trackFxChain")["payload"]["fx"]
    for i, fx in enumerate(chain):
        print(f"chain fx{i}: {len(fx['name'].encode())} bytes")
        is_prefix(fx["name"], o[f"fx{i}"], f"trackFxChain fx{i} name")
    r = c.command("trackFx/getParams", trackGuid=g, fxGuid=chain[0]["fxGuid"])
    assert r["success"], r
    for i in range(2):
        print(f"param{i}: {len(r['payload']['params'][i].encode())} bytes")
        is_prefix(r["payload"]["params"][i], o[f"param{i}"], f"getParams name {i}")
    assert c.command("trackFxParams/subscribe", trackGuid=g, fxGuid=chain[0]["fxGuid"], indices=[0, 1])["success"]
    c.wait_event("trackFxParams")
    c.drain(1.0)  # fx_state (all FX in the project) is polled at 5 Hz
