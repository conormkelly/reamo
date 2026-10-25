"""region/batch applies a region-editor session as REAPER would, in one undo step.

The ops a region editor produces when the user swaps Verse and Chorus,
deletes Intro and adds an Outro. Every op lands, the response counts them, and one undo
in REAPER restores the original regions.
"""
import time
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
ORIGINAL = "1:Intro@0-8 2:Verse@8-16 3:Chorus@16-24"

with Client() as c:
    c.wait_event("regions")
    assert reaper(STATE) == ORIGINAL, reaper(STATE)
    ops = [
        {"op": "update", "id": 3, "start": 8, "end": 16},
        {"op": "update", "id": 2, "start": 16, "end": 24, "name": "Verse 2"},
        {"op": "delete", "id": 1},
        {"op": "create", "start": 24, "end": 32, "name": "Outro"},
        {"op": "delete", "id": 99},
    ]
    r = c.command("region/batch", ops=ops)
    print("response:", r.get("payload"), r.get("error"))
    assert r["success"], r
    got = reaper(STATE)
    print("REAPER:", got)
    assert got == "1:Outro@24-32 2:Verse 2@16-24 3:Chorus@8-16", got  # REAPER reuses the freed number 1
    assert r["payload"]["applied"] == 4 and r["payload"]["skipped"] == 1, r["payload"]

    reaper("reaper.Undo_DoUndo2(0)")
    got = reaper(STATE)
    print("after one undo:", got)
    assert got == ORIGINAL, f"one undo left {got}"
