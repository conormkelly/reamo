-- A project that starts at measure -5, with a 6/8 section at 8 s and a 7/8
-- section at 140 BPM from 20 s: the meters and offset a real session uses.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local f = io.open("/tmp/start-measure.RPP", "w")
f:write([[<REAPER_PROJECT 0.1 "7.0" 0
  TEMPO 120 4 4 0
  PROJOFFS 0 -5 0
>
]])
f:close()
reaper.Main_openProject("noprompt:/tmp/start-measure.RPP")
harness.track("Click")
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 120, 4, 4, false)
reaper.SetTempoTimeSigMarker(0, -1, 8, -1, -1, 90, 6, 8, false)
reaper.SetTempoTimeSigMarker(0, -1, 20, -1, -1, 140, 7, 8, false)
reaper.UpdateTimeline()
harness.ready()
