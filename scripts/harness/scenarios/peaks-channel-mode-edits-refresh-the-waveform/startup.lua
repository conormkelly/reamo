-- Stereo staircase items (left: the staircase, right: 0.25), each in the
-- channel mode its edit starts from; the test changes each one's mode while
-- a phone watches.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local stereo = harness.staircase_wav("/tmp/staircase-stereo.wav", true)
for _, m in ipairs({{"normal to mono (left)", 0}, {"mono (downmix) to normal", 2},
                    {"mono (left) to mono (right)", 3}, {"normal to reverse stereo", 0}}) do
  local _, take = harness.waveform_item(m[1], stereo, 1, 8)
  reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", m[2])
end
harness.ready()
