-- Plain staircase items, edited in REAPER by the test in quick pairs while
-- a phone watches.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local wav = harness.staircase_wav("/tmp/staircase.wav")
for _, name in ipairs({"twice", "same tick 1", "same tick 2", "50 ms 1", "50 ms 2"}) do
  harness.waveform_item(name, wav, 1, 8)
end
harness.ready()
