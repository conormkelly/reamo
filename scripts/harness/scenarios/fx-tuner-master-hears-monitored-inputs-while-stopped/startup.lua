-- REAPER on JACK with 2 fed inputs (`jack-inputs`): Bass on input 1 and
-- Guitar on input 2, both armed and monitoring their input, so both play
-- through the master with the transport stopped.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for i, name in ipairs({"Bass", "Guitar"}) do
  local t = harness.track(name)
  reaper.SetMediaTrackInfo_Value(t, "I_RECINPUT", i - 1)
  reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(t, "I_RECMON", 1)
end
harness.ready()
