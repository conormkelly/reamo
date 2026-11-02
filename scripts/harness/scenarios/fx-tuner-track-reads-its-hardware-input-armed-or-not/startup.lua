-- REAPER on JACK with 2 fed inputs (`jack-inputs`). Bass records from
-- input 1, Guitar from input 2; neither is armed, neither monitors.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local bass = harness.track("Bass")
reaper.SetMediaTrackInfo_Value(bass, "I_RECINPUT", 0)
local gtr = harness.track("Guitar")
reaper.SetMediaTrackInfo_Value(gtr, "I_RECINPUT", 1)
harness.ready()
