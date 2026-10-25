dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.AddProjectMarker2(0, false, 4, 0, "Intro", 1, 0)
reaper.AddProjectMarker2(0, true, 8, 16, "Verse", 1, 0)
harness.ready()
