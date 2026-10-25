dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Drums")
harness.item(t, 0, 30)
harness.ready()
