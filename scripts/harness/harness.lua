-- Helpers for scenario fixtures (scenarios/<name>/startup.lua):
--
--   dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
--   local t = harness.track("Vocals")
--   harness.ready()   -- always last: boot.sh waits for this before testing
harness = {}

local log = io.open("/tmp/harness_lua.log", "a")

function harness.log(fmt, ...)
  log:write(string.format(fmt, ...) .. "\n")
  log:flush()
end

-- Append a user track (optionally named) and return it.
function harness.track(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local t = reaper.GetTrack(0, idx)
  if name then reaper.GetSetMediaTrackInfo_String(t, "P_NAME", name, true) end
  return t
end

-- Add an empty item to `track` at `pos` seconds, `len` long.
function harness.item(track, pos, len)
  local it = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len or 1)
  return it
end

-- Record a ground-truth value computed by REAPER itself, for test.py to
-- compare against (reamo_client.oracle()). Values are strings or numbers.
function harness.oracle(key, value)
  local f = io.open("/tmp/harness_oracle.tsv", "a")
  f:write(key .. "\t" .. tostring(value) .. "\n")
  f:close()
end

-- Open a project from the repo's test-fixtures directory (a writable copy).
function harness.open_fixture(name)
  reaper.Main_openProject("noprompt:/tmp/fixtures/" .. name)
  harness.log("opened %s: tracks=%d", name, reaper.CountTracks(0))
end

function harness.ready()
  reaper.UpdateArrange()
  harness.log("fixture ready: tracks=%d items=%d", reaper.CountTracks(0), reaper.CountMediaItems(0))
  local f = io.open("/tmp/harness_fixture_ready", "w")
  f:write("1")
  f:close()
end
