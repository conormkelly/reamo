dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local vox = harness.track("Vocals")
local gtr = harness.track("Guitar")
reaper.CreateTrackSend(vox, nil)  -- a hardware output on each
reaper.CreateTrackSend(gtr, nil)
reaper.TrackFX_AddByName(gtr, "JS:loser/4BandEQ", false, -1)
reaper.TrackFX_SetParamNormalized(gtr, 0, 0, 0.5)
reaper.Undo_OnStateChange("Harness fixture")
harness.ready()
