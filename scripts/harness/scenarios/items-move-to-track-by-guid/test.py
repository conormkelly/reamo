"""Moving an item to another track from the track picker lands it there, by GUID.

NavigateItemInfoBar's track picker sends item/moveByGuid {guid, destTrackGuid}.
The user first reorders tracks in REAPER (so indices the phone saw are stale),
then moves the second Gtr item to "Bass". The items event must follow.
"""
import time
from reamo_client import Client, reaper

WHERE = """
local out = {}
for i = 0, reaper.CountMediaItems(0) - 1 do
  local it = reaper.GetMediaItem(0, i)
  local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)
  local _, tn = reaper.GetTrackName(reaper.GetMediaItem_Track(it))
  out[g] = {tn, reaper.GetMediaItemInfo_Value(it, "D_POSITION")}
end
return out
"""

with Client() as c:
    items = sorted(c.wait_event("items")["payload"]["items"], key=lambda i: i["position"])
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    bass = next(t["g"] for t in skel if t["n"] == "Bass")
    second = items[1]["guid"]
    # The user drags Bass to the top in REAPER.
    reaper("reaper.SetOnlyTrackSelected(reaper.GetTrack(0, 2)); reaper.ReorderSelectedTracks(0, 0)")
    c.drain(1.2)
    deadline = time.time() + 3
    while True:
        r = c.command("item/moveByGuid", guid=second, destTrackGuid=bass)
        if r["success"] or time.time() > deadline:
            break
        time.sleep(0.1)
    print("moveByGuid:", r)
    assert r["success"], r
    w = reaper(WHERE)
    print("REAPER:", w)
    assert w[second] == ["Bass", 4], w[second]
    assert sorted(v[0] for v in w.values()) == ["Bass", "Gtr"], w
    deadline = time.time() + 2
    while True:
        c.drain(0.2)
        ev = {i["guid"]: i for i in c.latest_event("items")["payload"]["items"]}
        if ev[second]["trackIdx"] == 1 or time.time() > deadline:
            break
    print("items event:", {g[:9]: (i["trackIdx"], i["itemIdx"]) for g, i in ev.items()})
    assert ev[second]["trackIdx"] == 1, ev[second]  # Bass is now track 1
