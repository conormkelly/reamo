dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local vox = harness.track("Vocals")
local gtr = harness.track("Guitar")
local bus = harness.track("Bus")
reaper.CreateTrackSend(vox, nil)  -- a hardware output on Vocals and on Guitar
reaper.CreateTrackSend(gtr, nil)
reaper.CreateTrackSend(vox, gtr)  -- Guitar's receive 0
reaper.CreateTrackSend(gtr, bus)  -- Guitar's send 0
reaper.TrackFX_AddByName(gtr, "JS:loser/4BandEQ", false, -1)
reaper.TrackFX_SetParamNormalized(gtr, 0, 0, 0.5)
reaper.Undo_OnStateChange("Harness fixture")
harness.ready()
