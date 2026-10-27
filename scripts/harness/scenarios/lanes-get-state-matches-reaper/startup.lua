dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("BV")
reaper.SetMediaTrackInfo_Value(t, "I_FREEMODE", 2)
for lane = 0, 2 do
  local it = harness.item(t, 0, 4)
  reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane)
end
reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:0", 'Take "A"', true)
reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:1", "Harm\t3rd", true)
reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:2", "Alt\\low", true)
harness.ready()
