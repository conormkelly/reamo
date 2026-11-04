-- Two projects, each with a tone generator playing into the master: one
-- that asks for 44.1 kHz and one for 48 kHz. REAPER's dummy device follows
-- the project's rate.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local dir = harness.mkdir("/tmp/srate")
harness.begin_project(dir .. "/asks-44100.RPP")
local t = harness.track("Tone")
reaper.TrackFX_AddByName(t, "JS:synthesis/tonegenerator", false, -1)
harness.item(t, 0, 600)
harness.save_project(dir .. "/asks-44100.RPP", {SAMPLERATE = "44100 1 0"})
harness.save_project(dir .. "/asks-48000.RPP", {SAMPLERATE = "48000 1 0"})
harness.ready()
