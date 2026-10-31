dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 12 do harness.track(string.format("Track %02d", i)) end
harness.ready()
