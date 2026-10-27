-- A region whose name was typed in REAPER and is longer than 64 bytes.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.AddProjectMarker2(0, true, 4, 12, "Bridge (alt) - strings enter at bar 3, keep the pad low until the drop", 1, 0)
harness.ready()
