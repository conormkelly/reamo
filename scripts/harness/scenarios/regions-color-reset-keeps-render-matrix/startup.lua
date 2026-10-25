-- A region routed in REAPER's Region Render Matrix to two stems, coloured red.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local drums = harness.track("Drums")
local vox = harness.track("Vox")
reaper.AddProjectMarker2(0, true, 4, 12, "Chorus", 1, reaper.ColorToNative(255, 0, 0) | 0x1000000)
reaper.SetRegionRenderMatrix(0, 1, drums, 1)
reaper.SetRegionRenderMatrix(0, 1, vox, 1)
harness.ready()
