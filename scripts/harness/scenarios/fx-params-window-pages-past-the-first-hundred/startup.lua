-- A JSFX with 256 sliders, each set to its own value, so a parameter's
-- value says which parameter it is.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local f = io.open(reaper.GetResourcePath() .. "/Effects/harness_paging.jsfx", "w")
f:write("desc:Harness paging synth\n")
for i = 1, 256 do
  f:write(string.format("slider%d:0<0,1000,1>Param %03d\n", i, i - 1))
end
f:write("@sample\n")
f:close()
local t = harness.track("Synth")
harness.oracle("fx", reaper.TrackFX_AddByName(t, "JS:harness_paging.jsfx", false, -1))
harness.oracle("params", reaper.TrackFX_GetNumParams(t, 0))
for i = 0, 255 do
  reaper.TrackFX_SetParamNormalized(t, 0, i, i / 1000)
end
for _, i in ipairs({ 0, 180, 255 }) do
  harness.oracle("value" .. i, reaper.TrackFX_GetParamNormalized(t, 0, i))
  local _, formatted = reaper.TrackFX_GetFormattedParamValue(t, 0, i, "")
  harness.oracle("formatted" .. i, formatted)
end
harness.ready()
