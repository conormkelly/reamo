-- A guitar track, armed and monitoring, as when tuning before a take.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Guitar")
reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 1)
reaper.SetMediaTrackInfo_Value(t, "I_RECMON", 1)
harness.ready()
