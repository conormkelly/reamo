-- Vocals: a hardware output (e.g. to a headphone feed) plus two sends.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local vox = harness.track("Vocals")
local rev = harness.track("Reverb")
local dly = harness.track("Delay")
harness.oracle("hw", reaper.CreateTrackSend(vox, nil))
harness.oracle("s0", reaper.CreateTrackSend(vox, rev))
harness.oracle("s1", reaper.CreateTrackSend(vox, dly))
harness.ready()
