dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 8 do harness.item(harness.track("T" .. i), 0, 30) end
harness.ready()
