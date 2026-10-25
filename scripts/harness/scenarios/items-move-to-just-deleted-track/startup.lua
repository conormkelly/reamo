-- An item to move, on a track that stays.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local src = harness.track("Source")
harness.item(src, 1, 2)
harness.ready()
