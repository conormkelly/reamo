"""A region batch that skips many ops still tells the phone what it applied and skipped.

Each skipped op adds a warning to the reply. With enough of them the reply
outgrew its buffer and went out as a bare success, without the counts or
the warnings the region editor shows.
"""
from reamo_client import Client, reaper

with Client(timeout=10) as c:
    c.wait_event("regions")
    ops = [{"op": "delete", "id": 1000 + i} for i in range(30)]
    ops.append({"op": "update", "id": 1, "name": "Chorus 2"})
    r = c.command("region/batch", ops=ops)
    assert r["success"], r
    payload = r.get("payload")
    assert payload is not None, f"batch reply lost its counts: {r}"
    assert payload["applied"] == 1 and payload["skipped"] == 30, payload
    assert len(payload["warnings"]) > 0, payload

    name = reaper("local _, _, _, _, n = reaper.EnumProjectMarkers(1); return n")
    assert name == "Chorus 2", name
