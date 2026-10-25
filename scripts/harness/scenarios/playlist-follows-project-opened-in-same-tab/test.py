"""Playlists belong to their project. Opening another project in the same
tab (File > Open, the usual way) shows that project's playlists, and edits
then are saved into that project only. Reopening brings a setlist back
intact (name with | and \\, loop counts, stop-after-last).
"""
import time

from reamo_client import Client, reaper

NAME = 'Saturday | "encore" \\ Zürich'
EXT = 'local _, n = reaper.GetProjExtState(0, "Reamo", "PlaylistCount"); local _, v = reaper.GetProjExtState(0, "Reamo", "Playlist_0"); return n, v'


def shown(c):
    return c.latest_event("playlist")["payload"]["playlists"]


problems = []


def wait_playlists(c, pred, what, timeout=3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        c.drain(0.2)
        if pred(shown(c)):
            return shown(c)
    problems.append(f"{what}: client shows {shown(c)}; project ExtState {reaper(EXT)}")
    return shown(c)


with Client() as c:
    c.wait_event("playlist")
    reaper('reaper.Main_SaveProjectEx(0, "/tmp/other.rpp", 0)')  # a project with no playlists

    # The gig project: one setlist.
    assert c.command("playlist/create", name=NAME)["success"]
    for rid, loops in [(3, 2), (1, -1), (2, 1)]:
        assert c.command("playlist/addEntry", playlistIdx=0, regionId=rid, loopCount=loops)["success"]
    assert c.command("playlist/setStopAfterLast", playlistIdx=0, stopAfterLast=0)["success"]
    c.drain(0.5)  # persisted on the next medium tick when not playing
    reaper('reaper.Main_SaveProjectEx(0, "/tmp/gig.rpp", 0)')
    gig = [{"name": NAME, "entries": [{"regionId": 3, "loopCount": 2}, {"regionId": 1, "loopCount": -1},
                                       {"regionId": 2, "loopCount": 1}], "stopAfterLast": False}]

    reaper('reaper.Main_openProject("noprompt:/tmp/other.rpp")')
    wait_playlists(c, lambda p: p == [], "opened the other project (it has no playlists)")

    # An edit in the other project is saved into it alone.
    assert c.command("playlist/create", name="Other set")["success"]
    c.drain(0.5)
    n, v = reaper(EXT)
    if (n, v.split("|")[0]) != ("1", "Other set"):
        problems.append(f"edit in the other project saved as: PlaylistCount={n} Playlist_0={v!r}")
    reaper('reaper.Main_SaveProjectEx(0, "/tmp/other.rpp", 0)')

    reaper('reaper.Main_openProject("noprompt:/tmp/gig.rpp")')
    got = wait_playlists(c, lambda p: len(p) == 1 and p[0]["name"] == NAME, "reopened the gig project")
    if got != gig:
        problems.append(f"after reopening the gig: got {got}, want {gig}")
assert not problems, "\n".join(problems)
print("playlists follow the project")
