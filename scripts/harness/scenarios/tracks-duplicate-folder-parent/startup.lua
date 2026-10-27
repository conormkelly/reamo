-- Drums folder (Kick, Snare) followed by Bass.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local drums = harness.track("Drums")
reaper.SetMediaTrackInfo_Value(drums, "I_FOLDERDEPTH", 1)
harness.track("Kick")
local snare = harness.track("Snare")
reaper.SetMediaTrackInfo_Value(snare, "I_FOLDERDEPTH", -1)
harness.track("Bass")
harness.ready()
