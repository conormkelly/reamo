-- Markers 1-3 and a region that shares number 2 with a marker.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.AddProjectMarker2(0, false, 2, 0, "One", 1, 0)
reaper.AddProjectMarker2(0, false, 4, 0, "Two", 2, 0)
reaper.AddProjectMarker2(0, false, 6, 0, "Three", 3, 0)
reaper.AddProjectMarker2(0, true, 3, 5, "Region Two", 2, 0)
harness.ready()
