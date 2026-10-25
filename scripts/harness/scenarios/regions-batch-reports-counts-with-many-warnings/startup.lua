dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.AddProjectMarker2(0, false, 1, 0, "Verse", 1, 0)
reaper.AddProjectMarker2(0, true, 2, 4, "Chorus", 1, 0)
harness.ready()
