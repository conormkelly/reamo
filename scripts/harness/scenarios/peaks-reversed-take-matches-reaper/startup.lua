-- Takes reversed with "Item properties: Toggle take reverse", which wraps
-- the source in a reversed SECTION.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
harness.reverse_take(harness.waveform_item("reversed", wav, 1, 8))
-- A start offset counts from the reversed take's start (the file's end).
local it, take = harness.waveform_item("reversed, offset 2 s", wav, 1, 6)
harness.reverse_take(it)
reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 2)
-- A section reversed: seconds 2-5 of the file, backwards.
it = harness.waveform_item("reversed section 2-5 s", wav, 1, 3)
harness.section(it, 2, 3)
harness.reverse_take(it)
harness.ready()
