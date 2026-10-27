"""A track GUID a client has just received in trackSkeleton works in commands
straight away: the first fader move by GUID after opening the app is applied.

The UI's Fader, mute and solo buttons address tracks by GUID (locked at gesture
start), so a GUID the server can't resolve yet silently drops the user's input.
"""
from reamo_client import Client, reaper

MUTED = "return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, %d), 'B_MUTE')"

with Client() as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    guid = skel[2]["g"]
    r = c.command("track/setMute", trackGuid=guid, mute=1)
    print("first command by GUID:", r)
    assert r["success"], f"GUID {guid} from trackSkeleton not resolvable: {r}"
    assert reaper(MUTED % 1) == 1, "mute by GUID did not reach REAPER"
