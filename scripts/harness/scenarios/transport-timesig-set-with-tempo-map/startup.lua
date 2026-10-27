-- A song with a tempo map: 4/4 at 120 from the start, 6/8 at 90 from 8 s.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track("Keys")
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 120, 4, 4, false)
reaper.SetTempoTimeSigMarker(0, -1, 8, -1, -1, 90, 6, 8, false)
reaper.UpdateTimeline()
harness.ready()
