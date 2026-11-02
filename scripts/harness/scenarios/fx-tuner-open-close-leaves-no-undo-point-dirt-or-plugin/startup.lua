-- A saved project on JACK with 2 fed inputs (`jack-inputs`): Bass on input
-- 1, Guitar on input 2 (armed and monitoring, as before a take), Keys on
-- the stereo pair 1/2, and an FX of the user's own on Guitar's input FX.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.begin_project("/tmp/tuner-undo.RPP")
local bass = harness.track("Bass")
reaper.SetMediaTrackInfo_Value(bass, "I_RECINPUT", 0)
local gtr = harness.track("Guitar")
reaper.SetMediaTrackInfo_Value(gtr, "I_RECINPUT", 1)
reaper.SetMediaTrackInfo_Value(gtr, "I_RECARM", 1)
reaper.SetMediaTrackInfo_Value(gtr, "I_RECMON", 1)
reaper.TrackFX_AddByName(gtr, "JS:utility/volume", true, -1)
local keys = harness.track("Keys")
reaper.SetMediaTrackInfo_Value(keys, "I_RECINPUT", 1024)
harness.save_as("/tmp/tuner-undo.RPP")
reaper.Main_openProject("noprompt:/tmp/tuner-undo.RPP")
harness.ready()
