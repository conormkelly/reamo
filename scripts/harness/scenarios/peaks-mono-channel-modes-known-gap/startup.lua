-- A stereo file (left: the staircase, right: 0.25) in takes with each
-- channel mode (Item Properties: Channel mode, I_CHANMODE).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local stereo = harness.staircase_wav("/tmp/staircase-stereo.wav", true)
for _, m in ipairs({{"normal", 0}, {"reverse stereo", 1}, {"mono (downmix)", 2}, {"mono (left)", 3}, {"mono (right)", 4}}) do
  local _, take = harness.waveform_item(m[1], stereo, 1, 8)
  reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", m[2])
end
harness.ready()
