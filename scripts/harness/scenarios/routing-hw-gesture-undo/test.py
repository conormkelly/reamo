"""Send and hardware-output fader drags undo as one step and never leave REAPER's undo open.

SendsTab / the hardware-output fader wrap a drag in gesture/start + set... +
gesture/end. Each drag must be one undo step; a drag held still past the
gesture timeout, or a phone that drops mid-drag, must still let the user's
next edit in REAPER get its own undo point.
"""
import time
from reamo_client import Client, reaper

UNDO = "return reaper.Undo_CanUndo2(0) or ''"
VOLS = """
local t = reaper.GetTrack(0, 0)
return reaper.GetTrackSendInfo_Value(t, 1, 0, 'D_VOL'), reaper.GetTrackSendInfo_Value(t, 0, 0, 'D_VOL')
"""
n_edit = [0]


def user_edit():
    n_edit[0] += 1
    name = f"Click {n_edit[0]}"
    reaper(f"""
        reaper.Undo_BeginBlock()
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, 0), 'P_NAME', '{name}', true)
        reaper.Undo_EndBlock('{name}', -1)
    """)
    return name, reaper(UNDO)


def drag(c, kind, values, pause=0.0, end=True):
    ctl, cmd, key = {"hw": ("hwOutputVolume", "hw/setVolume", "hwIdx"),
                     "send": ("send", "send/setVolume", "sendIdx")}[kind]
    c.fire("gesture/start", controlType=ctl, trackIdx=1, **{key: 0})
    for i, v in enumerate(values):
        c.fire(cmd, trackIdx=1, volume=v, **{key: 0})
        time.sleep(0.03)
        if pause and i == 0:
            time.sleep(pause)
    if end:
        c.fire("gesture/end", controlType=ctl, trackIdx=1, **{key: 0})
    c.drain(0.4)


problems = []
with Client() as c:
    c.wait_event("trackSkeleton")
    time.sleep(1.2)
    for kind in ("hw", "send"):
        for label, pause in (("clean", 0.0), ("held still", 1.0)):
            before = reaper(VOLS)
            drag(c, kind, [0.9, 0.8, 0.7], pause=pause)
            top = reaper(UNDO)
            reaper("reaper.Undo_DoUndo2(0)")
            undone = reaper(VOLS)
            name, got = user_edit()
            print(f"{kind:4s} {label:10s}: undo top {top!r}; one undo -> {undone} (before {before}); next edit -> {got!r}")
            if undone != before:
                problems.append(f"{kind} {label}: one undo gives {undone}, before the drag {before}")
            if got != name:
                problems.append(f"{kind} {label}: the user's next edit has no undo point (top is {got!r})")
for kind in ("hw", "send"):
    with Client() as d:
        d.wait_event("trackSkeleton")
        drag(d, kind, [0.5, 0.4], end=False)
    time.sleep(1.0)
    name, got = user_edit()
    print(f"{kind:4s} dropped mid-drag: next edit -> {got!r}")
    if got != name:
        problems.append(f"{kind} dropped mid-drag: the user's next edit has no undo point (top is {got!r})")
assert not problems, "\n".join(problems)
