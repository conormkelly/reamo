-- REAPER on JACK with 2 fed inputs (`jack-inputs`); Guitar records from
-- input 2. The test restarts REAPER with "close audio device when
-- stopped" on, and this runs again then.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local gtr = harness.track("Guitar")
reaper.SetMediaTrackInfo_Value(gtr, "I_RECINPUT", 1)
harness.ready()
