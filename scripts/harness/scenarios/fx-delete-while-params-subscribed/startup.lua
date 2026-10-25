dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Drums")
for _, fx in ipairs({"JS:loser/4BandEQ", "JS:utility/volume", "JS:delay/delay"}) do
  reaper.TrackFX_AddByName(t, fx, false, -1)
end
harness.ready()
