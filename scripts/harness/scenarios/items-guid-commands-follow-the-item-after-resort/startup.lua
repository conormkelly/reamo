dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local tr = harness.track("Vox")
for _, pos in ipairs({1, 5}) do
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
  reaper.AddTakeToMediaItem(it)
end
harness.ready()
