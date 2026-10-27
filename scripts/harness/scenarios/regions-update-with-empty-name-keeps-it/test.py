"""region/update with name "" keeps the region's name, as API.md documents for
marker and region updates (an empty name means "unchanged"); RegionInfoBar
only sends non-empty names. The rename before it lands whole in REAPER and
reaches clients."""
import time
from reamo_client import Client, reaper

REGION_1 = """
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then return nil end
  if isrgn and id == 1 then return name end
  i = i + 1
end
"""

with Client() as c:
    c.wait_event("regions")
    c.fire("region/update", id=1, name="Verse 2")
    deadline = time.time() + 2
    while reaper(REGION_1) != "Verse 2" and time.time() < deadline:
        time.sleep(0.1)
    assert reaper(REGION_1) == "Verse 2", reaper(REGION_1)

    c.fire("region/update", id=1, name="")
    c.fire("region/update", id=1, end=12.0)  # a resize sends no name at all
    time.sleep(0.5)
    name = reaper(REGION_1)
    c.drain(0.5)
    shown = c.latest_event("regions")["payload"]["regions"][0]["name"]
    print(f"REAPER name {name!r}, clients show {shown!r}")
    assert name == "Verse 2", f"region renamed to {name!r} by an update that sent no name"
    assert shown == "Verse 2", shown
