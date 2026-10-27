-- A marker and a region whose REAPER names are longer than the 128 bytes the
-- extension keeps, with byte 128 inside a multi-byte character.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local name = "Alt Puente — " .. string.rep("acústica, ", 15)
reaper.AddProjectMarker2(0, false, 4, 0, name, 1, 0)
reaper.AddProjectMarker2(0, true, 8, 16, name, 1, 0)
harness.oracle("name_len", #name)
harness.ready()
