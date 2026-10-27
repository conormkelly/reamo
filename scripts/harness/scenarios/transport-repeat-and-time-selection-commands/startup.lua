dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Pad")
harness.item(t, 0, 40)
harness.ready()
