"""A fader drag where the finger rests mid-drag for over a second, then moves on.

REAMo keeps the gesture open (no gesture timeout fires), but REAPER itself
commits control-surface volume changes after about a second without
movement, exactly as it does for a hardware fader held still, so the drag
can become two "Adjust track volume (via surface)" steps. What must hold:
at most two steps, each moving only this fader, and undoing them restores
the starting volume."""
import time

from reamo_client import Client, reaper

VOL = "return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'D_VOL')"


def undo_history_depth():
    return reaper("""
local n = 0
while reaper.Undo_CanUndo2(0) do reaper.Undo_DoUndo2(0); n = n + 1 end
for _ = 1, n do reaper.Undo_DoRedo2(0) end
return n
""")


def wait_vol(c, want):
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.1)
        if abs(reaper(VOL) - want) < 1e-6:
            return
    raise AssertionError(f"REAPER volume {reaper(VOL)}, want {want}")


with Client() as c:
    guid = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    assert c.command("track/subscribe", range={"start": 0, "end": 2})["success"]  # the mixer view
    c.drain(0.3)
    before = undo_history_depth()
    start_vol = reaper(VOL)

    c.fire("gesture/start", controlType="volume", trackGuid=guid)
    for i in range(10):
        c.fire("track/setVolume", trackGuid=guid, volume=1.0 - i * 0.03)
        time.sleep(0.016)
    wait_vol(c, 0.73)
    time.sleep(1.2)  # finger resting on the fader, still down
    for i in range(10):
        c.fire("track/setVolume", trackGuid=guid, volume=0.70 - i * 0.03)
        time.sleep(0.016)
    c.fire("gesture/end", controlType="volume", trackGuid=guid)
    wait_vol(c, 0.43)
    c.drain(1.0)

    depth = undo_history_depth()
    steps = []
    for _ in range(depth - before):
        steps.append(reaper("return reaper.Undo_CanUndo2(0) or ''"))
        reaper("reaper.Main_OnCommand(40029, 0)")
    after_undo = reaper(VOL)
    print(f"undo steps for the drag: {steps}; volume start {start_vol}, after undoing them {after_undo}")
    assert 1 <= len(steps) <= 2, f"one drag made {len(steps)} undo points"
    assert all(label == "Adjust track volume (via surface)" for label in steps), steps
    assert abs(after_undo - start_vol) < 1e-6, f"undoing the drag left the fader at {after_undo}, want {start_vol}"
