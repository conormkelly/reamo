-- Two fixed-lane tracks with three lanes each; the user has "Gtr" selected in REAPER.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for _, name in ipairs({"Vox", "Gtr"}) do
  local t = harness.track(name)
  reaper.SetMediaTrackInfo_Value(t, "I_FREEMODE", 2)
  for lane = 0, 2 do
    local it = harness.item(t, 0, 4)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane)
  end
end
reaper.SetOnlyTrackSelected(reaper.GetTrack(0, 1))
harness.ready()
