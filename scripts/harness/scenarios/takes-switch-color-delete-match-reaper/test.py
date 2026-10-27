"""Take switching, take colour and take delete from the item info bar match REAPER.

NavigateItemInfoBar: next/prev take send item/setActiveTake with an index it
computes; the colour picker sends take/setColor for the active take; delete
take and crop send take/delete and take/cropToActive (REAPER actions on the
selected items). item/getTakes must list what REAPER has.
"""
import time
from reamo_client import Client, reaper

TAKES = """
local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), %d)
local out = {}
local act = reaper.GetActiveTake(it)
for i = 0, reaper.CountTakes(it) - 1 do
  local tk = reaper.GetTake(it, i)
  local _, nm = reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
  out[#out + 1] = {nm, tk == act, reaper.GetMediaItemTakeInfo_Value(tk, "I_CUSTOMCOLOR")}
end
return out
"""


def until(pred, lua):
    deadline = time.time() + 2
    while True:
        got = reaper(lua)
        if pred(got) or time.time() > deadline:
            return got
        time.sleep(0.05)


def event_item(c, idx):
    c.drain(0.5)
    items = [i for i in c.latest_event("items")["payload"]["items"] if i["trackIdx"] == 1]
    return sorted(items, key=lambda i: i["position"])[idx]


with Client() as c:
    c.wait_event("items")
    want = reaper(TAKES % 0)
    r = c.command("item/getTakes", trackIdx=1, itemIdx=0)
    assert r["success"], r
    got = [(t["name"], t["isActive"]) for t in r["payload"]["takes"]]
    print("getTakes:", got, " REAPER:", [(n, a) for n, a, _ in want])
    assert got == [(n, a) for n, a, _ in want], (got, want)
    assert all(t["isMidi"] for t in r["payload"]["takes"]), r

    # Next take from the first take: the bar sends index 1, then "prev" from 0 wraps to 2.
    c.fire("item/setActiveTake", trackIdx=1, itemIdx=0, takeIdx=2)
    st = until(lambda s: s[2][1], TAKES % 0)
    assert [a for _, a, _ in st] == [False, False, True], st
    ev = event_item(c, 0)
    print("items event after switch:", ev.get("activeTakeIdx"), ev.get("activeTakeName"), ev.get("takeCount"))
    assert ev["activeTakeIdx"] == 2 and ev["takeCount"] == 3, ev

    # Colour the active take red; the other takes keep theirs.
    red = 0x1000000 | (255 << 16)
    r = c.command("take/setColor", trackIdx=1, itemIdx=0, takeIdx=2, color=red)
    assert r["success"], r
    st = reaper(TAKES % 0)
    print("colours:", [col for _, _, col in st])
    assert [col for _, _, col in st] == [0, 0, red], st

    # Delete take: the phone shows one item selected; REAPER deletes its active take.
    reaper("reaper.SelectAllMediaItems(0, false); reaper.SetMediaItemSelected(reaper.GetTrackMediaItem(reaper.GetTrack(0,0), 0), true)")
    c.fire("take/delete")
    st = until(lambda s: len(s) == 2, TAKES % 0)
    print("after delete:", st)
    assert [n for n, _, _ in st] == ["Keys take 1", "Keys take 2"], st
    other = reaper(TAKES % 1)
    assert len(other) == 1, f"take/delete touched the unselected item: {other}"
    ev = event_item(c, 0)
    assert ev["takeCount"] == 2, ev

    # Crop to active: only the active take remains.
    c.fire("take/cropToActive")
    st = until(lambda s: len(s) == 1, TAKES % 0)
    print("after crop:", st)
    assert len(st) == 1 and st[0][1], st

    # Undo the crop from REAPER: the phone sees two takes again.
    reaper("reaper.Undo_DoUndo2(0)")
    st = until(lambda s: len(s) == 2, TAKES % 0)
    assert len(st) == 2, f"undo did not restore the cropped take: {st}"
    ev = event_item(c, 0)
    assert ev["takeCount"] == 2, ev
