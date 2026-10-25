-- A real saved session: test-fixtures/test-project-1.RPP (140 BPM, start measure -5).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.open_fixture("test-project-1.RPP")
-- REAPER's own bar labels (measures.beats, project offset applied) at bar-length steps.
local bar = 60 / reaper.Master_GetTempo() * 4
for i = 0, 6 do
  local t = i * bar
  harness.oracle(string.format("label@%.6f", t), reaper.format_timestr_pos(t, "", 2))
end
harness.oracle("bar_seconds", bar)
harness.ready()
