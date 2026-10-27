-- About 84 KB of lyrics: more than a phone can carry (64 KB).
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local lines = {}
for i = 1, 2000 do lines[#lines + 1] = string.format("Verse %04d: la la la la la la la la la la", i) end
lines[#lines + 1] = "THE END OF THE LYRICS"
reaper.GetSetProjectNotes(0, true, table.concat(lines, "\n"))
harness.ready()
