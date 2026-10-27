"""The phone drops off Wi-Fi mid fader drag (no gesture/end): the drag still
becomes exactly one undo point, and one Undo restores the starting volume."""
import time

from reamo_client import Client, reaper

VOL = "return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'D_VOL')"
DEPTH = """
local n = 0
while reaper.Undo_CanUndo2(0) do reaper.Undo_DoUndo2(0); n = n + 1 end
for _ = 1, n do reaper.Undo_DoRedo2(0) end
return n
"""

before = reaper(DEPTH)
start = reaper(VOL)
a = Client()
guid = a.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
a.drain(1.2)
a.fire("gesture/start", controlType="volume", trackGuid=guid)
for i in range(15):
    a.fire("track/setVolume", trackGuid=guid, volume=1.0 - i * 0.04)
    time.sleep(0.016)
deadline = time.time() + 2
while abs(reaper(VOL) - 0.44) > 1e-6 and time.time() < deadline:
    a.drain(0.1)
a.close()  # finger still on the fader
time.sleep(1.5)

with Client() as b:  # the user picks the phone back up
    b.wait_event("trackSkeleton")
    depth = reaper(DEPTH)
    label = reaper("return reaper.Undo_CanUndo2(0) or ''")
    reaper("reaper.Main_OnCommand(40029, 0)")
    print(f"undo depth {before} -> {depth} ({label!r}); volume {start} -> 0.44 -> after Undo {reaper(VOL)}")
    assert depth == before + 1, f"dropped drag left {depth - before} undo points"
    assert abs(reaper(VOL) - start) < 1e-6, f"one Undo left the fader at {reaper(VOL)}"
