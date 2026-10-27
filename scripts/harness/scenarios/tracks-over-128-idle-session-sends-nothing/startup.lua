-- More tracks than the per-track state arrays hold (128), and nothing else.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i = 1, 140 do harness.track(string.format("Track %03d", i)) end
harness.ready()
