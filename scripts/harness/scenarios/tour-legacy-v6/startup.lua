-- Copies corpus/legacy-v6.RPP into place; the tour opens it with clients
-- connected, clicking through REAPER's plugin and missing-media dialogs.
dofile("/harness/corpus/legacy-v6.lua")
harness.ready()
