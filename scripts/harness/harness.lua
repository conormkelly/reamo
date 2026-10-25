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

-- Write a 16-bit PCM WAV of a sine at `freq` Hz (default 48 kHz stereo), so
-- items have real audio: peaks, meters and the tuner then see a signal.
function harness.wav(path, seconds, freq, channels, rate)
  channels, rate = channels or 2, rate or 48000
  local frames = math.floor(seconds * rate)
  local parts = {}
  local step = 2 * math.pi * freq / rate
  for i = 0, frames - 1 do
    local v = math.floor(math.sin(i * step) * 16000)
    parts[#parts + 1] = string.rep(string.pack("<i2", v), channels)
  end
  local data = table.concat(parts)
  local f = io.open(path, "wb")
  f:write("RIFF", string.pack("<I4", 36 + #data), "WAVEfmt ",
    string.pack("<I4I2I2I4I4I2I2", 16, 1, channels, rate, rate * channels * 2, channels * 2, 16),
    "data", string.pack("<I4", #data), data)
  f:close()
  return path
end

-- Add an item on `track` at `pos` playing the audio file at `path`.
-- Extra takes: harness.add_take(item, path).
function harness.audio_item(track, pos, path, len)
  local it = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(it)
  local src = reaper.PCM_Source_CreateFromFile(path)
  reaper.SetMediaItemTake_Source(take, src)
  local srclen = reaper.GetMediaSourceLength(src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len or srclen)
  return it, take
end

function harness.add_take(item, path, name)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, reaper.PCM_Source_CreateFromFile(path))
  if name then reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true) end
  return take
end

-- A MIDI item with `notes` = {{start_qn, len_qn, pitch, vel}, ...} (quarter notes from item start).
function harness.midi_item(track, pos, len, notes)
  local it = reaper.CreateNewMIDIItemInProj(track, pos, pos + len, false)
  local take = reaper.GetActiveTake(it)
  local qn0 = reaper.TimeMap2_timeToQN(0, pos)
  for _, n in ipairs(notes or {}) do
    local s = reaper.MIDI_GetPPQPosFromProjQN(take, qn0 + n[1])
    local e = reaper.MIDI_GetPPQPosFromProjQN(take, qn0 + n[1] + n[2])
    reaper.MIDI_InsertNote(take, false, false, s, e, 0, n[3], n[4] or 100, true)
  end
  reaper.MIDI_Sort(take)
  return it, take
end

-- Append raw RPP text inside a track's chunk, just before its closing ">"
-- (for content the API cannot create, e.g. a plugin that is not installed).
function harness.track_chunk_append(track, text)
  local ok, chunk = reaper.GetTrackStateChunk(track, "", false)
  assert(ok, "GetTrackStateChunk failed")
  chunk = chunk:gsub(">%s*$", text .. "\n>\n")
  assert(reaper.SetTrackStateChunk(track, chunk, false), "SetTrackStateChunk failed")
end

-- Save the project to `path`, then patch top-level RPP lines REAPER's API
-- cannot set (e.g. PROJOFFS for the start measure, TIMELOCKMODE, SAMPLERATE).
-- The test opens it with reamo_client.open_project(), which goes through
-- REAPER's project-load path (and its dialogs) while clients are connected.
function harness.save_project(path, patches)
  reaper.Main_SaveProjectEx(0, path, 0)
  local f = io.open(path, "r")
  local text = f:read("a")
  f:close()
  for key, value in pairs(patches or {}) do
    local n
    text, n = text:gsub("\n  " .. key .. " [^\n]*", "\n  " .. key .. " " .. value, 1)
    if n == 0 then text = text:gsub("\n", "\n  " .. key .. " " .. value .. "\n", 1) end
  end
  f = io.open(path, "w")
  f:write(text)
  f:close()
  harness.log("saved %s: tracks=%d items=%d", path, reaper.CountTracks(0), reaper.CountMediaItems(0))
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

-- Minimal JSON encoder for RPC results. Tables with keys 1..n are arrays;
-- non-finite numbers become strings ("inf", "nan") so they survive the trip.
local function json(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return json(tostring(v)) end
    if math.type and math.type(v) == "integer" then return tostring(v) end
    return string.format("%.17g", v)
  elseif t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    local n = #v
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    local parts = {}
    if count == n then
      for i = 1, n do parts[i] = json(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, val in pairs(v) do parts[#parts + 1] = json(tostring(k)) .. ":" .. json(val) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return json(tostring(v)) -- userdata (MediaTrack* etc.), functions
end

-- RPC: test.py's reaper() drops numbered Lua chunks into /tmp/harness_rpc;
-- this loop runs each on REAPER's main thread (as a user's edit would be)
-- and writes its return values back as JSON. Requests run strictly in order.
local RPC = "/tmp/harness_rpc/"
local rpc_next = 1

local function write_atomic(path, text)
  local f = io.open(path .. ".tmp", "w")
  f:write(text)
  f:close()
  os.rename(path .. ".tmp", path)
end

local function serve()
  local path = RPC .. rpc_next .. ".lua"
  local f = io.open(path, "r")
  if f then
    local src = f:read("a")
    f:close()
    os.remove(path)
    local chunk, err = load(src, "=rpc" .. rpc_next)
    local out
    if not chunk then
      out = '{"ok":false,"error":' .. json(err) .. '}'
    else
      local res = table.pack(pcall(chunk))
      if res[1] then
        local vals = {}
        for i = 2, res.n do vals[i - 1] = json(res[i]) end
        out = '{"ok":true,"result":[' .. table.concat(vals, ",") .. ']}'
      else
        out = '{"ok":false,"error":' .. json(res[2]) .. '}'
      end
    end
    write_atomic(RPC .. rpc_next .. ".out", out)
    rpc_next = rpc_next + 1
  end
  reaper.defer(serve)
end

function harness.ready()
  reaper.UpdateArrange()
  harness.log("fixture ready: tracks=%d items=%d", reaper.CountTracks(0), reaper.CountMediaItems(0))
  os.execute("mkdir -p " .. RPC)
  serve()
  local f = io.open("/tmp/harness_fixture_ready", "w")
  f:write("1")
  f:close()
end
