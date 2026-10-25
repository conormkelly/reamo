"""Switching to a project much bigger than the last one keeps REAmo running.

On a project change REAmo resizes its per-tier memory arenas to the new
project's entity counts. The tier's state structs live inside those
arenas, and the poll that resized them went on using the old ones.
"""
import time
from reamo_client import Client, reaper

BUILD = """
reaper.Main_OnCommand(40859, 0) -- new project tab
for i = 1, 1000 do
  reaper.InsertTrackAtIndex(i - 1, false)
  local t = reaper.GetTrack(0, i - 1)
  do
    for j = 0, 9 do
      local it = reaper.AddMediaItemToTrack(t)
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", j * 2)
      reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 1.5)
    end
  end
end
for i = 0, 299 do
  reaper.AddProjectMarker(0, false, i * 3, 0, "M" .. i, -1)
  reaper.AddProjectMarker(0, true, i * 3, i * 3 + 2, "R" .. i, -1)
end
reaper.UpdateArrange()
return reaper.CountTracks(0)
"""

with Client(timeout=15) as c:
    c.wait_event("trackSkeleton")
    assert reaper(BUILD, timeout=120) == 1000
    deadline = time.time() + 30
    while True:
        c.drain(0.5)
        skel = c.latest_event("trackSkeleton")
        if skel and len(skel["payload"]["tracks"]) == 1001:
            break
        assert time.time() < deadline, "the bigger project's track list never arrived"
    # Switch away and back: each switch is a project change, now between
    # projects whose sizes differ by far more than the resize threshold.
    for _ in range(2):
        reaper("reaper.Main_OnCommand(40862, 0)")  # previous tab (the small one)
        c.drain(2)
        reaper("reaper.Main_OnCommand(40861, 0)")  # next tab (the big one)
        c.drain(2)
        assert c.command("debug/memoryStats")["success"]
    log = reaper("local f = io.open(reaper.GetResourcePath() .. '/Logs/reamo.log'); local s = f:read('a'); f:close(); return s")
    print("\n".join(l for l in log.splitlines() if "roject" in l or "rena" in l or "entities" in l))
    resizes = log.count("Resizing arenas")
    print(f"arena resizes: {resizes}")
    assert resizes >= 2, "the switches didn't resize the arenas, so this tested nothing"
