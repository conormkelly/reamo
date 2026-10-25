"""The harness itself works: connect, receive state, subscribe, run a command."""
from reamo_client import Client

with Client() as c:
    skeleton = c.wait_event("trackSkeleton")["payload"]["tracks"]
    names = [t["n"] for t in skeleton]
    assert names == ["MASTER", "Drums", "Bass"], names
    c.wait_event("transport")

    r = c.command("track/subscribe", range={"start": 0, "end": 2})
    assert r["success"], r
    tracks = c.wait_event("tracks")["payload"]["tracks"]
    assert len(tracks) == 3, tracks

    r = c.command("tempo/barsToTime", bar=3)
    assert r["success"], r
    print(f"ok: skeleton={names}, subscribed tracks={len(tracks)}, bar 3 at {r['payload']['time']:.3f}s")
