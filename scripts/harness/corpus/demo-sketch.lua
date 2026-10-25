-- What an amateur makes in an evening: REAPER's default project settings
-- (120 BPM, 4/4, project start at 0, no markers), four tracks of which two
-- were never named, a couple of takes recorded off the grid, a MIDI chord
-- idea on ReaSynth, and nothing tidied: an empty track, a fader left low,
-- the vocal still armed, the last item still selected and a leftover time
-- selection.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local dir = "/tmp/corpus/demo-sketch"
os.execute("mkdir -p " .. dir)
local function wav(name, secs, freq, ch) return harness.wav(dir .. "/" .. name, secs, freq, ch) end

local bar = 60 / 120 * 4 -- 2 s at REAPER's default tempo

-- Track 1, never named: a guitar riff recorded straight in, started a little late.
local gtr = harness.track()
harness.audio_item(gtr, 0.53, wav("Track 1-001.wav", 9.2, 196, 2))
reaper.SetMediaTrackInfo_Value(gtr, "D_VOL", 0.71)

-- A chord idea played in on the virtual keyboard: four bars, slightly loose.
local keys = harness.track("synth")
reaper.TrackFX_AddByName(keys, "ReaSynth", false, -1)
harness.midi_item(keys, 0, 4 * bar, {
  {0, 3.9, 57, 92}, {0.02, 3.9, 60, 88}, {0.05, 3.85, 64, 85},
  {4, 4, 53, 90}, {4.03, 3.95, 57, 84}, {4.04, 3.9, 60, 80},
  {8, 4, 55, 95}, {8.01, 3.9, 59, 87}, {8.06, 3.8, 62, 83},
  {12, 3.5, 52, 90}, {12.02, 3.5, 55, 86}, {12.03, 3.4, 59, 81},
})

-- Two vocal takes, the second a punch-in over the first's end.
local vox = harness.track("vox")
harness.audio_item(vox, 2.1, wav("vox-001.wav", 5.4, 440, 1))
local punch = harness.audio_item(vox, 6.8, wav("vox-002.wav", 3.1, 466, 1))
reaper.SetMediaTrackInfo_Value(vox, "I_RECARM", 1)
reaper.SetMediaTrackInfo_Value(vox, "I_RECINPUT", 0)

-- Added "for drums later" and never used.
harness.track()

reaper.SetMediaItemSelected(punch, true)
reaper.SetOnlyTrackSelected(vox)
reaper.GetSet_LoopTimeRange2(0, true, false, 6.5, 10.25, false)
reaper.SetEditCurPos(7.4, false, false)

harness.save_project(dir .. "/demo-sketch.RPP")
reaper.Main_OnCommand(40859, 0) -- File: New project tab (empty), so the test opens the sketch
