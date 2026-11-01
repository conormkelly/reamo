-- REAPER on JACK with 4 fed inputs (this scenario's `jack-inputs`): one
-- track per input, each recording and monitoring its mono input, so the
-- test can read what reaches REAPER from its meters and from a recording.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
reaper.GetSetProjectInfo_String(0, "RECORD_PATH", harness.mkdir("/tmp/rec"), true)
harness.log("GetNumAudioInputs=%d", reaper.GetNumAudioInputs())
for i = 0, 3 do
  local t = harness.track("In " .. (i + 1))
  reaper.SetMediaTrackInfo_Value(t, "I_RECINPUT", i)  -- mono input i+1
  reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(t, "I_RECMON", 1)
end
harness.ready()
