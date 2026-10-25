"""Deleting tracks a client is subscribed to (by range and by GUID) updates cleanly."""
from reamo_client import Client

with Client() as a, Client() as b:
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    guids = [t["g"] for t in skel[1:]]
    assert a.command("track/subscribe", range={"start": 0, "end": 6})["success"]
    assert b.command("track/subscribe", guids=guids[2:5])["success"]
    assert a.command("peaks/subscribe", range={"start": 1, "end": 6},
                     viewport={"start": 0, "end": 10, "widthPx": 400})["success"]
    a.drain(0.5); b.drain(0.5)
    for idx in (3, 3, 1):  # delete from the middle, then the first track
        r = a.command("track/delete", trackIdx=idx)
        assert r["success"], r
        a.drain(0.4); b.drain(0.4)
    a.drain(1.5)  # skeleton is polled at 1 Hz
    skel = a.latest_event("trackSkeleton")["payload"]["tracks"]
    print("tracks left:", [t["n"] for t in skel])
    assert [t["n"] for t in skel] == ["MASTER", "T2", "T5", "T6"], skel
