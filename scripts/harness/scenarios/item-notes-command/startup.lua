-- Item notes longer than item/getNotes' 8 KB buffer, on a track whose items
-- are polled too (so this also covers the poll path).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Notes")
reaper.GetSetMediaItemInfo_String(harness.item(t, 0, 2), "P_NOTES", string.rep("n", 500), true)
reaper.GetSetMediaItemInfo_String(harness.item(t, 4, 2), "P_NOTES", string.rep("n", 20000), true)
harness.ready()
