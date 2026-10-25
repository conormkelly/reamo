-- A 4 s mono WAV: 2 s of silence, then 2 s of a 200 Hz square wave at 0.8.
-- One item shows its first 2 s (silence); a control item on a second track
-- shows the loud half.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local rate, secs = 8000, 4
local path = "/tmp/half-silent.wav"
local n = rate * secs
local f = io.open(path, "wb")
f:write("RIFF", string.pack("<I4", 36 + n * 2), "WAVE")
f:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16))
f:write("data", string.pack("<I4", n * 2))
local hi, lo = string.pack("<i2", math.floor(0.8 * 32767)), string.pack("<i2", -math.floor(0.8 * 32767))
local zero = string.pack("<i2", 0)
local chunk = {}
for i = 0, n - 1 do
  if i < rate * 2 then chunk[#chunk + 1] = zero
  elseif (i // 20) % 2 == 0 then chunk[#chunk + 1] = hi
  else chunk[#chunk + 1] = lo end
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
reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
-- Control: the same file on a second track, already showing the loud half.
local t2 = harness.track("Vox dbl")
local it2 = reaper.AddMediaItemToTrack(t2)
local take2 = reaper.AddTakeToMediaItem(it2)
reaper.SetMediaItemTake_Source(take2, reaper.PCM_Source_CreateFromFile(path))
reaper.SetMediaItemTakeInfo_Value(take2, "D_STARTOFFS", 2)
reaper.SetMediaItemInfo_Value(it2, "D_POSITION", 0)
reaper.SetMediaItemInfo_Value(it2, "D_LENGTH", 2)
-- Build the peak file now so GetMediaItemTake_Peaks has data.
if reaper.PCM_Source_BuildPeaks(src, 0) ~= 0 then
  while reaper.PCM_Source_BuildPeaks(src, 1) ~= 0 do end
  reaper.PCM_Source_BuildPeaks(src, 2)
end
reaper.UpdateArrange()
harness.log("source len=%f", reaper.GetMediaSourceLength(src))
harness.ready()
