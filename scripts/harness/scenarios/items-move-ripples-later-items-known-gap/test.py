"""Known gap (RV1-39): nudging an item from the phone ignores REAPER's ripple editing.

With ripple editing on, REAPER's nudge moves what comes after an item along
with it (grouping off here, so groups don't blur the rule):

- per track: the later items on the moved item's track (a2, a3);
- all tracks: every item that starts at or after the moved item's start, on
  every track (a2, a3, b1, b2).

Ripple on all tracks can move markers too (REAPER 7.83 moves m7 here; 6.0
doesn't with this fixture). That is REAPER's call, so the marker is printed,
not checked.

The phone's nudge buttons send item/moveByGuid with the item's start plus
the nudge, which sets the one item's position, so nothing ripples. With
ripple off REAmo already matches.

REAPER's set-position nudge (ApplyNudge flag 1) moves the item alone, ripple
or not; this pins that too. Which of the two a typed "move to" position
should follow is RV1-39's open design question.

When REAmo's nudge ripples, the known-gap assertion fails: make it assert a
match with REAPER instead.
"""
from reamo_client import Client, reaper
import item_moves as im

FROM, TO = 1.0, 2.5  # a1's start, and where the nudge takes it
DELTA = TO - FROM
A1_ALONE = {"a1": ("A", TO)}
RIPPLED = {
    "per-track": {"a1", "a2", "a3"},
    "all-tracks": {"a1", "a2", "a3", "b1", "b2"},
}
MARKER = "marker m7"

with Client() as c:
    c.wait_event("items")
    im.setup()
    before = im.state()

    im.setup(ripple="off", grouping=0)
    want = im.reaper_move("a1", DELTA)
    im.setup(ripple="off", grouping=0)
    r, got = im.reamo_move(c, "a1", TO)
    assert r["success"], r
    assert im.moved_exactly(before, want, A1_ALONE), im.moved(before, want)
    assert not im.diff(want, got), "ripple off:\n" + "\n".join(im.diff(want, got))

    gaps = []
    for mode, rippled in RIPPLED.items():
        im.setup(ripple=mode, grouping=0)
        want = im.reaper_move("a1", DELTA)
        print(f"REAPER, ripple {mode}:", im.moved(before, want))
        expected = {k: (before[k][0], before[k][1] + DELTA) for k in rippled}
        items_before = {k: v for k, v in before.items() if k != MARKER}
        assert im.moved_exactly(items_before, want, expected), f"REAPER, ripple {mode}: {im.moved(before, want)}"

        im.setup(ripple=mode, grouping=0)
        reaper(f"reaper.SetMediaItemSelected(MOVE_ITEMS.a1, true); reaper.ApplyNudge(0, 1, 0, 1, {TO}, false, 0)")
        set_to = im.state()
        assert im.moved_exactly(before, set_to, A1_ALONE), \
            f"REAPER's set-position nudge, ripple {mode}: {im.moved(before, set_to)}"

        im.setup(ripple=mode, grouping=0)
        r, got = im.reamo_move(c, "a1", TO)
        assert r["success"], r
        print(f"REAmo, ripple {mode}:", im.moved(before, got))
        if not im.moved_exactly(before, got, A1_ALONE):
            gaps.append(f"ripple {mode}:\n" + "\n".join(im.diff(want, got) or ["  matches REAPER"]))

    # Known gap: a1 moves alone in both ripple modes.
    assert not gaps, "REAmo no longer moves a1 alone. If it now matches REAPER, the known gap is " \
        "fixed: assert a match here instead.\n" + "\n".join(gaps)
