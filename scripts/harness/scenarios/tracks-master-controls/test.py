"""The master track (wire index 0, GUID "master") takes volume, pan, mute and solo
like any track, shows them in the tracks event, and refuses rename/duplicate/delete
without touching the project."""
import time

from reamo_client import Client, reaper

MASTER = """
local m = reaper.GetMasterTrack(0)
return {vol = reaper.GetMediaTrackInfo_Value(m, "D_VOL"), pan = reaper.GetMediaTrackInfo_Value(m, "D_PAN"),
        mute = reaper.GetMediaTrackInfo_Value(m, "B_MUTE"), solo = reaper.GetMediaTrackInfo_Value(m, "I_SOLO"),
        flags = reaper.GetMasterMuteSoloFlags(), tracks = reaper.CountTracks(0)}
"""


def master_shown(c):
    return next(t for t in c.latest_event("tracks")["payload"]["tracks"] if t["idx"] == 0)


def wait_for(c, pred, what):
    deadline = time.time() + 2
    while True:
        c.drain(0.15)
        m, s = reaper(MASTER), master_shown(c)
        if pred(m, s) or time.time() > deadline:
            break
    print(f"{what:>20}: REAPER {m} | shown vol={s['volume']} pan={s['pan']} mute={s['mute']} solo={s['solo']}")
    assert pred(m, s), what
    return m, s


with Client() as c:
    c.wait_event("trackSkeleton")
    assert c.command("track/subscribe", range={"start": 0, "end": 1})["success"]
    c.drain(1.2)  # see tracks-guid-commands-right-after-connect: GUIDs resolve only after the first 1 Hz tick
    c.fire("track/setVolume", trackIdx=0, volume=0.5)
    wait_for(c, lambda m, s: abs(m["vol"] - 0.5) < 1e-6 and abs(s["volume"] - 0.5) < 1e-6, "volume by idx 0")
    c.fire("track/setVolume", trackGuid="master", volume=0.25)
    wait_for(c, lambda m, s: abs(m["vol"] - 0.25) < 1e-6 and abs(s["volume"] - 0.25) < 1e-6, "volume by 'master'")
    c.fire("track/setPan", trackIdx=0, pan=-0.5)
    wait_for(c, lambda m, s: abs(m["pan"] + 0.5) < 1e-6 and abs(s["pan"] + 0.5) < 1e-6, "pan")
    c.fire("track/setMute", trackIdx=0)  # toggle on
    wait_for(c, lambda m, s: m["flags"] & 1 and s["mute"] is True, "mute toggle on")
    c.fire("track/setMute", trackIdx=0)  # toggle off
    wait_for(c, lambda m, s: not m["flags"] & 1 and s["mute"] is False, "mute toggle off")
    c.fire("track/setSolo", trackIdx=0)
    wait_for(c, lambda m, s: m["flags"] & 2 and s["solo"] != 0, "solo toggle on")
    c.fire("track/setSolo", trackIdx=0)
    wait_for(c, lambda m, s: not m["flags"] & 2 and s["solo"] == 0, "solo toggle off")

    for cmd in ("track/rename", "track/duplicate", "track/delete"):
        r = c.command(cmd, trackIdx=0, name="Bus")
        print(cmd, "on master:", r.get("success"), r.get("error"))
        assert not r["success"], f"{cmd} on master succeeded: {r}"
    assert reaper(MASTER)["tracks"] == 1
    assert reaper('local _, n = reaper.GetTrackName(reaper.GetMasterTrack(0)); return n') == "MASTER"
