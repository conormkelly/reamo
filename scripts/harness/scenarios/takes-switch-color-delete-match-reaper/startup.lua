-- A MIDI item with three takes (comped keys part) and a second single-take item.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local keys = harness.track("Keys")
local it = reaper.CreateNewMIDIItemInProj(keys, 0, 4, false)
reaper.SelectAllMediaItems(0, false)
reaper.SetMediaItemSelected(it, true)
reaper.Main_OnCommand(40639, 0) -- Take: Duplicate active take
reaper.Main_OnCommand(40639, 0)
for i = 0, reaper.CountTakes(it) - 1 do
  reaper.GetSetMediaItemTakeInfo_String(reaper.GetTake(it, i), "P_NAME", "Keys take " .. (i + 1), true)
end
reaper.SetActiveTake(reaper.GetTake(it, 0))
reaper.CreateNewMIDIItemInProj(keys, 6, 8, false)
reaper.SelectAllMediaItems(0, false)
harness.log("takes=%d", reaper.CountTakes(it))
harness.ready()
