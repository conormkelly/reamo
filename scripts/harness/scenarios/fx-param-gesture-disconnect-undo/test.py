"""A phone that drops off mid FX-parameter drag doesn't leave REAPER's undo open.

FxParamModal wraps a slider drag in gesture/start + trackFxParams/set... +
gesture/end (controlType fxParam). If the phone disconnects before
gesture/end, the extension must close the drag's undo block: the user's next
edit in REAPER must still get its own undo point.
"""
import time
from reamo_client import Client, reaper

PARAM = "return reaper.TrackFX_GetParamNormalized(reaper.GetTrack(0, 0), 0, 0)"
UNDO = "return reaper.Undo_CanUndo2(0) or ''"


def user_edit(name):
    """The user renames the track in REAPER: one undo point named `name`."""
    reaper(f"""
        reaper.Undo_BeginBlock()
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, 0), 'P_NAME', '{name}', true)
        reaper.Undo_EndBlock('{name}', -1)
    """)
    return reaper(UNDO)


def drag(c, g, fx, values, pause=0.0, end=True):
    c.fire("gesture/start", controlType="fxParam", trackGuid=g, fxGuid=fx, paramIdx=0)
    for i, v in enumerate(values):
        c.fire("trackFxParams/set", trackGuid=g, fxGuid=fx, paramIdx=0, value=v)
        time.sleep(0.03)
        if pause and i == 0:
            time.sleep(pause)  # finger held still
    if end:
        c.fire("gesture/end", controlType="fxParam", trackGuid=g, fxGuid=fx, paramIdx=0)
    c.drain(0.4)


problems = []
with Client() as d:
    g = d.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert d.command("trackFx/subscribe", trackGuid=g)["success"]
    fx = d.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]
    assert user_edit("Bass DI") == "Bass DI"
    drag(d, g, fx, [0.8, 0.85], end=False)  # the phone drops off mid-drag
time.sleep(1.0)
got = user_edit("Bass Synth")
print("dropped mid-drag: user edit afterwards: undo =", repr(got), " param =", reaper(PARAM))
assert got == "Bass Synth", f"phone dropped mid-drag: the user's next edit has no undo point (top of undo is {got!r})"
reaper("reaper.Undo_DoUndo2(0)")
print("after undoing the edit: name =", reaper("local _, n = reaper.GetTrackName(reaper.GetTrack(0, 0)); return n"),
      "undo =", repr(reaper(UNDO)))
