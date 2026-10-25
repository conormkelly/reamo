"""Send and receive edits from the phone each become their own undo point.

SendsTab wraps the drag in gesture/start(send) + send/setVolume... +
gesture/end. Afterwards REAPER's undo history must have a point for it, and
one undo must put the send back without undoing anything the user did before.
Same for the pan knob, a receive fader on the bus, and the one-tap mute and
mode buttons (sent without a gesture). Track volume is the control: it works.
"""
import time
from reamo_client import Client, reaper

UNDO = "return reaper.Undo_CanUndo2(0) or ''"
STATE = """
local t = reaper.GetTrack(0, 0)
local _, n = reaper.GetTrackName(t)
return n, reaper.GetTrackSendInfo_Value(t, 0, 0, 'D_VOL'), reaper.GetTrackSendInfo_Value(t, 0, 0, 'D_PAN'),
       reaper.GetMediaTrackInfo_Value(t, 'D_VOL'), reaper.GetTrackSendInfo_Value(t, 0, 0, 'B_MUTE'),
       reaper.GetTrackSendInfo_Value(t, 0, 0, 'I_SENDMODE')
"""


def user_rename(name):
    reaper(f"""
        reaper.Undo_BeginBlock()
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, 0), 'P_NAME', '{name}', true)
        reaper.Undo_EndBlock('{name}', -1)
    """)


problems = []
with Client() as c:
    c.wait_event("trackSkeleton")
    time.sleep(1.2)
    for label, ctl, cmd, idx_key, track, key, values in [
        ("track volume (control)", "volume", "track/setVolume", None, 1, "volume", [0.9, 0.8, 0.7]),
        ("send volume", "send", "send/setVolume", "sendIdx", 1, "volume", [0.9, 0.8, 0.7]),
        ("send pan", "sendPan", "send/setPan", "sendIdx", 1, "pan", [-0.1, -0.2, -0.3]),
        ("receive volume", "receive", "receive/setVolume", "recvIdx", 2, "volume", [0.6, 0.5, 0.4]),
        ("send mute tap", None, "send/setMute", "sendIdx", 1, "muted", [1]),
        ("send mode tap", None, "send/setMode", "sendIdx", 1, "mode", [1]),
    ]:
        user_rename(f"Vocals before {label}")
        before = reaper(STATE)
        idx = {idx_key: 0} if idx_key else {}
        if ctl:
            c.fire("gesture/start", controlType=ctl, trackIdx=track, **idx)
        for v in values:
            c.fire(cmd, trackIdx=track, **idx, **{key: v})
            time.sleep(0.03)
        if ctl:
            c.fire("gesture/end", controlType=ctl, trackIdx=track, **idx)
        c.drain(1.0)
        moved = reaper(STATE)
        top = reaper(UNDO)
        reaper("reaper.Undo_DoUndo2(0)")
        undone = reaper(STATE)
        print(f"{label:22s}: {before} -> {moved}; undo top {top!r}; one undo -> {undone}")
        if top == f"Vocals before {label}" or undone != before:
            problems.append(f"{label}: no undo point of its own (top of undo {top!r}); "
                            f"one undo gives {undone}, before the drag {before}")
        reaper("reaper.Undo_DoRedo2(0)")  # back to the dragged state for the next control
assert not problems, "\n".join(problems)
