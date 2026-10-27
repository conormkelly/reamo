"""Creating a track from the phone is its own undo step: Undo in REAPER removes
just the new track and leaves the user's earlier edit (a colour change) alone."""
import time

from reamo_client import Client, reaper

STATE = """
local t = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, n = reaper.GetTrackName(tr)
  t[#t + 1] = n .. "#" .. math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"))
end
return t
"""

with Client() as c:
    c.wait_event("trackSkeleton")
    # An earlier edit the user cares about.
    assert c.command("track/setColor", trackIdx=1, color=0x1000000 | 0xFF0000)["success"]
    before = reaper(STATE)
    r = c.command("track/create", name="Keys")
    assert r["success"] and r["payload"]["trackIdx"] == 3, r
    created = reaper(STATE)
    label = reaper("return reaper.Undo_CanUndo2(0) or ''")
    print("before:", before, "\ncreated:", created, "\nundo menu says:", repr(label))
    assert created[:2] == before and created[2].startswith("Keys#"), created

    reaper("reaper.Main_OnCommand(40029, 0)")  # Edit: Undo
    after = reaper(STATE)
    print("after one Undo:", after)
    reaper("reaper.Main_OnCommand(40030, 0)")  # Edit: Redo
    print("after Redo:", reaper(STATE))
    reaper("reaper.Main_OnCommand(40029, 0)")
    assert after == before, f"one Undo after creating a track left {after}, want {before}"
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        ev = c.latest_event("trackSkeleton")
        names = [t["n"] for t in ev["payload"]["tracks"]] if ev else None
        if names == ["MASTER", "Drums", "Bass"]:
            break
    assert names == ["MASTER", "Drums", "Bass"], names
