-- Markers and a region in a project whose markers keep their time when the
-- tempo map changes (timebase: Time), so only their bar labels move.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local function project(path, start_measure)
  local f = io.open(path, "w")
  f:write(string.format([[<REAPER_PROJECT 0.1 "7.0" 0
  TIMELOCKMODE 0
  TEMPOENVLOCKMODE 0
  TEMPO 120 4 4 0
  PROJOFFS 0 %d 0
  MARKER 1 4 "Verse" 0 0 1 R
  MARKER 2 8 "Chorus" 0 0 1 R
  MARKER 3 4 "Section" 1 0 1 R
  MARKER 3 12 "" 1
>
]], start_measure))
  f:close()
end

project("/tmp/time-timebase.RPP", 0)
project("/tmp/time-timebase-start-5.RPP", -5) -- same markers, project starts at measure -5
reaper.Main_openProject("noprompt:/tmp/time-timebase.RPP")
harness.ready()
