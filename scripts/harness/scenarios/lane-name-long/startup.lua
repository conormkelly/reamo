-- A fixed-lane track whose lane name is longer than the 256-byte buffer
-- lanes/getState reads lane names into.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Comp")
reaper.SetMediaTrackInfo_Value(t, "I_FREEMODE", 2)        -- fixed item lanes
reaper.SetMediaTrackInfo_Value(t, "I_NUMFIXEDLANES", 2)
local ok = reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:0", string.rep("L", 2000), true)
local _, back = reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:0", "", false)
harness.log("lane name set=%s, length read back=%d", tostring(ok), #back)
harness.ready()
