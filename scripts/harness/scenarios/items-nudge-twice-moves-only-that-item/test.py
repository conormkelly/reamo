"""A double-tapped nudge moves only the nudged item.

NavigateItemInfoBar's nudge sends item/moveByGuid {guid, position}. Moving
item A past item B reorders the track (REAPER keeps a track's items sorted by
position at once), so A's index changes. A second tap before the next items
event must still move A, never B, whose GUID the user never touched.
"""
import time
from reamo_client import Client, reaper

POS = """
local t = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.CountTrackMediaItems(t) - 1 do
  local it = reaper.GetTrackMediaItem(t, i)
  local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)
  out[g] = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
end
return out
"""
RESET = """
local t = reaper.GetTrack(0, 0)
for i = 0, reaper.CountTrackMediaItems(t) - 1 do
  local it = reaper.GetTrackMediaItem(t, i)
  local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", g == "%s" and 1 or 2)
end
reaper.UpdateArrange()
"""

with Client() as c:
    items = sorted(c.wait_event("items")["payload"]["items"], key=lambda i: i["position"])
    a, b = items[0]["guid"], items[1]["guid"]
    bad = []
    for trial in range(5):
        reaper(RESET % a)
        c.drain(0.6)  # let an items poll see the reset order (A first)
        # The phone shows A at 1.0; each tap sends 1.0 + 1.5 (its stale position + nudge).
        c.fire("item/moveByGuid", guid=a, position=2.5)
        c.fire("item/moveByGuid", guid=a, position=2.5)
        deadline = time.time() + 2
        while True:
            pos = reaper(POS)
            if pos[a] == 2.5 or time.time() > deadline:
                break
            time.sleep(0.05)
        c.drain(0.3)
        pos = reaper(POS)
        print(f"  trial {trial}: A={pos[a]} B={pos[b]}")
        if pos[b] != 2.0 or pos[a] != 2.5:
            bad.append(f"trial {trial}: A at {pos[a]}, B at {pos[b]} (B was never nudged; it should stay at 2.0)")
    assert not bad, "\n".join(bad)
