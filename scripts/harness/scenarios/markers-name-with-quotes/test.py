"""Marker and region names with quotes or backslashes reach REAPER as typed.

JSON escapes `"` as `\\"` and `\\` as `\\\\` on the wire (the browser does
too); REAPER must get the unescaped text, as item notes already do.
"""
import time
from reamo_client import Client, reaper

NAME = 'Take "2" \\ alt'

NAMES = """
local out = {}
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then break end
  out[#out + 1] = {isrgn and "region" or "marker", pos, name}
  i = i + 1
end
return out
"""

with Client() as c:
    c.wait_event("markers")
    c.fire("marker/update", id=1, name=NAME)
    c.fire("marker/add", position=20.0, name=NAME)
    c.fire("region/update", id=1, name=NAME)
    c.fire("region/add", start=24.0, end=28.0, name=NAME)
    deadline = time.time() + 2
    while True:
        got = reaper(NAMES)
        if (len(got) == 4 and all(n != "Intro" and n != "Verse" for _, _, n in got)) or time.time() > deadline:
            break
        time.sleep(0.1)
    c.drain(0.5)
    shown = [m["name"] for m in c.latest_event("markers")["payload"]["markers"]] + \
            [r["name"] for r in c.latest_event("regions")["payload"]["regions"]]
    print("  REAPER:", [n for _, _, n in got])
    print("  clients:", shown)
    bad = [f"{k} @{p}: {n!r}" for k, p, n in got if n != NAME]
    assert not bad, f"phone typed {NAME!r}, REAPER holds:\n  " + "\n  ".join(bad)
