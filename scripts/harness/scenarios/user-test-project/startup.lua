-- A real saved session, test-fixtures/test-project-1.RPP (140 BPM, start
-- measure -5), opened by test.py as a user would: a REAPER older than the
-- one that saved it shows a load warning first.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.ready()
