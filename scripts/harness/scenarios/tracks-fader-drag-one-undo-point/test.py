"""A fader drag from the phone (gesture/start, a stream of setVolume, gesture/end)
leaves exactly one undo point, and one Undo in REAPER puts the fader back."""
import time

from reamo_client import Client, reaper

UNDO_STATE = "return reaper.Undo_CanUndo2(0) or '', reaper.GetProjectStateChangeCount(0)"
VOL = "return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'D_VOL')"


def undo_history_depth():
    # Count undo steps by undoing until nothing is left, then redoing all of them back.
    return reaper("""
local n = 0
while reaper.Undo_CanUndo2(0) do reaper.Undo_DoUndo2(0); n = n + 1 end
for _ = 1, n do reaper.Undo_DoRedo2(0) end
return n
""")


with Client() as c:
    guid = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    assert c.command("track/subscribe", range={"start": 0, "end": 2})["success"]
    c.drain(0.3)
    before_depth = undo_history_depth()
    start_vol = reaper(VOL)

    # The Fader component locks the GUID at gesture start and sends ~60 Hz updates.
    c.fire("gesture/start", controlType="volume", trackGuid=guid)
    for i in range(30):
        c.fire("track/setVolume", trackGuid=guid, volume=1.0 - i * 0.02)
        time.sleep(0.016)
    c.fire("gesture/end", controlType="volume", trackGuid=guid)

    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        if abs(reaper(VOL) - 0.42) < 1e-6:
            break
    final_vol = reaper(VOL)
    assert abs(final_vol - 0.42) < 1e-6, f"REAPER volume after drag: {final_vol}"
    shown = next(t for t in c.latest_event("tracks")["payload"]["tracks"] if t["g"] == guid)["volume"]
    assert abs(shown - final_vol) < 1e-6, f"tracks event shows {shown}, REAPER has {final_vol}"

    label, _ = reaper(UNDO_STATE)
    depth = undo_history_depth()
    print(f"undo depth {before_depth} -> {depth}, top: {label!r}")
    assert depth == before_depth + 1, f"drag made {depth - before_depth} undo points, want 1"
    assert "volume" in label.lower(), label

    reaper("reaper.Main_OnCommand(40029, 0)")  # Edit: Undo, as the user would in REAPER
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        shown = next(t for t in c.latest_event("tracks")["payload"]["tracks"] if t["g"] == guid)["volume"]
        if abs(shown - start_vol) < 1e-6:
            break
    assert abs(reaper(VOL) - start_vol) < 1e-6, f"after one Undo REAPER volume is {reaper(VOL)}, want {start_vol}"
    assert abs(shown - start_vol) < 1e-6, f"after Undo clients show {shown}, want {start_vol}"
