"""Phone A drags the Guitar fader (GUID-locked, as Fader.tsx does) while phone B
inserts a track at the top, shifting Guitar's index mid-drag.

REAPER has one undo history, so B's insert lands between the parts of A's
drag. What must hold: every undo step belongs to one phone's edit (never
undoes the other phone's insert along with a fader move), the drag still
targets Guitar after the index shift, and undoing everything restores the
start."""
import time

from reamo_client import Client, reaper

VOL = """
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i); local _, n = reaper.GetTrackName(t)
  if n == "Guitar" then return reaper.GetMediaTrackInfo_Value(t, "D_VOL") end
end
"""
DEPTH = """
local n = 0
while reaper.Undo_CanUndo2(0) do reaper.Undo_DoUndo2(0); n = n + 1 end
for _ = 1, n do reaper.Undo_DoRedo2(0) end
return n
"""

with Client() as a, Client() as b:
    guid = a.wait_event("trackSkeleton")["payload"]["tracks"][2]["g"]
    b.wait_event("trackSkeleton")
    a.drain(1.2)
    start = reaper(VOL)

    a.fire("gesture/start", controlType="volume", trackGuid=guid)
    for i in range(8):
        a.fire("track/setVolume", trackGuid=guid, volume=1.0 - i * 0.05)
        time.sleep(0.016)
    r = b.command("track/create", name="Click", afterTrackIdx=0)  # B, mid-drag
    assert r["success"], r
    before = None
    for i in range(8, 16):
        a.fire("track/setVolume", trackGuid=guid, volume=1.0 - i * 0.05)
        time.sleep(0.016)
    a.fire("gesture/end", controlType="volume", trackGuid=guid)
    deadline = time.time() + 2
    while abs(reaper(VOL) - 0.25) > 1e-6 and time.time() < deadline:
        a.drain(0.1)
    a.drain(1.0)
    assert abs(reaper(VOL) - 0.25) < 1e-6, f"Guitar volume {reaper(VOL)} after drag"

    TRACKS = "local t = {} for i = 0, reaper.CountTracks(0) - 1 do local _, n = reaper.GetTrackName(reaper.GetTrack(0, i)); t[#t + 1] = n end return t"
    steps = []
    while True:
        label = reaper("return reaper.Undo_CanUndo2(0) or ''")
        if label in ("", None) or len(steps) > 6:
            break
        vol0, names0 = reaper(VOL), reaper(TRACKS)
        reaper("reaper.Main_OnCommand(40029, 0)")
        vol1, names1 = reaper(VOL), reaper(TRACKS)
        steps.append((label, abs(vol1 - vol0) > 1e-9, names1 != names0))
        if abs(vol1 - start) < 1e-9 and "Click" not in names1:
            break
    print("undo steps (label, moved fader, changed tracks):", steps)
    for label, moved, changed in steps:
        assert not (moved and changed), f"undo step {label!r} reverted both phones' edits at once"
    assert abs(reaper(VOL) - start) < 1e-9 and "Click" not in reaper(TRACKS), "undoing everything did not restore the start"
