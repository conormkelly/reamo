-- REAPER on JACK with 2 fed inputs (`jack-inputs`): a bass on input 1, a
-- guitar on input 2, as a bassist and a guitarist in one session.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local bass = harness.track("Bass")
reaper.SetMediaTrackInfo_Value(bass, "I_RECINPUT", 0)
local gtr = harness.track("Guitar")
reaper.SetMediaTrackInfo_Value(gtr, "I_RECINPUT", 1)
harness.ready()
