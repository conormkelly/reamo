-- A project last saved by REAPER 6.36 on 64-bit Windows (corpus/legacy-v6.RPP,
-- written by hand in that version's chunk layout): 96 BPM 4/4, a drum folder,
-- stock Cockos plugins saved under their Windows .dll names, a VST3 that isn't
-- installed here (REAPER warns while loading), an instrument VST3 the user had
-- set offline, two-take audio with item notes, MIDI stored in the project,
-- sends to a reverb, master FX, markers, regions and project notes. Every
-- audio file is on a Windows drive that doesn't exist here, so REAPER raises
-- its missing-media dialog as well.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local dir = "/tmp/corpus/legacy-v6"
os.execute("mkdir -p " .. dir)
local src = io.open("/harness/corpus/legacy-v6.RPP", "rb")
local text = src:read("a")
src:close()
-- REAPER on Windows writes CRLF line endings.
local out = io.open(dir .. "/legacy-v6.RPP", "wb")
out:write((text:gsub("\r?\n", "\r\n")))
out:close()
harness.log("wrote %s/legacy-v6.RPP (%d bytes)", dir, #text)
