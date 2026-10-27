-- A JSFX with 256 sliders with long, descriptive names (large synths expose
-- thousands of parameters; this is the most a JSFX can declare).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local f = io.open(reaper.GetResourcePath() .. "/Effects/harness_big.jsfx", "w")
f:write("desc:Harness big synth\n")
for i = 1, 256 do
  f:write(string.format("slider%d:0<0,1,0.01>Osc %03d modulation depth %s\n", i, i, string.rep("detail ", 40)))
end
f:write("@sample\n")
f:close()
local t = harness.track("Synth")
harness.oracle("fx", reaper.TrackFX_AddByName(t, "JS:harness_big.jsfx", false, -1))
harness.oracle("params", reaper.TrackFX_GetNumParams(t, 0))
local _, n = reaper.TrackFX_GetParamName(t, 0, 0, "")
harness.oracle("name0", n)
harness.ready()
