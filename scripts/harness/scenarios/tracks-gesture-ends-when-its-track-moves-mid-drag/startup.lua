dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local vox = harness.track("Vocals")
local gtr = harness.track("Guitar")
local bus = harness.track("Bus")
local keys = harness.track("Keys")
-- Vocals has every route and FX Guitar has, so a drag that reached Vocals
-- instead would change it rather than be refused.
reaper.CreateTrackSend(vox, nil)  -- hardware output 0 on Vocals and Guitar
reaper.CreateTrackSend(gtr, nil)
reaper.CreateTrackSend(vox, gtr)  -- Vocals' send 0, Guitar's receive 0
reaper.CreateTrackSend(gtr, bus)  -- Guitar's send 0
reaper.CreateTrackSend(keys, vox) -- Vocals' receive 0
-- FX last: with routes created between FX adds, the routes made after the
-- first FX did not come back from the test's undo-everything-then-redo walk.
for _, t in ipairs({ vox, gtr }) do
  reaper.TrackFX_AddByName(t, "JS:loser/4BandEQ", false, -1)
  reaper.TrackFX_SetParamNormalized(t, 0, 0, 0.5)
end
reaper.Undo_OnStateChange("Harness fixture")
harness.ready()
