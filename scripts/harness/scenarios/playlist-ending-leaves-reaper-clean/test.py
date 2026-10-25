"""However a playlist ends, REAPER is left as a normal transport: repeat off,
no leftover playlist loop, and the phone shows no active playlist.

Ways a user ends it: presses Stop in REAPER; deletes the playing playlist on
the phone ("Stops playback if the deleted playlist is active"); presses Next
on the last entry. A REAPER left with repeat on loops the region forever,
which on stage is the song never ending.
"""
import time

from reamo_client import Client, reaper

STATE = "return reaper.GetPlayState(), reaper.GetToggleCommandState(1068), reaper.GetPlayPosition()"


def start(c, p):
    c.fire("playlist/play", playlistIdx=p)
    deadline = time.time() + 3
    while time.time() < deadline:
        c.drain(0.1)
        if c.latest_event("playlist")["payload"]["isPlaylistActive"] and reaper(STATE)[0] & 1:
            return
    raise AssertionError("playlist did not start")


def settle(c, what):
    c.drain(1.5)
    st, rep, pos = reaper(STATE)
    ev = c.latest_event("playlist")["payload"]
    print(f"{what:32s} play state {st}, repeat {rep}, pos {pos:.2f}, playlist active {ev['isPlaylistActive']}")
    return st, rep, ev["isPlaylistActive"]


problems = []
with Client() as c:
    c.wait_event("regions")
    for name in ("Set A", "Set B"):
        p = c.command("playlist/create", name=name)["payload"]["playlistIdx"]
        for rid in (1, 2):
            assert c.command("playlist/addEntry", playlistIdx=p, regionId=rid, loopCount=-1)["success"]

    # 1. Stop pressed in REAPER.
    start(c, 0)
    reaper("reaper.Main_OnCommand(1016, 0)")  # Transport: Stop
    st, rep, active = settle(c, "REAPER Stop")
    if rep or active:
        problems.append(f"after REAPER Stop: repeat {rep}, playlist active {active}")

    # 2. The playing playlist is deleted on the phone.
    reaper("reaper.GetSetRepeat(0)")
    start(c, 1)
    c.fire("playlist/delete", playlistIdx=1)
    st, rep, active = settle(c, "delete the playing playlist")
    if active or st & 1 or rep:
        problems.append(f"after deleting the playing playlist: play state {st}, repeat {rep}, active {active}")

    # 3. Next on the last entry.
    reaper("reaper.Main_OnCommand(1016, 0); reaper.GetSetRepeat(0)")
    c.drain(0.5)
    start(c, 0)
    c.fire("playlist/next"); c.drain(0.3); c.fire("playlist/next")
    st, rep, active = settle(c, "Next past the last entry")
    if active or rep:
        problems.append(f"after Next past the last entry: repeat {rep}, active {active}")
    reaper("reaper.Main_OnCommand(1016, 0)")
assert not problems, "\n".join(problems)
