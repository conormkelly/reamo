dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
for _, n in ipairs({"Kick", "Snare", "Bass", "Gtr", "Keys", "Vox"}) do harness.item(harness.track(n), 0, 2) end
harness.ready()
