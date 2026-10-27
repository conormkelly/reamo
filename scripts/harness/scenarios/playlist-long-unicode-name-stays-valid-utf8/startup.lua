-- A tiny gig: three 2 s "songs" at 240 BPM 4/4 (1 s bars), the last one not
-- adjacent to the others, as playlists usually jump around the timeline.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 240, 4, 4, false)
reaper.AddProjectMarker2(0, true, 0, 2, "Intro", 1, 0)
reaper.AddProjectMarker2(0, true, 2, 4, "Verse", 2, 0)
reaper.AddProjectMarker2(0, true, 6, 8, "Outro", 3, 0)
reaper.UpdateTimeline()
harness.ready()
