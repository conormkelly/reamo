-- Items longer than their 8 s file, with "Loop source" on.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
local it = harness.waveform_item("looped, 12 s", wav, 1, 12)
reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 1)
local take
it, take = harness.waveform_item("looped, offset 6 s", wav, 1, 6)
reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 1)
reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 6)
harness.ready()
