-- One stereo staircase item (left: the staircase, right: 0.25) in normal
-- channel mode; the test switches it to mono and back while a phone scrolls.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local stereo = harness.staircase_wav("/tmp/staircase-stereo.wav", true)
harness.waveform_item("stairs", stereo, 1, 8)
harness.ready()
