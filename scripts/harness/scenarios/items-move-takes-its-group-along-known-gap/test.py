"""Known gap (RV1-39): nudging a grouped item from the phone leaves the rest of its group behind.

With item grouping on, REAPER's nudge of a grouped item moves its whole
group: a1 and b1, its group-mate on another track, move by the same amount.
If any member is locked, REAPER moves none of them.

The phone's nudge buttons send item/moveByGuid with the item's start plus
the nudge, which sets the one item's position, so a1 moves alone and b1
stays put, and a locked b1 doesn't stop it. With grouping off, or a1 itself
locked, REAmo already does what REAPER does; those cases are checked as
they stand.

When REAmo moves the group, the known-gap assertions fail: make them assert
a match with REAPER instead.
"""
from reamo_client import Client
import item_moves as im

FROM, TO = 1.0, 2.5  # a1's start, and where the nudge takes it
A1_ALONE = {"a1": ("A", TO)}
GROUP = {"a1": ("A", TO), "b1": ("B", TO)}

with Client() as c:
    c.wait_event("items")

    # Grouping off: only a1 moves, in REAPER and in REAmo.
    im.setup(grouping=0)
    before = im.state()
    want = im.reaper_move("a1", TO - FROM)
    assert im.moved_exactly(before, want, A1_ALONE), im.moved(before, want)
    im.setup(grouping=0)
    r, got = im.reamo_move(c, "a1", TO)
    assert r["success"], r
    assert not im.diff(want, got), "grouping off:\n" + "\n".join(im.diff(want, got))

    # a1 locked: neither moves it.
    lock_a1 = "reaper.SetMediaItemInfo_Value(MOVE_ITEMS.a1, 'C_LOCK', 1)"
    im.setup(grouping=1, lua=lock_a1)
    want = im.reaper_move("a1", TO - FROM)
    assert im.moved(before, want) == {}, f"REAPER moved a locked item: {im.moved(before, want)}"
    im.setup(grouping=1, lua=lock_a1)
    r, got = im.reamo_move(c, "a1", TO)
    assert not r["success"] and r["error"]["code"] == "ITEM_LOCKED", r
    assert not im.diff(want, got), "a1 locked:\n" + "\n".join(im.diff(want, got))

    # Grouping on: REAPER moves a1's group-mate b1 by the same amount.
    im.setup(grouping=1)
    want = im.reaper_move("a1", TO - FROM)
    print("REAPER, grouping on:", im.moved(before, want))
    assert im.moved_exactly(before, want, GROUP), f"REAPER, grouping on: {im.moved(before, want)}"
    im.setup(grouping=1)
    r, got = im.reamo_move(c, "a1", TO)
    assert r["success"], r
    print("REAmo, grouping on:", im.moved(before, got))
    # Known gap: a1 moves alone.
    assert im.moved_exactly(before, got, A1_ALONE), \
        "grouping on: REAmo no longer moves a1 alone. If it now matches REAPER, the known gap " \
        "is fixed: assert a match here instead.\n" + "\n".join(im.diff(want, got) or ["  matches REAPER"])

    # Grouping on, group-mate b1 locked: REAPER moves neither.
    lock_b1 = "reaper.SetMediaItemInfo_Value(MOVE_ITEMS.b1, 'C_LOCK', 1)"
    im.setup(grouping=1, lua=lock_b1)
    want = im.reaper_move("a1", TO - FROM)
    print("REAPER, b1 locked:", im.moved(before, want))
    assert im.moved(before, want) == {}, f"REAPER, b1 locked: {im.moved(before, want)}"
    im.setup(grouping=1, lua=lock_b1)
    r, got = im.reamo_move(c, "a1", TO)
    print("REAmo, b1 locked:", r.get("success"), im.moved(before, got))
    # Known gap: a1 moves anyway.
    assert r["success"] and im.moved_exactly(before, got, A1_ALONE), \
        "b1 locked: REAmo no longer moves a1 alone. If it now refuses like REAPER, the known gap " \
        f"is fixed: assert a match here instead.\n{r}\n" + "\n".join(im.diff(want, got) or ["  matches REAPER"])
