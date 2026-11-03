-- Items playing a section of the staircase file (Item Properties: Section),
-- so their take's source is a SECTION wrapping the WAVE file.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
harness.section(harness.waveform_item("section 2-5 s", wav, 1, 3), 2, 3)
-- A start offset counts from the section's start, not the file's.
local it, take = harness.waveform_item("section 2-5 s, offset 1 s", wav, 1, 2)
harness.section(it, 2, 3)
reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 1)
harness.waveform_item("whole file", wav, 1, 8)
harness.ready()
