"""An item's index on its track changes when another item moves past it
(REAPER keeps items sorted by position); its GUID doesn't. A phone that
names the item by GUID must reach the item it showed the user, not
whichever item now has its old index."""
from reamo_client import Client, reaper

GUIDS = '''
local tr = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
  local _, g = reaper.GetSetMediaItemInfo_String(reaper.GetTrackMediaItem(tr, i), "GUID", "", false)
  out[#out + 1] = g
end
return table.concat(out, " ")
'''
NOTES = '''
local tr = reaper.GetTrack(0, 0)
for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
  local item = reaper.GetTrackMediaItem(tr, i)
  local _, g = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if g == "%s" then
    local _, n = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    return n
  end
end
return nil
'''

first, second = reaper(GUIDS).split()
with Client() as c:
    c.wait_event("transport")
    # The user picked the first item (index 0); then, in REAPER, the second
    # item is dragged to the start, so the picked item is now index 1.
    reaper(f'''
      local tr = reaper.GetTrack(0, 0)
      reaper.SetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, 1), "D_POSITION", 0)
      reaper.UpdateArrange()
    ''')
    assert reaper(GUIDS).split() == [second, first], "REAPER didn't re-sort the track"

    r = c.command("item/setNotes", itemGuid=first, trackIdx=1, itemIdx=0, notes="double the chorus")
    assert r["success"], r
    assert reaper(NOTES % first) == "double the chorus", "the notes missed the item the phone named"
    assert reaper(NOTES % second) == "", "the notes landed on the item now at the old index"

    r = c.command("item/getNotes", itemGuid=first)
    assert r["success"] and r["payload"]["notes"] == "double the chorus", r

    r = c.command("item/delete", itemGuid=first)
    assert r["success"], r
    assert reaper(GUIDS).split() == [second], "delete removed the wrong item"

    r = c.command("item/setNotes", itemGuid=first, trackIdx=1, itemIdx=0, notes="stale")
    assert not r["success"] and r["error"]["code"] == "NOT_FOUND", r
    assert reaper(NOTES % second) == "", "a gone item's notes landed on its old index"
print("ok: commands by itemGuid follow the item through a re-sort and a delete")
