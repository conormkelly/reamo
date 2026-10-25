-- A tone generator at +6 dB on "Synth" (clips), a quiet one on "Pad", and a silent track.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local loud = harness.track("Synth")
local fx = reaper.TrackFX_AddByName(loud, "JS:synthesis/tonegenerator", false, -1)
reaper.TrackFX_SetParam(loud, fx, 0, 6)     -- wet +6 dB
reaper.TrackFX_SetParam(loud, fx, 1, -120)  -- dry off
local quiet = harness.track("Pad")
fx = reaper.TrackFX_AddByName(quiet, "JS:synthesis/tonegenerator", false, -1)
reaper.TrackFX_SetParam(quiet, fx, 0, -20)
reaper.TrackFX_SetParam(quiet, fx, 1, -120)
harness.track("Silent")
harness.oracle("fx", reaper.TrackFX_GetCount(loud))
harness.ready()
