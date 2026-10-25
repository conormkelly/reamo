-- ReaEQ ships factory presets; the JSFX beside it has none.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Vocals")
reaper.TrackFX_AddByName(t, "JS:utility/volume", false, -1)
reaper.TrackFX_AddByName(t, "ReaEQ (Cockos)", false, -1)
harness.ready()
