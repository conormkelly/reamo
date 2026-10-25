"""Every playlist edit made on one phone shows up on another phone.

Band members share the setlist: one edits (rename, loop counts, reorder,
the "stop after last" switch), the others see the edit in their playlist
event. Fire-and-forget, as PlaylistView sends them.
"""
import time

from reamo_client import Client


def wait_for(c, pred, what):
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        ev = c.latest_event("playlist")
        if ev and pred(ev["payload"]):
            return ev["payload"]
    raise AssertionError(f"{what}: other client still shows {c.latest_event('playlist')['payload']}")


problems = []
with Client() as a, Client() as b:
    a.wait_event("playlist"); b.wait_event("playlist")
    a.fire("playlist/create", name="Set")
    wait_for(b, lambda p: len(p["playlists"]) == 1, "create")
    for rid, loops in [(1, 1), (2, 2), (3, 1)]:
        a.fire("playlist/addEntry", playlistIdx=0, regionId=rid, loopCount=loops)
    wait_for(b, lambda p: len(p["playlists"][0]["entries"]) == 3, "addEntry")

    edits = [
        ("rename", {"playlistIdx": 0, "name": "Gig — Zürich | \"late\" \\ set"},
         lambda p: p["playlists"][0]["name"] == "Gig — Zürich | \"late\" \\ set"),
        ("setLoopCount", {"playlistIdx": 0, "entryIdx": 1, "loopCount": -1},
         lambda p: p["playlists"][0]["entries"][1]["loopCount"] == -1),
        ("reorderEntry", {"playlistIdx": 0, "fromIdx": 2, "toIdx": 0},
         lambda p: [e["regionId"] for e in p["playlists"][0]["entries"]] == [3, 1, 2]),
        ("setStopAfterLast", {"playlistIdx": 0, "stopAfterLast": 0},
         lambda p: p["playlists"][0]["stopAfterLast"] is False),
        ("removeEntry", {"playlistIdx": 0, "entryIdx": 0},
         lambda p: [e["regionId"] for e in p["playlists"][0]["entries"]] == [1, 2]),
    ]
    for cmd, params, pred in edits:
        a.fire(f"playlist/{cmd}", **params)
        try:
            wait_for(b, pred, cmd)
            print(f"  {cmd}: seen by the other client")
        except AssertionError as e:
            problems.append(str(e))
            print(f"  {cmd}: NOT seen")
assert not problems, "\n".join(problems)
