-- A comped vocal: fixed lanes, a comp lane, and 400 takes worth of items
-- (a long session's punch-ins), so the track's state chunk is well over 64 KB.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Lead Vox")
reaper.SetMediaTrackInfo_Value(t, "I_FREEMODE", 2)
for i = 0, 399 do
  local it = harness.item(t, (i // 4) * 2, 1.5)
  reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", i % 4)
  reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "punch-in " .. i, true)
end
reaper.SetOnlyTrackSelected(t)
reaper.Main_OnCommand(42797, 0) -- Track lanes: Insert new comp lane
local _, chunk = reaper.GetTrackStateChunk(t, "", false)
harness.oracle("chunk_bytes", #chunk)
harness.oracle("items", reaper.CountTrackMediaItems(t))
harness.ready()
