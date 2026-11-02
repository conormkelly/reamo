-- Bass and Guitar record from inputs 1 and 2 of REAPER's JACK device
-- (`jack-inputs`).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local bass = harness.track("Bass")
reaper.SetMediaTrackInfo_Value(bass, "I_RECINPUT", 0)
local gtr = harness.track("Guitar")
reaper.SetMediaTrackInfo_Value(gtr, "I_RECINPUT", 1)
harness.ready()
