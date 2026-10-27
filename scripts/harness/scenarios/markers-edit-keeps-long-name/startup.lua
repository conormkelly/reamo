-- Markers whose names were typed in REAPER and are longer than 64 bytes.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.AddProjectMarker2(0, false, 4, 0, "Verse 1 - lead vocal comp from take 3, double the last line, ad-lib out", 1, 0)
reaper.AddProjectMarker2(0, false, 8, 0, "Chorus", 2, 0)
harness.ready()
