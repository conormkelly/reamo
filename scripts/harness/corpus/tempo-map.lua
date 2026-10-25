-- A tempo-mapped arrangement: a linear ramp into the verse, a 7/8 bridge, a
-- 3/4 outro that slows down (another linear ramp), timebase "time"
-- (TIMELOCKMODE 0, so audio items stay put in seconds when the tempo
-- changes), a project start offset of -2 bars (PROJOFFS: the ruler counts
-- -1, 0, then bar 1 two bars in), and markers and regions on and between the
-- changes.
--
--   measure (0-based)  0          4         8          12         20     24
--   meter              4/4 -----------------7/8 -------3/4 ----------------
--   BPM                92 ramp -> 104 ------104 -------120 ramp -> 90 -----
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local dir = "/tmp/corpus/tempo-map"
os.execute("mkdir -p " .. dir .. "/Media")
local function wav(name, secs, freq, ch) return harness.wav(dir .. "/Media/" .. name, secs, freq, ch) end

-- (measure, bpm, num, den, linear): num/den 0 keep the meter in force.
local map = {
  {0, 92, 4, 4, true},
  {4, 104, 0, 0, false},
  {8, 104, 7, 8, false},
  {12, 120, 3, 4, true},
  {20, 90, 0, 0, false},
}
for _, m in ipairs(map) do
  assert(reaper.SetTempoTimeSigMarker(0, -1, -1, m[1], 0, m[2], m[3], m[4], m[5]), "tempo marker at measure " .. m[1])
end
reaper.UpdateTimeline()

local function at(measure, beat) return reaper.TimeMap2_beatsToTime(0, beat or 0, measure) end
for _, m in ipairs(map) do harness.oracle("measure" .. m[1], at(m[1])) end
harness.log("tempo markers=%d end=%.3f", reaper.CountTempoTimeSigMarkers(0), at(24))

-- Click and a guide track spanning everything; drums and bass per section.
local click = harness.track("Click")
reaper.TrackFX_AddByName(click, "JS: Utility/volume", false, -1)
local guide = harness.track("Guide vox")
harness.audio_item(guide, at(0), wav("guide.wav", at(24) - at(0), 330, 1))

local drums = harness.track("Drums")
local drum_wav = wav("drums-loop.wav", 4, 60, 2)
for _, sec in ipairs({{0, 4}, {4, 8}, {8, 12}, {12, 20}, {20, 24}}) do
  harness.audio_item(drums, at(sec[1]), drum_wav, at(sec[2]) - at(sec[1]))
end

local bass = harness.track("Bass")
reaper.TrackFX_AddByName(bass, "ReaSynth", false, -1)
-- Quarter-note positions from each item's start, so notes land on the beats
-- REAPER's tempo map gives them (eighths in 7/8).
harness.midi_item(bass, at(0), at(8) - at(0), {{0, 4, 40}, {4, 4, 43}, {8, 4, 45}, {12, 4, 40},
                                               {16, 4, 40}, {20, 4, 43}, {24, 4, 45}, {28, 4, 47}})
harness.midi_item(bass, at(8), at(12) - at(8), {{0, 1.5, 38}, {1.5, 2, 41}, {3.5, 1.5, 38}, {5, 2, 43},
                                                {7, 1.5, 38}, {8.5, 2, 41}, {10.5, 1.5, 45}, {12, 2, 43}})
harness.midi_item(bass, at(12), at(24) - at(12), {{0, 3, 36}, {3, 3, 43}, {6, 3, 41}, {9, 3, 36}})

-- Arrangement: regions per section, markers on the changes and one mid-bar.
reaper.AddProjectMarker2(0, true, at(0), at(4), "Intro (accel.)", 1, 0)
reaper.AddProjectMarker2(0, true, at(4), at(8), "Verse", 2, reaper.ColorToNative(60, 160, 90) | 0x1000000)
reaper.AddProjectMarker2(0, true, at(8), at(12), "Bridge 7/8", 3, 0)
reaper.AddProjectMarker2(0, true, at(12), at(24), "Outro (rit.)", 4, 0)
reaper.AddProjectMarker2(0, false, at(4), 0, "a tempo", 1, 0)
reaper.AddProjectMarker2(0, false, at(8), 0, "7/8", 2, 0)
reaper.AddProjectMarker2(0, false, at(10, 2.5), 0, "hit on the and", 3, 0)
reaper.AddProjectMarker2(0, false, at(12), 0, "3/4 rit.", 4, 0)
reaper.AddProjectMarker2(0, false, at(23), 0, "last bar", 5, 0)

harness.save_project(dir .. "/tempo-map.RPP", {PROJOFFS = "0 -2 0", TIMELOCKMODE = "0", SAMPLERATE = "44100 1 0"})
reaper.Main_OnCommand(40859, 0) -- File: New project tab (empty), so the test opens the session
