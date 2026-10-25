"""A region name ending in a backslash does not break region/batch.

On the wire the name "Gtr \\" is `"Gtr \\\\"`: the closing quote follows a
backslash that is itself escaped. Every op must still apply, and REAPER must
get the name as typed.
"""
from reamo_client import Client, reaper

STATE = """
local out = {}
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then break end
  if isrgn then out[#out + 1] = string.format("%d:%s@%g-%g", id, name, pos, rend) end
  i = i + 1
end
table.sort(out)
return table.concat(out, " ")
"""

with Client() as c:
    c.wait_event("regions")
    r = c.command("region/batch", ops=[
        {"op": "update", "id": 2, "name": "Gtr \\"},
        {"op": "update", "id": 3, "start": 16, "end": 28},
    ])
    print("response:", r.get("payload"), r.get("error"))
    got = reaper(STATE)
    print("REAPER:", got)
    assert r["success"], r
    assert got == "1:Intro@0-8 2:Gtr \\@8-16 3:Chorus@16-28", got
