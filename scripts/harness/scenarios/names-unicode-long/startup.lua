-- Names users really type: accents, emoji, CJK, and very long names.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track("Bën — Vocals 🎤")
harness.track("ギター")
harness.track(string.rep("Long name ", 40))   -- 400 bytes
reaper.AddProjectMarker(0, false, 1, 0, "Chorus 💥 " .. string.rep("x", 300), -1)
reaper.AddProjectMarker(0, true, 2, 6, "Brücke " .. string.rep("y", 300), -1)
harness.ready()
