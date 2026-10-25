dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for _, n in ipairs({"Kick", "Snare", "Bass"}) do harness.track(n) end
reaper.Undo_OnStateChangeEx2(0, "fixture", -1, -1)
harness.ready()
