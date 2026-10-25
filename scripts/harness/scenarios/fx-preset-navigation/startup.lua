-- ReaEQ ships factory presets (reaeq.vst.so.rpl); a JSFX next to it has none.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Vocals")
reaper.TrackFX_AddByName(t, "JS:utility/volume", false, -1)
harness.oracle("reaeq", reaper.TrackFX_AddByName(t, "VST: ReaEQ (Cockos)", false, -1))
local _, n = reaper.TrackFX_GetPresetIndex(t, 1)
harness.oracle("presets", n)
harness.ready()
