-- Guitar track with a four-FX chain, as a user's insert chain would look.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Guitar")
for _, fx in ipairs({"JS:loser/4BandEQ", "JS:utility/volume", "JS:delay/delay", "JS:loser/3BandEQ"}) do
  reaper.TrackFX_AddByName(t, fx, false, -1)
end
harness.ready()
