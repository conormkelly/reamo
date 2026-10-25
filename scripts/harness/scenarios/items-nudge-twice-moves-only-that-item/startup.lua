-- Two takes on a vocal track, the first nudged past the second.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Vox")
harness.item(t, 1, 1)
harness.item(t, 2, 1)
harness.ready()
