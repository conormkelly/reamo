-- Bass records from input 1 of REAPER's JACK device (`jack-inputs`).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local bass = harness.track("Bass")
reaper.SetMediaTrackInfo_Value(bass, "I_RECINPUT", 0)
harness.ready()
