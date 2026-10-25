-- Unicode FX and parameter names longer than the extension's name buffers.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local f = io.open(reaper.GetResourcePath() .. "/Effects/harness_uni.jsfx", "w")
f:write("desc:Harness unicode\n")
-- 10-byte ASCII prefix, then 2-byte characters: byte 255 falls inside one.
f:write("slider1:0.5<0,1,0.01>Band 001: " .. string.rep("é", 150) .. "\n")
f:write("slider2:0.5<0,1,0.01>Gain ✓ " .. string.rep("音", 100) .. "\n")
f:write("@sample\n")
f:close()
local t = harness.track("Vocals")
reaper.TrackFX_AddByName(t, "JS:harness_uni.jsfx", false, -1)
reaper.TrackFX_AddByName(t, "JS:utility/volume", false, -1)
-- The user renames the second FX in REAPER's FX chain (a 2-byte name > 128 bytes).
reaper.TrackFX_SetNamedConfigParm(t, 1, "renamed_name", "Lead vocal " .. string.rep("ü", 80))
for i = 0, 1 do
  local _, n = reaper.TrackFX_GetParamName(t, 0, i, "")
  harness.oracle("param" .. i, n)
  local _, fxn = reaper.TrackFX_GetFXName(t, i, "")
  harness.oracle("fx" .. i, fxn)
end
harness.ready()
