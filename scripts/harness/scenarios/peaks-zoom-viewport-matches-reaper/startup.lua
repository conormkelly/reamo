-- A 30 s mono WAV at 8 kHz: a 200 Hz square wave at 0.1, loud (0.9) from
-- 10 s to 12 s. Beside it on other tracks: a MIDI item and an empty item.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local rate, secs = 8000, 30
local path = "/tmp/accent.wav"
local n = rate * secs
local f = io.open(path, "wb")
f:write("RIFF", string.pack("<I4", 36 + n * 2), "WAVE")
f:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16))
f:write("data", string.pack("<I4", n * 2))
local function s16(v) return string.pack("<i2", math.floor(v * 32767)) end
local q, l = {s16(0.1), s16(-0.1)}, {s16(0.9), s16(-0.9)}
local chunk = {}
for i = 0, n - 1 do
  local loud = i >= rate * 10 and i < rate * 12
  chunk[#chunk + 1] = (loud and l or q)[(i // 20) % 2 + 1]
  if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
end
f:write(table.concat(chunk))
f:close()

local t = harness.track("Vox")
local it = reaper.AddMediaItemToTrack(t)
local take = reaper.AddTakeToMediaItem(it)
local src = reaper.PCM_Source_CreateFromFile(path)
reaper.SetMediaItemTake_Source(take, src)
reaper.SetMediaItemInfo_Value(it, "D_POSITION", 0)
reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 30)
harness.build_peaks(src)
reaper.CreateNewMIDIItemInProj(harness.track("Keys"), 0, 8, false)
harness.item(harness.track("Empty"), 2, 4)
reaper.UpdateArrange()
harness.ready()
