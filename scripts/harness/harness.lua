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
