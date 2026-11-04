-- ReaEQ with 86 bands, so 258 band parameters (frequency, gain and
-- bandwidth of each) before its global ones. Parameters 0 to 255 are each
-- set to their own value, so a parameter's value says which one it is.
--
-- A JSFX can't be the plugin: REAPER 6.0 gives one at most 64 sliders.
-- ReaEQ ships with every REAPER, and a user adds bands to it in its window;
-- a script can't, so this writes them into ReaEQ's saved state. That state
-- is REAPER's VST chunk header, ReaEQ's own data (a version, the band count
-- and a 33-byte record per band, then its global settings), and a trailer.
-- The header holds the data's length, and the data its band count; both
-- change, the rest is kept as REAPER wrote it.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

local BANDS = 86
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64decode(s)
  s = s:gsub("=", "")
  local out = {}
  for i = 1, #s, 4 do
    local quad = s:sub(i, i + 3)
    local v = 0
    for j = 1, 4 do
      local c = quad:sub(j, j)
      v = (v << 6) | (c == "" and 0 or assert(B64:find(c, 1, true), "not base64: " .. c) - 1)
    end
    out[#out + 1] = string.pack(">I3", v):sub(1, #quad - 1)
  end
  return table.concat(out)
end

local function b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local group = s:sub(i, i + 2)
    local v = string.unpack(">I3", group .. string.rep("\0", 3 - #group))
    for k = 0, 3 do
      local sextet = (v >> (18 - 6 * k)) & 63
      out[#out + 1] = k > #group and "=" or B64:sub(sextet + 1, sextet + 1)
    end
  end
  return table.concat(out)
end

-- Each line of a VST chunk is base64 on its own; lines of a multiple of 3
-- bytes carry no padding.
local function b64lines(s)
  local lines = {}
  for i = 1, #s, 96 do lines[#lines + 1] = b64encode(s:sub(i, i + 95)) end
  return table.concat(lines, "\n")
end

local t = harness.track("Synth")
harness.oracle("fx", reaper.TrackFX_AddByName(t, "ReaEQ", false, -1))

local ok, chunk = reaper.GetTrackStateChunk(t, "", false)
assert(ok, "GetTrackStateChunk failed")
local head, body, tail = chunk:match("(<VST [^\n]*\n)(.-)(\n>)")
assert(head, "no ReaEQ in the track's chunk")
local lines = {}
for line in body:gmatch("[^\n]+") do lines[#lines + 1] = b64decode(line) end
-- The header: the plugin's ID, a magic number, the input count and a 64-bit
-- pin mask per input, the output count and its masks, the data's length,
-- then 8 bytes this fixture keeps as they are.
local header = lines[1]
local rest = table.concat(lines, "", 2)
local _, magic, inputs = string.unpack("<I4I4I4", header)
local outputs = string.unpack("<I4", header, 13 + 8 * inputs)
local size_at = 17 + 8 * inputs + 8 * outputs
assert(magic == 0xFEED5EEE and #header == size_at + 3 + 8,
  string.format("REAPER VST chunk header (magic %x, %d bytes, %d in, %d out): not the layout this fixture knows",
    magic, #header, inputs, outputs))
local size = string.unpack("<I4", header, size_at)
assert(#rest > size, string.format("the VST chunk holds %d bytes after its header, its data says %d", #rest, size))
local data, trailer = rest:sub(1, size), rest:sub(size + 1)
local version, count = string.unpack("<I4I4", data)
local record = data:sub(8 + 33 + 1, 8 + 33 * 2)  -- band 2: a band (peak) filter
assert(version == 33 and count >= 2 and count < BANDS and #data >= 8 + 33 * count and string.unpack("<I4", record) == 8,
  string.format("ReaEQ state version %d (%d bytes, %d bands): not the layout this fixture knows", version, #data, count))
data = string.pack("<I4I4", version, BANDS) .. data:sub(9, 8 + 33 * count)
  .. string.rep(record, BANDS - count) .. data:sub(8 + 33 * count + 1)
header = header:sub(1, size_at - 1) .. string.pack("<I4", #data) .. header:sub(size_at + 4)
chunk = chunk:gsub("<VST [^\n]*\n.-\n>", function()
  return head .. b64encode(header) .. "\n" .. b64lines(data) .. "\n" .. b64encode(trailer) .. tail
end, 1)
assert(reaper.SetTrackStateChunk(t, chunk, false), "SetTrackStateChunk failed")

harness.oracle("params", reaper.TrackFX_GetNumParams(t, 0))
for i = 0, 255 do
  reaper.TrackFX_SetParamNormalized(t, 0, i, i / 1000)
end
for _, i in ipairs({ 0, 180, 255 }) do
  harness.oracle("value" .. i, reaper.TrackFX_GetParamNormalized(t, 0, i))
  local _, formatted = reaper.TrackFX_GetFormattedParamValue(t, 0, i, "")
  harness.oracle("formatted" .. i, formatted)
end
harness.ready()
