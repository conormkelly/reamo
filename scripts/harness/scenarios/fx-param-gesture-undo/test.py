"""An FX-parameter drag is one undo point, and never leaves REAPER's undo open.

FxParamModal wraps a slider drag in gesture/start + trackFxParams/set... +
gesture/end (controlType fxParam). The drag must undo as one step. A finger
held still mid-drag (no sets for over 0.5 s, the gesture timeout) must not
leave an undo block open: the user's next edit in REAPER must still get its
own undo point.
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
with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    fx = c.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]

    drag(c, g, fx, [0.55, 0.6, 0.65, 0.7])
    print("clean drag: undo =", repr(reaper(UNDO)), "param =", reaper(PARAM))
    reaper("reaper.Undo_DoUndo2(0)")
    after = reaper(PARAM)
    print("  after one undo: param =", after)
    if abs(after - 0.5) > 1e-6:
        problems.append(f"clean drag: one undo leaves the param at {after}, not 0.5")
    got = user_edit("Bass DI")
    print("  user edit afterwards: undo =", repr(got))
    if got != "Bass DI":
        problems.append(f"clean drag: the user's next edit has no undo point (top of undo is {got!r})")

    drag(c, g, fx, [0.3, 0.35, 0.4], pause=1.0)
    print("held-still drag: undo =", repr(reaper(UNDO)), "param =", reaper(PARAM))
    got = user_edit("Bass Amp")
    print("  user edit afterwards: undo =", repr(got))
    if got != "Bass Amp":
        problems.append(f"drag with a 1 s pause: the user's next edit has no undo point (top of undo is {got!r})")

assert not problems, "\n".join(problems)
