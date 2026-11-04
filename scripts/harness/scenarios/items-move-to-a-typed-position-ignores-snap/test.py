"""A position sent from the phone is where the item lands, snap on or off.

REAPER's snapping applies to mouse edits. Its nudge (ApplyNudge) doesn't
look at the snap toggle: an item nudged off the grid stays off the grid
with snapping on. Only ApplyNudge's own snap flag snaps (checked here, so
the grid is known to be in effect), so a move that follows REAPER's rules
passes no snap flag and a typed 2.3 s lands at 2.3 s.

REAmo already does this; the check keeps it so when moves follow REAPER's
ripple and grouping (RV1-39).
"""
from reamo_client import Client, reaper
import item_moves as im

FROM, TO = 1.0, 2.3  # a1's start, and a typed position off the 1/4 grid
GRID = "reaper.SetProjectGrid(0, 0.25)"

with Client() as c:
    c.wait_event("items")

    # Snapping is in effect: ApplyNudge's snap flag moves a1 off 2.3.
    im.setup(grouping=0, snap=1, lua=GRID)
    reaper(f"reaper.SetMediaItemSelected(MOVE_ITEMS.a1, true); reaper.ApplyNudge(0, 3, 0, 1, {TO}, false, 0)")
    snapped = im.state()["a1"][1]
    print(f"ApplyNudge with its snap flag, to {TO}: a1@{snapped:.6f}")
    assert abs(snapped - TO) > 1e-6, f"the grid didn't snap a1: it is at {snapped}"

    for snap in (0, 1):
        im.setup(grouping=0, snap=snap, lua=GRID)
        assert reaper(f"return reaper.GetToggleCommandState({im.SNAP})") == snap
        want = im.reaper_move("a1", TO - FROM)
        assert abs(want["a1"][1] - TO) < 1e-9, f"REAPER's nudge, snap {snap}: a1 at {want['a1'][1]}, not {TO}"

        im.setup(grouping=0, snap=snap, lua=GRID)
        r, got = im.reamo_move(c, "a1", TO)
        assert r["success"], r
        print(f"snap {snap}: REAPER a1@{want['a1'][1]:.6f}, REAmo a1@{got['a1'][1]:.6f}")
        assert not im.diff(want, got), f"snap {snap}:\n" + "\n".join(im.diff(want, got))
