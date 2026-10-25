-- An item note longer than the 1 KB buffer the item poll reads notes into.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local it = harness.item(harness.track("Notes"), 0, 2)
reaper.GetSetMediaItemInfo_String(it, "P_NOTES", string.rep("n", 3000), true)
harness.ready()
