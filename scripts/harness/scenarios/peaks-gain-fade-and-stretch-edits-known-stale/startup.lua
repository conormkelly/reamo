-- Plain staircase items, each edited in REAPER by the test while a phone
-- watches. "loop source" starts looped (12 s item, 8 s file); "take pan"
-- holds the staircase on the left and 0.25 on the right.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
local stereo = harness.staircase_wav("/tmp/staircase-stereo.wav", true)
for _, name in ipairs({"item volume", "take volume", "fade in", "stretch markers", "take volume envelope", "slip (control)"}) do
  harness.waveform_item(name, wav, 1, 8)
end
local it = harness.waveform_item("loop source", wav, 1, 12)
reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 1)
harness.waveform_item("take pan", stereo, 1, 8)
harness.ready()
