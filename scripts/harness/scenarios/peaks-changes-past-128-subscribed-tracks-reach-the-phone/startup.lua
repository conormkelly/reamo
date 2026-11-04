-- 160 tracks of plain staircase items, more than REAmo's change check reads
-- in one tick. The test reverses the takes on the last 32 one at a time.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
for i = 1, 160 do
  harness.waveform_item(string.format("t%03d", i), wav, 1, 8)
end
harness.ready()
