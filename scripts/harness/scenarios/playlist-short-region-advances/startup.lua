-- 120 BPM 4/4 (2 s bars): a 1 s pickup/stinger region, then a song elsewhere.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 120, 4, 4, false)
reaper.AddProjectMarker2(0, true, 0, 1, "Pickup", 1, 0)
reaper.AddProjectMarker2(0, true, 4, 6, "Song", 2, 0)
reaper.UpdateTimeline()
harness.ready()
