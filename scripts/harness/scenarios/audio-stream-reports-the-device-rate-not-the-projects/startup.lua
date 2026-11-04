-- REAPER on JACK at 48 kHz with one fed input (this scenario's `jack-inputs`),
-- and a project that asks for 44.1 kHz, which JACK can't run at. Its one
-- track records and monitors input 1, so what the feeder plays reaches the
-- master, and the audio stream.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local project = harness.mkdir("/tmp/srate") .. "/asks-44100.RPP"
harness.begin_project(project)
local t = harness.track("In 1")
reaper.SetMediaTrackInfo_Value(t, "I_RECINPUT", 0)  -- mono input 1
reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 1)
reaper.SetMediaTrackInfo_Value(t, "I_RECMON", 1)
harness.save_project(project, {SAMPLERATE = "44100 1 0"})
harness.ready()
