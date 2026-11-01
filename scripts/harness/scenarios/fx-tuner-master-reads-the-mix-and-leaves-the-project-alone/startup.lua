-- A3 (220 Hz) on a track as 2 s notes 1 s apart, so playing the project
-- gives the master tuner a "pluck" (a note starting after silence) every
-- 3 s without anything editing the project. Saved, so it starts clean.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.begin_project("/tmp/master-tuner.RPP")
local t = harness.track("Guitar")
local wav = harness.wav("/tmp/a3.wav", 2.0, 220)
for k = 0, 59 do harness.audio_item(t, k * 3.0, wav) end
harness.save_as("/tmp/master-tuner.RPP")
-- Reopened from its file, so a save is silent and the project starts clean.
reaper.Main_openProject("noprompt:/tmp/master-tuner.RPP")
harness.ready()
