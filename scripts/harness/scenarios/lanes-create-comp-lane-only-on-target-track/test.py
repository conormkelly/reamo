"""lanes/createCompLane adds a comp lane to the track it names, and only that track.

"Track lanes: Insert new comp lane" acts on every selected track. The phone
asks for a comp lane on "Vox" while the user has "Gtr" selected in REAPER:
Gtr must keep its lanes, and the user's track selection should be as it was.
"""
import time
from reamo_client import Client, reaper

STATE = """
local out = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i)
  local _, n = reaper.GetTrackName(t)
  out[n] = {reaper.GetMediaTrackInfo_Value(t, "I_NUMFIXEDLANES"), reaper.IsTrackSelected(t)}
end
return out
"""

with Client() as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    vox = next(t["g"] for t in skel if t["n"] == "Vox")
    before = reaper(STATE)
    print("before:", before)
    deadline = time.time() + 3
    while True:  # the track GUID cache fills shortly after connect
        r = c.command("lanes/createCompLane", trackGuid=vox)
        if r["success"] or time.time() > deadline:
            break
        time.sleep(0.1)
    assert r["success"], r
    c.drain(0.3)
    after = reaper(STATE)
    print("after: ", after)
    assert after["Vox"][0] == before["Vox"][0] + 1, f"Vox did not get a comp lane: {after}"
    assert after["Gtr"][0] == before["Gtr"][0], \
        f"a comp lane asked for on Vox was also added to the selected track Gtr: {before['Gtr'][0]} -> {after['Gtr'][0]} lanes"
    assert [after[n][1] for n in ("Vox", "Gtr")] == [False, True], \
        f"track selection changed: Vox/Gtr selected = {after['Vox'][1]}/{after['Gtr'][1]}"
