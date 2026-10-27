"""Resetting a region's colour from the phone keeps its Region Render Matrix routing.

RegionInfoBar sends region/update {id, color: 0} for "reset to default".
Only the colour may change, and only as REAPER's own "Set region to default
color" changes it (the custom flag cleared): the region's render matrix
assignments (which stems a user has set up to render for it) must survive.
"""
import time
from reamo_client import Client, reaper

STATE = """
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id, color = reaper.EnumProjectMarkers3(0, i)
  if ok == 0 then return nil end
  if isrgn and id == 1 then
    local routed = {}
    local j = 0
    while true do
      local t = reaper.EnumRegionRenderMatrix(0, 1, j)
      if not t then break end
      local _, nm = reaper.GetTrackName(t)
      routed[#routed + 1] = nm
      j = j + 1
    end
    return {pos = pos, rend = rend, name = name, color = color, routed = routed}
  end
  i = i + 1
end
"""

with Client() as c:
    c.wait_event("regions")
    before = reaper(STATE)
    print("before:", before)
    assert before["routed"] == ["Drums", "Vox"], before
    c.fire("region/update", id=1, color=0)
    deadline = time.time() + 2
    while True:
        after = reaper(STATE)
        if (after and not after["color"] & 0x1000000) or time.time() > deadline:
            break
        time.sleep(0.1)
    print("after: ", after)
    assert not after["color"] & 0x1000000, f"colour not reset: {after}"
    assert (after["pos"], after["rend"], after["name"]) == (4, 12, "Chorus"), after
    assert after["routed"] == ["Drums", "Vox"], \
        f"colour reset dropped the region's render matrix routing: {before['routed']} -> {after['routed']}"
