dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track("Vox")
-- A user script that asks a question, as a toolbar script on a phone
-- button might: it holds REAPER in a modal dialog until answered.
local path = reaper.GetResourcePath() .. "/Scripts/modal_probe.lua"
local f = assert(io.open(path, "w"))
f:write('reaper.ShowMessageBox("Waiting for an answer", "REAmo modal probe", 0)\n')
f:close()
reaper.SetExtState("harness", "modal_cmd", tostring(reaper.AddRemoveReaScript(true, 0, path, true)), false)
harness.ready()
