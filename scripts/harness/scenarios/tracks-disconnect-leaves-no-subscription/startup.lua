dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 4 do harness.track("T" .. i) end
harness.ready()
