-- A small real session: an FX on track 1, project notes, a tempo change.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Synth")
harness.track("Bus")
local fx = reaper.TrackFX_AddByName(t, "JS:synthesis/tonegenerator", false, -1)
harness.log("tone generator fx index=%d", fx)
reaper.GetSetProjectNotes(0, true, "Session notes\nline 2")
reaper.SetTempoTimeSigMarker(0, -1, 4, -1, -1, 100, 3, 4, false)
harness.ready()
