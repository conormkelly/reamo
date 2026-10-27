dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 6 do harness.item(harness.track("T" .. i), 0, 2) end
harness.ready()
