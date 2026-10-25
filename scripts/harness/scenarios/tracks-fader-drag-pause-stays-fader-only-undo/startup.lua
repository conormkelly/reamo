dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track("Vocals")
harness.track("Guitar")
reaper.Undo_OnStateChangeEx2(0, "fixture", -1, -1)  -- so Undo can't unwind the fixture itself
harness.ready()
