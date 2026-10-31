"""Deleting tracks with routing open: the bus drops the receive, and the bus itself can go.

Phone A has the Reverb bus's routing open and phone B the Vocals' FX chain.
The user deletes Vocals (which sends to the bus), then the Reverb bus itself.
A's routing view must lose the Vocals receive; then nothing may crash, and the
remaining commands that address the deleted bus must be refused.
"""
import time
from reamo_client import Client, reaper

with Client() as a, Client() as b:
    skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
    vox, gtr, rev = (t["g"] for t in skel[1:4])
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert a.command("routing/subscribe", trackGuid=rev)["success"]
    assert b.command("trackFx/subscribe", trackGuid=vox)["success"]
    assert b.command("routing/subscribe", trackGuid=vox)["success"]
    ev = a.wait_event("routing_state")["payload"]
    assert [r["srcName"] for r in ev["receives"]] == ["Vocals", "Guitar"], ev

    r = a.command("track/delete", trackIdx=1)  # Vocals
    assert r["success"], r
    deadline = time.time() + 2
    while True:
        a.drain(0.1); b.drain(0.1)
        ev = a.latest_event("routing_state")  # none until the receives change: wait_event took the subscribe snapshot
        got = [r["srcName"] for r in ev["payload"]["receives"]] if ev else None
        if got == ["Guitar"] or time.time() > deadline:
            break
    print("bus receives after deleting Vocals:", got, "REAPER:", reaper("return reaper.GetTrackNumSends(reaper.GetTrack(0, 1), -1)"))
    assert got == ["Guitar"], got if ev else "no routing_state event within 2 s of deleting Vocals"

    reaper("reaper.DeleteTrack(reaper.GetTrack(0, 1))")  # the user deletes the bus in REAPER
    a.drain(1.5); b.drain(0.5)
    assert reaper("return reaper.CountTracks(0)") == 1
    a.events.clear()
    a.drain(0.6)
    assert not [n for n, _ in a.events if n == "routing_state"], "routing events for a deleted track"
    for cmd, params in [("send/add", {"trackGuid": gtr, "destTrackGuid": rev}),
                        ("receive/remove", {"trackGuid": rev, "recvIdx": 0}),
                        ("hw/add", {"trackGuid": rev})]:
        r = a.command(cmd, **params)
        print(f"{cmd} on the deleted bus: {r.get('error')}")
        assert not r["success"], f"{cmd} on a deleted track succeeded: {r}"
    assert reaper("return reaper.GetTrackNumSends(reaper.GetTrack(0, 0), 0)") == 0
