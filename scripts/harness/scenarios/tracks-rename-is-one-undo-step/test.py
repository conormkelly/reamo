"""Renaming a track from the phone is its own undo step: one Undo in REAPER
restores the old name and leaves the earlier edit in place."""
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
    assert c.command("track/setColor", trackIdx=1, color=0x1000000 | 0xFF0000)["success"]
    before = reaper(STATE)
    assert c.command("track/rename", trackIdx=2, name="Bass DI")["success"]
    renamed = reaper(STATE)
    label = reaper("return reaper.Undo_CanUndo2(0) or ''")
    print("before:", before, "\nrenamed:", renamed, "\nundo menu says:", repr(label))
    assert renamed[1].startswith("Bass DI#"), renamed
    reaper("reaper.Main_OnCommand(40029, 0)")
    after = reaper(STATE)
    print("after one Undo:", after)
    reaper("reaper.Main_OnCommand(40030, 0)")  # Edit: Redo
    print("after Redo:", reaper(STATE))
    assert after == before, f"one Undo after a rename left {after}, want {before}"
