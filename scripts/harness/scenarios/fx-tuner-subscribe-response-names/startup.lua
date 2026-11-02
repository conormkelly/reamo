-- Track names users type: quotes, a backslash, accents, and a long one.
-- Both record from input 1 of REAPER's JACK device (`jack-inputs`), so
-- the tuner can open on them.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local a = harness.track('Lead "Strat" \\ DI')
reaper.SetMediaTrackInfo_Value(a, "I_RECINPUT", 0)
local b = harness.track("Guitare acoustique — prise 2 " .. string.rep("ü", 60))
reaper.SetMediaTrackInfo_Value(b, "I_RECINPUT", 0)
harness.ready()
