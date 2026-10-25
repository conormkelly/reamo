-- An edit placed to the sample at 48 kHz: 1 s + 20 samples.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.item(harness.track("Vox"), 1 + 20 / 48000, 2 + 7 / 48000)
harness.ready()
