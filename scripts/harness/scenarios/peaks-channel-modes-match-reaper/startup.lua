-- A stereo file (left: the staircase, right: 0.25) in takes with each
-- channel mode (Item Properties: Channel mode, I_CHANMODE), a four-channel
-- file in the modes that pick channels past the second, and a mono file
-- (the staircase) in normal, reverse stereo and a mode picking a channel it
-- doesn't have.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")

-- 8 s, 8 kHz: a 200 Hz square wave on every channel, channel k at levels[k].
local function levels_wav(path, levels)
  local rate, ch = 8000, #levels
  local n = rate * 8
  local f = io.open(path, "wb")
  f:write("RIFF", string.pack("<I4", 36 + n * 2 * ch), "WAVE")
  f:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, ch, rate, rate * 2 * ch, 2 * ch, 16))
  f:write("data", string.pack("<I4", n * 2 * ch))
  local parts = {}
  for i = 0, n - 1 do
    local sign = ((i // 20) % 2 == 0) and 1 or -1
    for c = 1, ch do parts[#parts + 1] = string.pack("<i2", math.floor(sign * levels[c] * 32767)) end
    if #parts >= 8192 then f:write(table.concat(parts)); parts = {} end
  end
  f:write(table.concat(parts))
  f:close()
  return path
end

local stereo = harness.staircase_wav("/tmp/staircase-stereo.wav", true)
for _, m in ipairs({{"normal", 0}, {"reverse stereo", 1}, {"mono (downmix)", 2}, {"mono (left)", 3}, {"mono (right)", 4}}) do
  local _, take = harness.waveform_item(m[1], stereo, 1, 8)
  reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", m[2])
end
local quad = levels_wav("/tmp/quad.wav", {0.1, 0.2, 0.3, 0.4})
for _, m in ipairs({{"mono (channel 3)", 5}, {"mono (channel 4)", 6}, {"stereo (channels 3/4)", 69}}) do
  local _, take = harness.waveform_item(m[1], quad, 1, 8)
  reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", m[2])
end
local mono = harness.staircase_wav("/tmp/staircase-mono.wav", false)
for _, m in ipairs({{"mono source (normal)", 0}, {"mono source (reverse stereo)", 1}, {"mono source (mono channel 3)", 5}}) do
  local _, take = harness.waveform_item(m[1], mono, 1, 8)
  reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", m[2])
end
harness.ready()
