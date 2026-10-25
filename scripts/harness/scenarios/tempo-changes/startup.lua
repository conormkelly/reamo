-- Tempo and time-signature changes (the negative measure offset is covered by
-- the user-test-project scenario, which opens a project saved with one).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track("Click")
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 120, 4, 4, false)
reaper.SetTempoTimeSigMarker(0, -1, 8, -1, -1, 90, 6, 8, false)
reaper.SetTempoTimeSigMarker(0, -1, 20, -1, -1, 140, 7, 8, true)
harness.log("tempo markers=%d", reaper.CountTempoTimeSigMarkers(0))
harness.ready()
