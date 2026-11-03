-- Items that run past the end of what their take plays, with looping off:
-- REAPER returns fewer peaks than asked for.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
harness.waveform_item("12 s item, 8 s file", wav, 1, 12)
local _, take = harness.waveform_item("slipped 2 s, 8 s item", wav, 1, 8)
reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 2)
_, take = harness.waveform_item("rate 2, 8 s item", wav, 1, 8)
reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 2)
harness.waveform_item("whole file", wav, 1, 8)
harness.ready()
