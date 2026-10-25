-- Vocals feeds the Reverb bus twice (a post-fader and a pre-fader send, a
-- common way to keep a reverb tail when the vocal is ridden down).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local vox = harness.track("Vocals")
local rev = harness.track("Reverb")
reaper.CreateTrackSend(vox, rev)
local i = reaper.CreateTrackSend(vox, rev)
reaper.SetTrackSendInfo_Value(vox, 0, i, "I_SENDMODE", 3)
harness.oracle("receives", reaper.GetTrackNumSends(rev, -1))
harness.ready()
