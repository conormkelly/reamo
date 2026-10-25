"""Toggling an item's selection by GUID selects that item, even right after a move.

The user moves item A to the end of the track with the nudge/move field and
at once taps A in multi-select (useItemTapHandler: item/toggleSelect {guid}).
REAPER re-sorts the track as soon as A moves, so A's index is no longer 0.
"""
import time
from reamo_client import Client, reaper

SEL = """
local t = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.CountTrackMediaItems(t) - 1 do
  local it = reaper.GetTrackMediaItem(t, i)
  local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)
  out[g] = {reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.IsMediaItemSelected(it)}
end
return out
"""
RESET = """
reaper.SelectAllMediaItems(0, false)
local t = reaper.GetTrack(0, 0)
for i = 0, reaper.CountTrackMediaItems(t) - 1 do
  local it = reaper.GetTrackMediaItem(t, i)
  local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)
  local p = ({["%s"] = 1, ["%s"] = 2, ["%s"] = 3})[g]
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", p)
end
reaper.UpdateArrange()
"""

with Client() as c:
    items = sorted(c.wait_event("items")["payload"]["items"], key=lambda i: i["position"])
    a, b, d = (i["guid"] for i in items)
    names = {a: "A", b: "B", d: "C"}
    bad = []
    for trial in range(5):
        reaper(RESET % (a, b, d))
        c.drain(0.6)
        c.fire("item/moveByGuid", guid=a, position=5.0)
        c.fire("item/toggleSelect", guid=a)
        deadline = time.time() + 2
        while True:
            st = reaper(SEL)
            if any(s[1] for s in st.values()) or time.time() > deadline:
                break
            time.sleep(0.05)
        st = reaper(SEL)
        selected = sorted(names[g] for g, s in st.items() if s[1])
        print(f"  trial {trial}: A at {st[a][0]}, selected {selected}")
        if selected != ["A"]:
            bad.append(f"trial {trial}: tapped A, REAPER selected {selected}")
    assert not bad, "\n".join(bad)
