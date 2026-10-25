"""Resizing a region from a phone keeps the name the user typed in REAPER.

RegionInfoBar sends region/update with only `start` or `end`; the name must
come back from REAPER untouched.
"""
import time
from reamo_client import Client, reaper

NAME = "Bridge (alt) - strings enter at bar 3, keep the pad low until the drop"
assert len(NAME.encode()) > 64

REGION_1 = """
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then return nil end
  if isrgn and id == 1 then return {pos, rend, name} end
  i = i + 1
end
"""

with Client() as c:
    c.wait_event("regions")
    c.fire("region/update", id=1, end=16.0)
    deadline = time.time() + 2
    while True:
        start, end, name = reaper(REGION_1)
        if end == 16.0 or time.time() > deadline:
            break
        time.sleep(0.1)
    print("after resize:", start, end, repr(name))
    assert end == 16.0, end
    assert name == NAME, f"resizing the region renamed it in REAPER to {name!r} ({len(name.encode())} bytes)"
