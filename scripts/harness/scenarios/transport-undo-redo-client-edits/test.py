"""undo/do and redo/do reverse tempo and meter edits made from a phone, and edits made in REAPER.

The UI awaits undo/do and redo/do and shows the returned action. After each,
REAPER's own state must match (tempo, meter), the transport event must show
it, and the project event's canUndo/canRedo must be REAPER's.
"""
import time

from reamo_client import Client, reaper

STATE = "local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0); return {reaper.Master_GetTempo(), num, den}"


def settle(c, want_state, label):
    """Wait until REAPER, the transport event and the project event all agree."""
    deadline = time.time() + 2
    while True:
        c.drain(0.2)
        got = reaper(STATE)
        undo, redo = reaper("return reaper.Undo_CanUndo2(0)"), reaper("return reaper.Undo_CanRedo2(0)")
        tp = c.latest_event("transport")["payload"]
        pp = c.latest_event("project")["payload"]
        shown = [tp["bpm"], tp["timeSignature"]["numerator"], tp["timeSignature"]["denominator"]]
        ok = (got == want_state and shown == want_state and pp["canUndo"] == undo and pp["canRedo"] == redo)
        if ok or time.time() > deadline:
            break
    print(f"  {label:28s} REAPER {got} shown {shown} undo={undo!r} redo={redo!r}")
    problems = []
    if got != want_state:
        problems.append(f"{label}: REAPER is {got}, want {want_state}")
    if shown != got:
        problems.append(f"{label}: transport event shows {shown}, REAPER {got}")
    if (pp["canUndo"], pp["canRedo"]) != (undo, redo):
        problems.append(f"{label}: project event canUndo/canRedo {pp['canUndo']!r}/{pp['canRedo']!r}, REAPER {undo!r}/{redo!r}")
    return problems


with Client() as c:
    c.wait_event("project")
    problems = []
    problems += settle(c, [120, 4, 4], "start")

    c.fire("tempo/set", bpm=100)  # fire-and-forget, as QuickActionsPanel sends it
    problems += settle(c, [100, 4, 4], "tempo/set 100")
    r = c.command("timesig/set", numerator=6, denominator=8)
    assert r["success"], r
    problems += settle(c, [100, 6, 8], "timesig/set 6/8")

    r = c.command("undo/do")
    print("  undo/do ->", r)
    assert r["success"], r
    problems += settle(c, [100, 4, 4], "undo (meter)")
    r = c.command("undo/do")
    print("  undo/do ->", r)
    assert r["success"], r
    problems += settle(c, [120, 4, 4], "undo (tempo)")
    r = c.command("redo/do")
    print("  redo/do ->", r)
    assert r["success"], r
    problems += settle(c, [100, 4, 4], "redo (tempo)")

    # An edit made in REAPER, then undone from the phone.
    reaper("reaper.Undo_BeginBlock2(0); reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'B_MUTE', 1); reaper.Undo_EndBlock2(0, 'Mute Bass', -1)")
    r = c.command("undo/do")
    print("  undo/do ->", r)
    if r.get("action") != "Mute Bass":
        problems.append(f"undo/do of REAPER's 'Mute Bass' returned {r}")
    if reaper("return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'B_MUTE')") != 0:
        problems.append("undo/do did not unmute Bass in REAPER")

    # Undo until there is nothing left: the UI shows the error, nothing crashes.
    for _ in range(10):
        r = c.command("undo/do")
        if not r["success"]:
            break
    print("  final undo/do ->", r)
    if r.get("error", {}).get("code") != "NOTHING_TO_UNDO":
        problems.append(f"undo/do with an empty history returned {r}")
    assert not problems, "\n".join(problems)
