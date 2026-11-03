-- An 8 s item with stretch markers that play the file's first 4 s in the
-- item's first 2 s, and its last 4 s over the remaining 6 s.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
local _, take = harness.waveform_item("stretched", wav, 1, 8)
reaper.SetTakeStretchMarker(take, -1, 0, 0)
reaper.SetTakeStretchMarker(take, -1, 2, 4)
reaper.SetTakeStretchMarker(take, -1, 8, 8)
harness.waveform_item("not stretched", wav, 1, 8)
harness.ready()
