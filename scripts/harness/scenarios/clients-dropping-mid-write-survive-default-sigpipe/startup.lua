-- A track with a tone generator, so the master bus carries non-silent audio
-- while the transport plays (silent frames are not sent, by design).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Tone")
local fx = reaper.TrackFX_AddByName(t, "JS:synthesis/tonegenerator", false, -1)
harness.log("tone generator fx index=%d", fx)
harness.item(t, 0, 600)
harness.ready()
