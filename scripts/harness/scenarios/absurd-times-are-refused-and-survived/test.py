"""A time no project could reach is refused from a phone and survived from REAPER.

From a phone: tempo conversions and marker/item placement at 1e300 seconds
answer an error. Converting that time overflowed REAPER's bar number into a
panic (tempo/snap took REAPER down), and its 15-decimal reply overflowed the
buffer. From REAPER: a marker a script put at 1e300 must not crash the
polling that turns every marker into bar.beat.
"""
from reamo_client import Client, reaper

with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")
    for command in ("tempo/snap", "tempo/getBarDuration", "tempo/timeToBeats"):
        for t in (1e300, -1e300):
            r = c.command(command, time=t)
            assert not r["success"] and r["error"]["code"] == "INVALID_TIME", (command, t, r)
        r = c.command(command, time=90.0)
        assert r["success"] and r.get("payload"), (command, r)

    r = c.command("marker/add", position=1e300)
    assert not r["success"] and r["error"]["code"] == "INVALID_POSITION", r

    reaper("reaper.AddProjectMarker(0, false, 1e300, 0, 'far away', 77); reaper.UpdateTimeline()")
    c.drain(2)  # a few marker polls
    markers = c.latest_event("markers")["payload"]["markers"]
    assert any(m["id"] == 77 for m in markers), markers
    r = c.command("debug/memoryStats")
    assert r["success"], r

    # The transport turns the edit cursor's position into bar.beat 30 times
    # a second: the cursor parked on that marker must not crash or hang it.
    reaper("reaper.SetEditCurPos(1e300, false, false)")
    c.drain(1)
    r = c.command("debug/memoryStats")
    assert r["success"], r
