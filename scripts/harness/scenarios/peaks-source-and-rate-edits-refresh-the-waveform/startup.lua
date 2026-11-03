-- Plain staircase items, each edited in REAPER by the test while a phone
-- watches; one item has a second take.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
harness.waveform_item("reverse", wav, 1, 8)
harness.waveform_item("section", wav, 1, 8)
harness.waveform_item("playrate", wav, 1, 8)
local it = harness.waveform_item("active take", wav, 1, 8)
reaper.SetActiveTake(harness.add_take(it, wav, "reversed"))
harness.reverse_take(it) -- reverses the active take
reaper.SetActiveTake(reaper.GetTake(it, 0))
harness.ready()
