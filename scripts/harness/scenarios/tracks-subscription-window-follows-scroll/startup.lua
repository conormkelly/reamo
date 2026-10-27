dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 120 do harness.track(string.format("Track %03d", i)) end
harness.ready()
