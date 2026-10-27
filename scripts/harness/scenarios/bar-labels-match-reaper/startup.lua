-- Markers and regions exactly on bar lines (computed by REAPER) and mid-bar,
-- across 4/4 -> 6/8 -> 7/8, plus a negative start measure. Records REAPER's own
-- measure.beat labels for each position as the oracle.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track("Click")
reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 120, 4, 4, false)
reaper.SetTempoTimeSigMarker(0, -1, 8, -1, -1, 90, 6, 8, false)
reaper.SetTempoTimeSigMarker(0, -1, 20, -1, -1, 140, 7, 8, false)

local positions = {}
for measure = 0, 14 do  -- REAPER's 0-based measure index -> exact bar-line time
  positions[#positions + 1] = reaper.TimeMap2_beatsToTime(0, 0, measure)
end
for _, t in ipairs({ 1.25, 9.7, 21.3, 25.05 }) do positions[#positions + 1] = t end
-- A hair before a bar line, as floating-point tempo maths and snapping produce
-- (e.g. 140 BPM bars of 1.7142857... s): REAPER rounds these to the next bar.
for _, measure in ipairs({ 2, 5, 9, 12 }) do
  positions[#positions + 1] = reaper.TimeMap2_beatsToTime(0, 0, measure) - 1e-7
end

for i, t in ipairs(positions) do
  reaper.AddProjectMarker(0, false, t, 0, "m" .. i, i)
  harness.oracle(string.format("marker%d", i), reaper.format_timestr_pos(t, "", 2))
  harness.oracle(string.format("time%d", i), string.format("%.9f", t))
end
-- A region spanning bar lines: start/end labels too.
reaper.AddProjectMarker(0, true, positions[3], positions[9], "r1", 1)
harness.oracle("region1_start", reaper.format_timestr_pos(positions[3], "", 2))
harness.oracle("region1_end", reaper.format_timestr_pos(positions[9], "", 2))
harness.ready()
